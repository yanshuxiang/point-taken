#!/bin/sh
# 编译「Point Taken.app」并打成 dmg，放到仓库根目录的 dist/（不装到 /Applications）。
# 命名规则见 docs/发布与命名规则.md：PointTaken-<版本>-macos-<架构>.dmg，旁边带一份 .sha256。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$HERE/Info.plist")"
ARCH="${POINT_TAKEN_ARCH:-$(uname -m)}"   # arm64 / x86_64
NAME="PointTaken-$VER-macos-$ARCH"
STAGE="$ROOT/dist/stage-$NAME"
DMG="$ROOT/dist/$NAME.dmg"

rm -rf "$STAGE"
POINT_TAKEN_APP="$STAGE/Point Taken.app" "$HERE/build-app.sh"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "Point Taken $VER" -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
(cd "$ROOT/dist" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
[ -n "$(git -C "$ROOT" status --porcelain)" ] && echo "注意：工作区有没提交的改动，这个 dmg 和任何提交都对不上。" >&2
echo "打好了：$DMG"
