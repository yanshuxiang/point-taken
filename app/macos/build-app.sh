#!/bin/sh
# 本地编译「Point Taken.app」（中文系统显示「懂你意思」）并装到 /Applications（不需要 uv / Python，不下载任何模型）。
# bundle id 是 io.github.yanshuxiang.pointtaken。
# 用 Xcode 自带的工具链（系统默认的命令行工具太旧，编不过）。
# 版本号来自仓库根目录的 VERSION（docs/发布与命名规则.md）。
# 签名（环境变量，都不设就和以前一样：有 Apple Development 证书用它，没有就 ad-hoc）：
#   POINT_TAKEN_SIGN_IDENTITY  钥匙串里的签名身份，如 "Developer ID Application: 名字 (TEAMID)"；
#                              Developer ID 会开 hardened runtime + 时间戳 + PointTaken.entitlements（公证要求）。
#                              设成 "-" 强制 ad-hoc。
#   POINT_TAKEN_KEYCHAIN       在指定钥匙串里找证书（CI 用临时钥匙串）。
set -e
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."      # 仓库根目录：scripts/、models/、assets/ 在这里
# 设了 POINT_TAKEN_APP 就只编到那个路径（打 dmg 用），不退出、不打开正在用的 App
APP="${POINT_TAKEN_APP:-/Applications/Point Taken.app}"
ID="io.github.yanshuxiang.pointtaken"
# VERSION 是完整的语义化版本（0.2.0-beta.2）；CFBundleShortVersionString 只能是数字（0.2.0），
# CFBundleVersion 用提交数（只增不减），完整版本写到 PointTakenVersion，App 里显示它。
VERSION="$(tr -d ' \r\n' < "$ROOT/VERSION")"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || { echo "VERSION 不是合法的版本号：$VERSION" >&2; exit 1; }
SHORT_VERSION="${VERSION%%-*}"
BUILD_NUMBER="${POINT_TAKEN_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)}"
# 记下真实的 SDK 版本：不然新版构建系统把 13.0 写成 SDK 版本，系统按 macOS 13 的老样子画界面（没有液态玻璃）
export POINT_TAKEN_SDK_VERSION="${POINT_TAKEN_SDK_VERSION:-$(xcrun --sdk macosx --show-sdk-version)}"

swift build -c release --package-path "$HERE" --product point-taken
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/point-taken"

if [ -z "$POINT_TAKEN_APP" ]; then
  osascript -e "quit app id \"$ID\"" 2>/dev/null || true
  pkill -f "$APP/Contents/MacOS/point-taken" 2>/dev/null || true
  sleep 1
fi

rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/point-taken"
strip -S -x "$APP/Contents/MacOS/point-taken" || true
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace PointTakenVersion -string "$VERSION" "$APP/Contents/Info.plist"
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

# 签名。发布：POINT_TAKEN_SIGN_IDENTITY 指定 Developer ID，带 hardened runtime 和时间戳，才能公证。
# 本地：有 Apple Development 证书就用它（重新编译后系统记得给过的权限，不用每次重给）；没有就退回 ad-hoc
KC_ARGS=""
[ -n "$POINT_TAKEN_KEYCHAIN" ] && KC_ARGS="--keychain $POINT_TAKEN_KEYCHAIN"
CERT="${POINT_TAKEN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning $POINT_TAKEN_KEYCHAIN 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
case "$CERT" in
  "Developer ID Application"*)
    # shellcheck disable=SC2086
    codesign --force --sign "$CERT" $KC_ARGS --identifier "$ID" --options runtime --timestamp \
      --entitlements "$HERE/PointTaken.entitlements" "$APP"
    codesign --verify --strict --verbose=2 "$APP" ;;
  ""|-)
    codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$APP" ;;
  *)
    # shellcheck disable=SC2086
    codesign --force --sign "$CERT" $KC_ARGS --identifier "$ID" "$APP" ;;
esac
codesign -d -r- "$APP" 2>&1 | tail -1
echo "装好了：$APP"
[ -z "$POINT_TAKEN_APP" ] && open "$APP"
exit 0
