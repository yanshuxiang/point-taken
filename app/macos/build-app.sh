#!/bin/sh
# 本地编译「Point Taken.app」（中文系统显示「懂你意思」）并装到 /Applications（不需要 uv / Python，不下载任何模型）。
# bundle id 是 io.github.yanshuxiang.pointtaken。
# 用 Xcode 自带的工具链（系统默认的命令行工具太旧，编不过）。
set -e
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."      # 仓库根目录：scripts/、models/、assets/ 在这里
APP="/Applications/Point Taken.app"
ID="io.github.yanshuxiang.pointtaken"
# 记下真实的 SDK 版本：不然新版构建系统把 13.0 写成 SDK 版本，系统按 macOS 13 的老样子画界面（没有液态玻璃）
export POINT_TAKEN_SDK_VERSION="${POINT_TAKEN_SDK_VERSION:-$(xcrun --sdk macosx --show-sdk-version)}"

swift build -c release --package-path "$HERE" --product point-taken
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/point-taken"

osascript -e "quit app id \"$ID\"" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/point-taken" 2>/dev/null || true
sleep 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/point-taken"
strip -S -x "$APP/Contents/MacOS/point-taken" || true
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
[ -d "$HERE/ThirdParty" ] && cp -R "$HERE/ThirdParty" "$APP/Contents/Resources/"
R="$HERE/Sources/PointTakenApp/Resources"
for d in "$R"/*.lproj; do [ -e "$d" ] && cp -R "$d" "$APP/Contents/Resources/"; done
[ -f "$R/Assets.car" ] && cp "$R/Assets.car" "$APP/Contents/Resources/"
cp "$ROOT/assets/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 转写、实时字幕都靠 Python 脚本：scripts/ 和 models/ 打进 Resources/skill，启动时复制到 ~/.point-taken/skill。
# 少了它，所有转写都会报「找不到脚本」。.version 用脚本内容的哈希，脚本一改，下次启动就换上新的。
SK="$APP/Contents/Resources/skill"
mkdir -p "$SK"
for d in scripts models; do
  rsync -a --exclude __pycache__ --exclude .DS_Store --exclude '*.pyc' "$ROOT/$d/" "$SK/$d/"
done
printf 'local-%s\n' "$(cd "$SK" && find . -type f ! -name .version | LC_ALL=C sort | xargs shasum | shasum | cut -c1-12)" > "$SK/.version"
[ -f "$SK/scripts/_common.py" ] && [ -f "$SK/scripts/transcribe.py" ] && [ -f "$SK/scripts/board_live.py" ] \
  || { echo "打包的脚本不完整：$SK" >&2; exit 1; }

# 签名：有 Apple Development 证书就用它（重新编译后系统记得给过的权限，不用每次重给）；没有就退回 ad-hoc
CERT="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$CERT" ]; then
  codesign --force --sign "$CERT" --identifier "$ID" "$APP"
else
  codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$APP"
fi
codesign -d -r- "$APP" 2>&1 | tail -1
echo "装好了：$APP"
open "$APP"
