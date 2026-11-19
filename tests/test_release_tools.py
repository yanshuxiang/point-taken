""".github/scripts/release.py and the one-version rule (docs/发布与命名规则.md): VERSION is the only place a version is
written, the release notes come from CHANGELOG.md, and the uploaded files are named and checksummed by the rules.

  uv run --with pytest pytest tests/test_release_tools.py -q
"""
from __future__ import annotations

import hashlib
import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("release_tools", ROOT / ".github" / "scripts" / "release.py")
R = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(R)


class Version(unittest.TestCase):
    def test_version_file_is_semver(self):
        R.read_version()

    def test_semver(self):
        for ok in ("0.2.0", "1.0.0-beta.1", "0.2.0-rc.10", "10.20.30"):
            self.assertTrue(R.SEMVER.match(ok), ok)
        for bad in ("0.2", "v0.2.0", "0.2.0-", "01.2.3", "0.2.0 beta", "0.2.0-beta..1"):
            self.assertFalse(R.SEMVER.match(bad), bad)

    def test_tag_must_match(self):
        self.assertEqual(R.info("0.2.0-beta.2", "v0.2.0-beta.2")["prerelease"], "true")
        self.assertEqual(R.info("0.2.0", None)["prerelease"], "false")
        self.assertEqual(R.info("0.2.0", "v0.2.0")["title"], "Point Taken 0.2.0")
        with self.assertRaises(R.ReleaseError):
            R.info("0.2.0", "v0.2.1")

    def test_no_second_version_source(self):
        # the apps read VERSION at build time; a version written anywhere else would drift
        csproj = (ROOT / "app/windows/PointTaken.App/PointTaken.App.csproj").read_text(encoding="utf-8")
        self.assertNotRegex(csproj, r"<(Version|VersionPrefix|AssemblyVersion|FileVersion)>")
        plist = (ROOT / "app/macos/Info.plist").read_text(encoding="utf-8")
        short = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>", plist)
        self.assertEqual(short.group(1), "0.0.0")
        self.assertIn("VERSION", (ROOT / "app/windows/Directory.Build.props").read_text(encoding="utf-8"))
        self.assertIn('"$ROOT/VERSION"', (ROOT / "app/macos/build-app.sh").read_text(encoding="utf-8"))


class Notes(unittest.TestCase):
    CHANGELOG = "# Changelog\n\n## [Unreleased]\n\n## [0.2.0-beta.2] - 2026-11-19\n\n### Added\n- thing\n\n" \
                "## [0.2.0-beta.1] - 2026-11-18\n- old\n\n[Unreleased]: https://x\n[0.2.0-beta.2]: https://y\n"

    def test_section(self):
        self.assertEqual(R.changelog_section(self.CHANGELOG, "0.2.0-beta.2"), "### Added\n- thing")
        self.assertEqual(R.changelog_section(self.CHANGELOG, "0.2.0-beta.1"), "- old")

    def test_missing_or_empty(self):
        with self.assertRaises(R.ReleaseError):
            R.changelog_section(self.CHANGELOG, "0.2.0")
        with self.assertRaises(R.ReleaseError):
            R.changelog_section(self.CHANGELOG, "Unreleased")

    def test_prefix_is_not_a_match(self):
        with self.assertRaises(R.ReleaseError):
            R.changelog_section(self.CHANGELOG, "0.2.0-beta")

    def test_real_changelog_has_current_version(self):
        text = R.notes(R.read_version())
        self.assertIn(f"PointTaken-{R.read_version()}-windows-x64-setup.exe", text)
        self.assertNotIn("{version}", text)


class Verify(unittest.TestCase):
    def _write(self, d: Path, name: str, data: bytes = b"x", sums: str | None = None):
        (d / name).write_bytes(data)
        h = hashlib.sha256(data).hexdigest()
        (d / f"{name}.sha256").write_bytes((sums if sums is not None else f"{h}  {name}\n").encode("ascii"))

    def test_good(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            for n in ("PointTaken-0.2.0-beta.2-macos-arm64.dmg", "PointTaken-0.2.0-beta.2-windows-x64.zip",
                      "PointTaken-0.2.0-beta.2-windows-x64-setup.exe"):
                self._write(d, n)
            self.assertEqual(len(R.verify(d, "0.2.0-beta.2")), 3)

    def test_bad(self):
        cases = [("Point Taken 0.2.0.dmg", None), ("PointTaken-0.2.0-macos-arm64.dmg", "0" * 64 + "  PointTaken-0.2.0-macos-arm64.dmg"),
                 ("PointTaken-0.2.1-windows-x64.zip", None)]
        for name, sums in cases:
            with tempfile.TemporaryDirectory() as t:
                d = Path(t)
                self._write(d, name, sums=sums)
                with self.assertRaises(R.ReleaseError, msg=name):
                    R.verify(d, "0.2.0")

    def test_crlf_checksum(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            name = "PointTaken-0.2.0-windows-x64.zip"
            self._write(d, name, sums=f"{hashlib.sha256(b'x').hexdigest()}  {name}\r\n")
            with self.assertRaises(R.ReleaseError):
                R.verify(d)

    def test_missing_checksum(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            (d / "PointTaken-0.2.0-macos-arm64.dmg").write_bytes(b"x")
            with self.assertRaises(R.ReleaseError):
                R.verify(d)


if __name__ == "__main__":
    unittest.main()
