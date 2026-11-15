"""Annotation finalization reuses a warm model without dropping timestamp evidence."""
import argparse
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import test_asr_select as A
import board_live as L

T = A.T


class AnnotationWarmTranscript(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.wav = A.write_wav(Path(self.directory.name) / "recording.wav", 1)
        self.args = argparse.Namespace(wav=str(self.wav), language=None, model_id="sensevoice-small",
                                       vocab=False, dictation=False, no_server=False,
                                       no_download=False, segments=True)
        self.result = {"ok": True, "model": "sensevoice-small", "text": "all the words",
                       "segments": [{"start": 0, "end": 1, "text": "all the words"}]}

    def test_segmented_cli_request_reuses_the_warm_model(self):
        with mock.patch.object(T, "_server_call", return_value=self.result) as call, \
                mock.patch.object(T, "NoteEngine") as engine, mock.patch.object(T, "emit") as emit:
            T.cmd_note(self.args)
        self.assertEqual(call.call_count, 1)
        self.assertTrue(call.call_args.args[0]["include_segments"])
        self.assertEqual(call.call_args.args[0]["model_id"], "sensevoice-small")
        engine.assert_not_called()
        self.assertEqual(emit.call_args.args[0], {**self.result, "server": True})

    def test_older_server_without_timestamps_falls_back_to_same_model(self):
        old = {k: v for k, v in self.result.items() if k != "segments"}
        with mock.patch.object(T, "_server_call", return_value=old), \
                mock.patch.object(T, "NoteEngine") as engine, mock.patch.object(T, "emit") as emit, \
                mock.patch.object(T, "throttle"):
            engine.return_value.note.return_value = self.result
            T.cmd_note(self.args)
        self.assertEqual(engine.return_value.note.call_args.args[2], "sensevoice-small")
        self.assertTrue(engine.return_value.note.call_args.kwargs["include_segments"])
        self.assertEqual(emit.call_args.args[0], self.result)

    def test_server_errors_do_not_silently_select_another_model(self):
        with mock.patch.object(T, "_server_call", return_value={"ok": False, "code": "model_missing"}), \
                mock.patch.object(T, "NoteEngine") as engine, mock.patch.object(T, "throttle"):
            with self.assertRaises(T.Fail) as error:
                T.cmd_note(self.args)
        self.assertEqual(error.exception.code, "model_missing")
        engine.assert_not_called()

    def test_explicit_no_server_remains_available(self):
        self.args.no_server = True
        with mock.patch.object(T, "_server_call") as call, mock.patch.object(T, "NoteEngine") as engine, \
                mock.patch.object(T, "emit"), mock.patch.object(T, "throttle"):
            T.cmd_note(self.args)
        call.assert_not_called()
        self.assertTrue(engine.return_value.note.call_args.kwargs["include_segments"])


class AnnotationWarmServer(unittest.TestCase):
    setUp = A.Notes.setUp
    tearDown = A.Notes.tearDown
    serve_in_thread = A.Notes.serve_in_thread

    def test_timestamp_request_reaches_the_existing_engine(self):
        calls = []
        original = T.NoteEngine.note

        def note(engine, *args, **kwargs):
            calls.append((id(engine), kwargs.get("include_segments", False)))
            return original(engine, *args, **kwargs)

        with A.config({"asr": {"auto": False, "backend": "sensevoice"}}), \
                mock.patch.object(T.NoteEngine, "note", note):
            thread, _ = self.serve_in_thread(argparse.Namespace(preload=True, idle=600, exit_after=1800, parent=None))
            try:
                request = {"cmd": "note", "wav": str(A.write_wav(self.tmp / "audio.wav", 1)),
                           "model_id": "sensevoice-small", "include_segments": True}
                first = T._server_call(request)
                second = T._server_call(request)
            finally:
                T._server_call({"cmd": "exit"})
                thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(first["segments"], [{"start": 0.0, "end": 1.0, "text": "heard 1.0s"}])
        self.assertEqual(second["segments"], first["segments"])
        self.assertEqual(calls, [(calls[0][0], True), (calls[0][0], True)])


class AnnotationCaptionFinalization(unittest.TestCase):
    def run_caption(self, *, looped=False, warm=False):
        events, calls = [], []
        result = {"ok": True, "model": "sensevoice-small", "text": "the complete recording",
                  "segments": [{"start": 0, "end": 2, "text": "the complete recording"}]}

        class Engine:
            name = "fixture"

            def load(self, language, model):
                calls.append(("load", model))

            def note(self, wav, model_id, include_segments=False):
                calls.append(("note", wav.name, include_segments))
                return {**result, **({"looped": True} if looped and include_segments else {})}

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(T, "NoteEngine", Engine), \
                mock.patch.object(T, "_server_call", return_value=result if warm else None) as server:
            root = Path(directory)
            (root / "audio.pcm").write_bytes(bytes(6400))
            (root / "stop").touch()
            original = A.write_wav(root / "original.wav", 2)
            L.incremental(root, "sensevoice-small", events.append, audio_file=original)
            requests = list(server.call_args_list)
        return events, calls, requests

    def test_final_transcript_reuses_live_engine_and_the_whole_original_audio(self):
        events, calls, _ = self.run_caption()
        self.assertEqual([call for call in calls if call[0] == "load"], [("load", "sensevoice-small")])
        self.assertEqual(calls[-1], ("note", "original.wav", True))
        self.assertEqual([event["event"] for event in events][-3:], ["finalizing", "file_transcript", "done"])
        final = events[-2]
        self.assertEqual(final["text"], "the complete recording")
        self.assertEqual(final["segments"][-1]["end"], 2)
        self.assertTrue(final["ok"])

    def test_incomplete_final_text_is_reported_without_replacing_live_evidence(self):
        events, calls, _ = self.run_caption(looped=True)
        self.assertTrue(any(event["event"] == "segment" for event in events))
        self.assertEqual(events[-2]["event"], "file_transcript")
        self.assertFalse(events[-2]["ok"])
        self.assertEqual(events[-2]["code"], "bad_response")
        self.assertNotIn("text", events[-2])
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(len([call for call in calls if call[0] == "load"]), 1)

    def test_existing_warm_model_handles_live_and_final_without_another_load(self):
        events, calls, requests = self.run_caption(warm=True)
        self.assertEqual(calls, [])
        self.assertTrue(events[-2]["ok"])
        self.assertTrue(requests[-1].args[0]["include_segments"])
        self.assertTrue(all(call.args[0]["model_id"] == "sensevoice-small" for call in requests))


if __name__ == "__main__":
    unittest.main()
