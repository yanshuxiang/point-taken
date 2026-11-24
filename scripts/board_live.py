# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy==2.3.4; python_version >= '3.11'", "numpy==2.2.6; python_version < '3.11'", "sherpa-onnx==1.13.8", "truststore==0.10.5", "opencc-python-reimplemented==0.1.7"]
# ///
"""Annotation captions from its explicit model. Input is pause-trimmed 16k mono s16le PCM.

No microphone, system speech, dictation settings, voiceprint gate, model download or provider fallback.
stdout is JSON-lines; credentials are inherited only through the existing app environment.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import transcribe as T

RATE = T.SR * 2


def stream(root: Path, model: str, backend, send, window_seconds=240):
    """Native provider partials. Rotate at pauses / bounded windows without losing audio offsets."""
    session = None
    count = 0
    total = 0
    part = 0
    request_id = ""
    heartbeat = time.monotonic()
    output_lock = threading.Lock()

    def event(kind, **fields):
        with output_lock:
            send({"ok": True, "event": kind, "model": model, "provider": "volcengine",
                  "request_id": request_id, "service_model": "seed-asr-2.0 (bigmodel_async, two-pass)", "part": part, **fields})

    def update(text, _last):
        event("partial", text=T.to_user_script(text, None), start=total / RATE)

    def finish():
        nonlocal session, count, total, part
        if session is None:
            return
        text = session.finish(wait=T.final_wait(count / RATE, count / RATE))
        # each sentence's time in the recording: lets the app keep this two-pass text as the final transcript
        rows = []
        for row in session.utterances or []:
            begin, end, words = row.get("start_time"), row.get("end_time"), row.get("text")
            if (isinstance(begin, (int, float)) and isinstance(end, (int, float)) and 0 <= begin < end
                    and isinstance(words, str) and words.strip()):
                rows.append({"start": total / RATE + begin / 1000, "end": total / RATE + min(end / 1000, count / RATE),
                             "text": T.to_user_script(words, None)})
        event("segment", text=T.to_user_script(text, None), start=total / RATE, end=(total + count) / RATE,
              utterances=rows)
        session = None
        total += count
        count = 0
        part += 1

    try:
        with (root / "audio.pcm").open("rb", buffering=0) as source:
            while True:
                if time.monotonic() - heartbeat >= 2:
                    event("heartbeat")
                    heartbeat = time.monotonic()
                paused = (root / "paused").exists()
                data = source.read(6400) if not paused else b""
                if data:
                    if session is None:
                        backend.utterances = True
                        backend.two_pass = True
                        session = backend.open(url=T.VOLC_LIVE_URL, on_update=update)
                        request_id = session.request_id
                        event("connected")
                    session.feed(data)
                    count += len(data)
                    if count >= window_seconds * RATE:
                        finish()
                else:
                    # Stop drains bytes even if paused; queued microphone writes are already closed.
                    if (root / "stop").exists():
                        if paused:
                            (root / "paused").unlink(missing_ok=True)
                            continue
                        finish()
                        event("done")
                        return
                    if paused:
                        finish()
                    time.sleep(.03)
                if session is not None and getattr(session, "failed", False) is True:
                    raise session.error or T.Fail("live connection ended", "network")
    finally:
        if session is not None:
            session.close()


class CaptionEngine:
    """Reuse an existing server, or one local engine for both captions and the final original recording."""

    def __init__(self, model: str, language: str | None = None):
        self.model = model
        # the language the user said they speak (the app's 识别语言); None: the model tells (a short or accented piece
        # was taken for another language — "Okay, hi guys" came back as オケは外し)
        self.language = language or None
        self.engine = None
        self.provider = (T.entry(model) or {}).get("backend", "local")

    def note(self, wav: Path, *, include_segments=False):
        result = None
        if self.engine is None:
            result = T._server_call({"cmd": "note", "wav": str(wav), "model_id": self.model,
                                     "language": self.language, "no_download": True, "include_segments": include_segments},
                                    timeout=580 if include_segments else 120)
            if result is not None and not result.get("ok"):
                raise T.Fail("the selected live model failed", result.get("code") or "error")
            if result is not None and include_segments and not isinstance(result.get("segments"), list):
                result = None  # a warm process from before the timestamp protocol was added
            if result is None:
                self.engine = T.NoteEngine()
                self.engine.load(self.language, self.model)
                self.provider = self.engine.name
        if self.engine is not None:
            options = {"include_segments": True} if include_segments else {}
            if self.language:
                options["language"] = self.language
            result = self.engine.note(wav, model_id=self.model, **options)
        if result.get("model") != self.model or result.get("looped"):
            raise T.Fail("live model returned an incomplete result", "bad_response")
        self.provider = result.get("provider") or self.provider
        return result

    def finalize(self, audio_file: Path, send):
        send({"ok": True, "event": "finalizing", "model": self.model, "provider": self.provider})
        try:
            result = self.note(audio_file, include_segments=True)
            if not isinstance(result.get("segments"), list):
                raise T.Fail("final transcript has no timestamp evidence", "bad_response")
            send({**result, "ok": True, "event": "file_transcript", "model": self.model,
                  "provider": self.provider})
        except (Exception, SystemExit) as error:
            # The original recording and live segments remain available. Report failure, never replace them
            # with a shortened final text or load another model to silently retry the whole recording.
            code = error.code if isinstance(error, T.Fail) else "error"
            send({"ok": False, "event": "file_transcript", "model": self.model, "code": code})


FRAME = int(T.SR * .03)          # 30 ms


def frame_levels(pcm) -> "T.np.ndarray":
    """RMS of each 30 ms of 16-bit PCM."""
    x = T.np.frombuffer(pcm, dtype="<i2", count=len(pcm) // 2).astype(T.np.float32) / 32768
    k = len(x) // FRAME
    return T.np.sqrt((x[:k * FRAME].reshape(k, FRAME) ** 2).mean(1)) if k else T.np.zeros(0, T.np.float32)


def settle_point(pcm, window_seconds: float, final: bool) -> int:
    """Where the captions' window is closed (bytes; 0: not yet). A caption piece ends at a pause, never inside a word:
    after 4 s of audio, a pause of 0.6 s at the end closes it in the middle of that pause; a window that reaches
    `window_seconds` with no such pause is cut at its quietest 30 ms in its second half. Before, every 15 s was cut
    wherever it fell — a word split in two came back as two wrong characters and a sentence mark in the middle of it."""
    if final:
        return len(pcm)
    seconds = len(pcm) / RATE
    if seconds < 4:
        return 0
    levels = frame_levels(pcm)
    if not len(levels):
        return 0
    # quiet: under a fifth of the louder speech here (and under -50 dBFS whatever is said)
    quiet = max(.003, .2 * float(T.np.percentile(levels, 75)))
    tail = 0
    for v in levels[::-1]:
        if v >= quiet:
            break
        tail += 1
    if tail * .03 >= .6 and tail < len(levels):
        return (len(levels) - tail // 2) * FRAME * 2
    if seconds >= window_seconds:
        lo = len(levels) // 2
        return (lo + int(T.np.argmin(levels[lo:])) + 1) * FRAME * 2
    return 0


def incremental(root: Path, model: str, send, interval=1.5, window_seconds=12, audio_file: Path | None = None,
                language: str | None = None):
    """Models without a streaming protocol decode their current short window using that same model."""
    engine = CaptionEngine(model, language)
    count = 0
    part = 0
    last_size = 0
    ready = False
    heartbeat = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="point-taken-caption-") as td, (root / "audio.pcm").open("rb", buffering=0) as source:
        wav = Path(td) / "window.wav"
        pending = bytearray()
        while True:
            if time.monotonic() - heartbeat >= 2:
                send({"ok": True, "event": "heartbeat", "model": model})
                heartbeat = time.monotonic()
            room = max(0, int(window_seconds * RATE) - len(pending))
            data = source.read(room) if room else b""
            pending.extend(data)
            # stopped only once the file has nothing more (a full window read nothing because it asked for nothing)
            stop = (root / "stop").exists() and not data and room > 0
            paused = (root / "paused").exists()
            cut = settle_point(pending, window_seconds, stop or paused)
            settle = cut > 0
            enough = len(pending) - last_size >= interval * RATE
            if pending and (settle or enough):
                piece = pending[:cut] if settle else pending
                x = T.np.frombuffer(piece, dtype="<i2", count=len(piece) // 2).astype(T.np.float32) / 32768
                wav.write_bytes(T.wav_bytes(x))
                result = engine.note(wav)
                text = result["text"]
                if not ready:
                    send({"ok": True, "event": "connected", "model": model, "provider": engine.provider, "part": part})
                    ready = True
                send({"ok": True, "event": "segment" if settle else "partial", "model": model,
                      "provider": engine.provider, "part": part, "text": text, "start": count / RATE,
                      "end": (count + len(piece)) / RATE})
                last_size = len(pending)
                if settle:
                    # what follows the cut starts the next piece
                    count += len(piece)
                    del pending[:cut]
                    last_size = 0
                    part += 1
            if stop:
                if audio_file is not None:
                    engine.finalize(audio_file, send)
                send({"ok": True, "event": "done", "model": model, "provider": engine.provider, "part": part})
                return
            time.sleep(.05)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--audio-file", type=Path, help="closed original recording, finalized with the caption model")
    parser.add_argument("--language", help="the spoken language (zh, en, ja, ko…); default: the model tells")
    args = parser.parse_args()
    T.watch_parent(os.getppid())
    os.environ["POINT_TAKEN_NO_DOWNLOAD"] = "1"
    lock = threading.Lock()
    def send(event):
        with lock:
            print(json.dumps(event, ensure_ascii=False), flush=True)
    try:
        model = T.entry(args.model_id)
        if model is None:
            raise T.Fail("unknown selected model", "unknown_model")
        if not model.get("local", True) and T.local_only():
            raise T.Fail("cloud speech disabled by local-only setting", "privacy")
        if model.get("backend") == "volcengine":
            backend = T.Volcengine(argparse.Namespace(language=None))
            stream(args.directory, args.model_id, backend, send)
        else:
            incremental(args.directory, args.model_id, send, audio_file=args.audio_file, language=args.language)
    except T.Fail as error:
        # The UI needs the category, never raw provider errors or credentials.
        send({"ok": False, "event": "error", "model": args.model_id, "code": error.code})
        raise SystemExit(1)
    except Exception:
        send({"ok": False, "event": "error", "model": args.model_id, "code": "error"})
        raise SystemExit(1)

if __name__ == "__main__":
    main()
