"""Where recorded speech is cut for recognition: never inside a word when a quieter moment is near, never the same
audio twice, and no sentence mark where a cut fell inside a sentence. Live captions close a piece at a pause."""
from pathlib import Path
import sys
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import transcribe as T  # noqa: E402
import board_live as L  # noqa: E402

SR = T.SR


def speech(seconds: float, gaps=(), dip_at=None):
    """A loud tone (speech stand-in) with silent `gaps` [(start, end)] and a quiet 60 ms dip at `dip_at`."""
    t = np.arange(int(seconds * SR)) / SR
    x = (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    for a, b in gaps:
        x[int(a * SR):int(b * SR)] = 0
    if dip_at is not None:
        x[int((dip_at - .03) * SR):int((dip_at + .03) * SR)] *= .02
    return x


class QuietCut(unittest.TestCase):
    def test_cut_falls_on_the_quiet_moment(self):
        x = speech(20, dip_at=7.3)
        self.assertAlmostEqual(T.quiet_cut(x, 5, 10), 7.3, delta=.05)

    def test_a_window_too_short_keeps_its_end(self):
        self.assertEqual(T.quiet_cut(speech(1), .5, .51), .51)


class SpeechChunks(unittest.TestCase):
    def setUp(self):
        self.vad = T.vad_segments

    def tearDown(self):
        T.vad_segments = self.vad

    def test_long_speech_is_cut_at_its_quietest_and_never_overlaps(self):
        x = speech(24, dip_at=8.2)
        # the VAD hears one 24 s stretch, padded at both ends
        T.vad_segments = lambda s, max_speech=25: [(0.0, 24.0)]
        chunks = T.speech_chunks(x, 10)
        self.assertAlmostEqual(chunks[0][1], 8.2, delta=.05)
        for a, b in zip(chunks, chunks[1:]):
            self.assertLessEqual(a[1], b[0])
        self.assertTrue(all(e - s <= 10 for s, e in chunks))

    def test_padded_neighbours_meet_in_the_middle(self):
        x = speech(12, gaps=[(5.9, 6.1)])
        T.vad_segments = lambda s, max_speech=25: [(0.0, 6.2), (5.8, 12.0)]
        chunks = T.speech_chunks(x, 8)
        self.assertEqual(len(chunks), 2)
        self.assertAlmostEqual(chunks[0][1], chunks[1][0])
        self.assertAlmostEqual(chunks[0][1], 6.0, delta=.01)


class LongPauses(unittest.TestCase):
    """The Windows app joins takes recorded apart with 2 s of silence: no piece may hold the end of one and the start of
    the next, for either kind of chunking."""

    def setUp(self):
        self.vad = T.vad_segments

    def tearDown(self):
        T.vad_segments = self.vad

    def test_a_long_pause_ends_a_span(self):
        # take 1 speech to 6.0 s, 2 s of silence, take 2 from 8.0 s; the VAD's segments padded as vad_segments pads
        T.vad_segments = lambda s, max_speech=25: [(0.0, 6.2), (7.85, 12.0)]
        spans = T.pause_spans(speech(12), 20)
        self.assertEqual(len(spans), 2)
        self.assertLess(spans[0][1], 8.0)

    def test_short_pauses_still_share_a_span(self):
        T.vad_segments = lambda s, max_speech=25: [(0.0, 6.2), (6.4, 12.0)]
        self.assertEqual(len(T.pause_spans(speech(12), 20)), 1)

    def test_sensevoice_windows_never_bridge_a_take(self):
        T.vad_segments = lambda s, max_speech=25: [(0.0, 3.2), (4.85, 7.0)]
        self.assertEqual(len(T.speech_chunks(speech(7), 10)), 2)


class MendCut(unittest.TestCase):
    def test_a_full_stop_inside_a_sentence_goes(self):
        self.assertEqual(T.mend_cut((0, 1, "每一个T都给出一个横坐标和。"), "一个纵坐标")[2], "每一个T都给出一个横坐标和")
        self.assertEqual(T.mend_cut((0, 1, "时刻T。"), "决定一个X")[2], "时刻T")

    def test_other_marks_and_languages_stay(self):
        self.assertEqual(T.mend_cut((0, 1, "这样对吗？"), "不对")[2], "这样对吗？")
        self.assertEqual(T.mend_cut((0, 1, "It works."), "Next")[2], "It works.")

    def test_mid_speech_tells_a_pause_from_a_word(self):
        x = speech(10, gaps=[(4.8, 5.4)])
        self.assertFalse(T.mid_speech(x, 5.1))
        self.assertTrue(T.mid_speech(x, 2.5))


class JoinPieces(unittest.TestCase):
    def test_no_space_between_chinese_pieces_without_a_language_tag(self):
        text, _ = T.note_text([(0, 1, "由Y等于T加一"), (1, 2, "得到T等于Y减一"), (2, 3, "Then we go")])
        self.assertEqual(text, "由Y等于T加一得到T等于Y减一Then we go")

    def test_korean_pieces_keep_their_space(self):
        # Korean puts spaces between words: its pieces are joined like English
        self.assertEqual(T.note_text([(0, 1, "버튼을 눌러도"), (1, 2, "반응이 없습니다")])[0], "버튼을 눌러도 반응이 없습니다")

    def test_english_pieces_keep_their_space(self):
        self.assertEqual(T.note_text([(0, 1, "First part."), (1, 2, "Second part.")])[0], "First part. Second part.")


class CaptionLanguage(unittest.TestCase):
    """The app's 识别语言 reaches the model, through the warm server and without it; none given: the model tells."""

    def test_language_goes_to_the_warm_server(self):
        seen = []
        old = T._server_call
        T._server_call = lambda req, timeout=120: seen.append(req) or {"ok": True, "model": "m", "text": "hi"}
        try:
            L.CaptionEngine("m", "en").note(Path("x.wav"))
            L.CaptionEngine("m").note(Path("x.wav"))
        finally:
            T._server_call = old
        self.assertEqual([r["language"] for r in seen], ["en", None])

    def test_language_goes_to_a_local_engine(self):
        calls = []

        class Engine:
            name = "local"
            def load(self, language, model): calls.append(("load", language))
            def note(self, wav, model_id, **kw): calls.append(("note", kw.get("language"))); return {"model": model_id, "text": ""}
        old_call, old_engine = T._server_call, T.NoteEngine
        T._server_call, T.NoteEngine = (lambda req, timeout=120: None), Engine
        try:
            L.CaptionEngine("m", "zh").note(Path("x.wav"))
        finally:
            T._server_call, T.NoteEngine = old_call, old_engine
        self.assertEqual(calls, [("load", "zh"), ("note", "zh")])


def pcm(x):
    return (np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()


class LiveCaptionPieces(unittest.TestCase):
    def test_a_pause_closes_a_piece_in_its_middle(self):
        x = speech(5.2, gaps=[(4.4, 5.2)])
        cut = L.settle_point(pcm(x), 12, final=False)
        self.assertAlmostEqual(cut / L.RATE, 4.8, delta=.1)

    def test_short_or_unbroken_speech_waits(self):
        self.assertEqual(L.settle_point(pcm(speech(3, gaps=[(2, 3)])), 12, final=False), 0)
        self.assertEqual(L.settle_point(pcm(speech(8)), 12, final=False), 0)

    def test_a_full_window_is_cut_at_its_quietest_in_the_second_half(self):
        cut = L.settle_point(pcm(speech(12, dip_at=9.1)), 12, final=False)
        self.assertAlmostEqual(cut / L.RATE, 9.1, delta=.06)

    def test_stop_or_pause_takes_everything(self):
        data = pcm(speech(2))
        self.assertEqual(L.settle_point(data, 12, final=True), len(data))


if __name__ == "__main__":
    unittest.main()
