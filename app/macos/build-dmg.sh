#!/bin/sh
# 编译「Point Taken.app」并打成 dmg，放到仓库根目录的 dist/（不装到 /Applications）。
# 命名规则见 docs/发布与命名规则.md：PointTaken-<版本>-macos-<架构>.dmg，旁边带一份 .sha256。版本来自仓库根目录的 VERSION。
# 签名和公证都由环境变量打开（发布工作流 .github/workflows/release.yml 就是这样用的）：
#   POINT_TAKEN_SIGN_IDENTITY  "Developer ID Application: 名字 (TEAMID)" → App 和 dmg 都用它签（见 build-app.sh）
#   POINT_TAKEN_KEYCHAIN       证书所在的钥匙串
#   公证（要先有 Developer ID 签名），二选一：
#     APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID   App Store Connect API 密钥（.p8）
#     POINT_TAKEN_NOTARY_PROFILE                                    `xcrun notarytool store-credentials` 存的配置名
# 没有签名身份就是 ad-hoc 签名、不公证（别人打开时要在「系统设置 → 隐私与安全性」里放行）。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VER="$(tr -d ' \r\n' < "$ROOT/VERSION")"
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

case "$POINT_TAKEN_SIGN_IDENTITY" in
  "Developer ID Application"*)
    KC_ARGS=""
    [ -n "$POINT_TAKEN_KEYCHAIN" ] && KC_ARGS="--keychain $POINT_TAKEN_KEYCHAIN"
    # shellcheck disable=SC2086
    codesign --force --sign "$POINT_TAKEN_SIGN_IDENTITY" $KC_ARGS --timestamp "$DMG"
    if [ -n "$APPLE_API_KEY_PATH" ] && [ -n "$APPLE_API_KEY_ID" ] && [ -n "$APPLE_API_ISSUER_ID" ]; then
      NOTARY="--key $APPLE_API_KEY_PATH --key-id $APPLE_API_KEY_ID --issuer $APPLE_API_ISSUER_ID"
    elif [ -n "$POINT_TAKEN_NOTARY_PROFILE" ]; then
      NOTARY="--keychain-profile $POINT_TAKEN_NOTARY_PROFILE"
    else
      NOTARY=""
      echo "注意：没有公证凭据，dmg 已签名但没公证。" >&2
    fi
    if [ -n "$NOTARY" ]; then
      echo "提交公证（通常几分钟）…"
      # shellcheck disable=SC2086
      OUT="$(xcrun notarytool submit "$DMG" $NOTARY --wait --timeout 30m --output-format json)" || true
      echo "$OUT"
      SUB_ID="$(echo "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
      STATUS="$(echo "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
      if [ "$STATUS" != "Accepted" ]; then
        # shellcheck disable=SC2086
        [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" $NOTARY >&2 || true
        echo "公证没通过（$STATUS）" >&2
        exit 1
      fi
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$DMG"
      # Gatekeeper 自检：和用户第一次打开时做的检查一样
      spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    fi ;;
esac

(cd "$ROOT/dist" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
[ -n "$(git -C "$ROOT" status --porcelain)" ] && echo "注意：工作区有没提交的改动，这个 dmg 和任何提交都对不上。" >&2
echo "打好了：$DMG"
