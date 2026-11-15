"""The suite never touches the real ~/.point-taken or ~/Point Taken (conftest.py points both at a scratch dir first)."""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))


class Isolation(unittest.TestCase):
    def test_scripts_resolve_a_scratch_home(self):
        import _common  # noqa: PLC0415
        import transcribe  # noqa: PLC0415
        real = Path.home() / ".point-taken"
        for p in (_common.POINT_TAKEN_HOME, transcribe.POINT_TAKEN_HOME, Path(os.environ["POINT_TAKEN_HOME"])):
            self.assertNotEqual(Path(p).resolve(), real.resolve())
        self.assertNotEqual(Path(os.environ["POINT_TAKEN_WORKSPACE"]).resolve(), (Path.home() / "Point Taken").resolve())
