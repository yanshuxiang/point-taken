"""scripts/.python-version: the Python uv runs the skill's scripts on, so uv never picks one on its own (the newest
release, which the pinned packages may ship no wheels for yet — BLU-1, #47). It must fit every script's
requires-python and ship with each app.

  uv run --with pytest pytest tests/test_python_version.py -q
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"


def pinned() -> tuple[int, int]:
    lines = [l.strip() for l in (SCRIPTS / ".python-version").read_text(encoding="utf-8").splitlines()]
    v = [l for l in lines if l and not l.startswith("#")]
    assert len(v) == 1 and re.fullmatch(r"3\.\d+", v[0]), v
    major, minor = v[0].split(".")
    return int(major), int(minor)


def version(s: str) -> tuple[int, int]:
    major, minor = s.split(".")[:2]
    return int(major), int(minor)


def test_fits_every_script():
    v = pinned()
    for f in sorted(SCRIPTS.glob("*.py")):
        m = re.search(r'^# requires-python = "([^"]+)"', f.read_text(encoding="utf-8"), re.M)
        if not m:
            continue
        for spec in m.group(1).split(","):
            op, ver = re.fullmatch(r"\s*(>=|<|<=|>|==)\s*([\d.]+)\s*", spec).groups()
            ok = {">=": v >= version(ver), ">": v > version(ver), "<": v < version(ver),
                  "<=": v <= version(ver), "==": v == version(ver)}[op]
            assert ok, f"{f.name}: requires-python {m.group(1)!r} excludes {v}"


@pytest.mark.skipif(not (shutil.which("sh") and shutil.which("rsync")), reason="the macOS build step needs sh and rsync")
def test_ships_with_the_desktop_app():
    # The macOS bundle now owns the scripts. Run its actual resource-copy block in a temporary directory,
    # without compiling, installing or opening the app, to catch excludes that accidentally drop this dotfile.
    build = (ROOT / "app/macos/build-app.sh").read_text(encoding="utf-8")
    copy = re.search(r"^for d in scripts models; do\n.*?^done$", build, re.M | re.S)
    assert copy, "the app's script packaging step is missing"
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(["sh", "-ec", copy.group()], check=True,
                       env={**os.environ, "ROOT": str(ROOT), "SK": directory}, capture_output=True)
        assert (Path(directory) / "scripts/.python-version").read_bytes() == (SCRIPTS / ".python-version").read_bytes()
