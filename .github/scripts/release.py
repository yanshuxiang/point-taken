#!/usr/bin/env python3
"""Release helpers for .github/workflows/release.yml and ci.yml (docs/发布与命名规则.md). Standard library only.

  release.py info [--tag v0.2.0-beta.2]      VERSION checked (and equal to the tag) → version, tag, prerelease, title
                                              (also written to $GITHUB_OUTPUT when set)
  release.py notes [--version X] --out FILE  the release notes: CHANGELOG.md's `## [X]` section + .github/release-footer.md
  release.py verify DIR                      every download in DIR is named by the rules and matches its .sha256
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
                    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$")
# PointTaken-<version>-macos-<arch>.dmg, PointTaken-<version>-windows-<arch>.zip / -setup.exe
ASSET = re.compile(r"^PointTaken-(?P<version>[0-9A-Za-z.-]+?)-(?:macos-(?:arm64|x86_64|universal)\.dmg"
                   r"|windows-(?:x64|arm64)(?:\.zip|-setup\.exe))$")


class ReleaseError(Exception):
    pass


def read_version(root: Path = ROOT) -> str:
    v = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not SEMVER.match(v):
        raise ReleaseError(f"VERSION is not a semantic version (x.y.z or x.y.z-beta.N): {v!r}")
    return v


def info(version: str, tag: str | None) -> dict[str, str]:
    if tag is not None and tag != f"v{version}":
        raise ReleaseError(f"tag {tag} does not match VERSION {version}: the tag must be v{version}")
    return {"version": version, "tag": f"v{version}", "prerelease": str("-" in version).lower(),
            "title": f"Point Taken {version}"}


def changelog_section(changelog: str, version: str) -> str:
    lines = changelog.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(rf"^## \[{re.escape(version)}\](\s|$)", l)), None)
    if start is None:
        raise ReleaseError(f"CHANGELOG.md has no '## [{version}]' section: move the Unreleased notes under it")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## [") or re.match(r"^\[[^\]]+\]: ", lines[i])),
               len(lines))
    body = "\n".join(lines[start + 1:end]).strip()
    if not body:
        raise ReleaseError(f"CHANGELOG.md's '## [{version}]' section is empty")
    return body


def notes(version: str, root: Path = ROOT) -> str:
    body = changelog_section((root / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    footer = (root / ".github" / "release-footer.md").read_text(encoding="utf-8").replace("{version}", version)
    return f"{body}\n\n{footer.strip()}\n"


def verify(directory: Path, version: str | None = None) -> list[str]:
    files = sorted(p for p in directory.iterdir() if p.is_file())
    downloads = [p for p in files if not p.name.endswith(".sha256")]
    if not downloads:
        raise ReleaseError(f"no downloads in {directory}")
    problems = []
    for p in downloads:
        m = ASSET.match(p.name)
        if not m:
            problems.append(f"{p.name}: not named by docs/发布与命名规则.md")
        elif version and m["version"] != version:
            problems.append(f"{p.name}: version {m['version']} is not {version}")
        sums = p.with_name(p.name + ".sha256")
        if not sums.exists():
            problems.append(f"{p.name}: no {sums.name}")
            continue
        want = sums.read_text(encoding="ascii").split()
        got = hashlib.sha256(p.read_bytes()).hexdigest()
        if len(want) != 2 or want[0].lower() != got or want[1].lstrip("*") != p.name:
            problems.append(f"{sums.name}: does not match {p.name} (sha256 {got})")
    for s in files:
        if s.name.endswith(".sha256") and not s.with_name(s.name[:-7]).exists():
            problems.append(f"{s.name}: no file it belongs to")
    if problems:
        raise ReleaseError("\n".join(problems))
    return [p.name for p in downloads]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("info"); a.add_argument("--tag")
    a = sub.add_parser("notes"); a.add_argument("--version"); a.add_argument("--out", required=True)
    a = sub.add_parser("verify"); a.add_argument("dir"); a.add_argument("--version")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "info":
            out = info(read_version(), args.tag)
            for k, v in out.items():
                print(f"{k}={v}")
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
                    f.writelines(f"{k}={v}\n" for k, v in out.items())
        elif args.cmd == "notes":
            Path(args.out).write_text(notes(args.version or read_version()), encoding="utf-8")
            print(f"wrote {args.out}")
        elif args.cmd == "verify":
            for name in verify(Path(args.dir), args.version):
                print(f"ok  {name}")
    except ReleaseError as e:
        for line in str(e).splitlines():
            print(f"::error::{line}" if os.environ.get("GITHUB_ACTIONS") else f"error: {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
