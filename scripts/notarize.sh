#!/bin/bash
# notarize.sh — Apple 公證＋釘票，兩段：① app 本體（zip 送審→釘票在 app 上）② 用釘好票的 app 打 DMG→送審→釘票在 DMG 上。
# 為什麼兩段：只釘 DMG 的話，對方把 app 拖出來後 app 本身沒票，Gatekeeper 要連 Apple 查；離線或公司網路擋住就「無法打開」。
# 公證過的 DMG 用 AirDrop／網路給任何 Mac，打開零警告。
#
# 前提：① app 是 Developer ID 簽名（build.sh 鑰匙圈有憑證就自動用）
#      ② notarytool 憑據已存鑰匙圈：xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password <app 專用密碼>
# profile 名怎麼找（依序）：HEARBY_NOTARY_PROFILE 環境變數 → 倉根 .notary-profile 檔（不進 git，一台機器寫一次）→ 預設 hearby-notary
# 用法：bash build.sh && bash scripts/notarize.sh   （這支會自己叫 make-dmg.sh；Apple 端每段通常 1–10 分鐘，--wait 會等完）
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${HEARBY_BUILD_DIR:-build}"
APP="$BUILD/Hearby.app"
PROFILE="${HEARBY_NOTARY_PROFILE:-}"
[ -z "$PROFILE" ] && [ -f .notary-profile ] && PROFILE=$(tr -d '[:space:]' < .notary-profile)
PROFILE="${PROFILE:-hearby-notary}"
[ -d "$APP" ] || { echo "找不到 $APP——先跑 bash build.sh"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$BUILD/Hearby-$VER-build$BLD.dmg"

# 不可用「codesign | grep -q」：pipefail 下 grep -q 提早關管會讓 codesign 吃 SIGPIPE 誤判失敗
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
echo "$SIGN_INFO" | grep -q "Developer ID Application" \
  || { echo "app 不是 Developer ID 簽名——確認憑證已裝（security find-identity -v -p codesigning）後重跑 build.sh"; exit 1; }
echo "$SIGN_INFO" | grep -q "flags=0x10000(runtime)" \
  || { echo "app 沒開 hardened runtime——重跑 build.sh"; exit 1; }

echo "── ①/④ app 本體送審（profile：$PROFILE）──"
WORK=$(mktemp -d /tmp/hearby-notarize.XXXXXX)
ZIP="$WORK/Hearby-$VER-build$BLD.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
echo "── ②/④ 釘票在 app 上 ──"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" >/dev/null && echo "   ✓ app 有票"

echo "── ③/④ 用釘好票的 app 打 DMG ──"
bash scripts/make-dmg.sh
[ -f "$DMG" ] || { echo "找不到 $DMG"; exit 1; }
# 出貨閘：DMG 裡的 app 必須就是現在這顆 $APP（cdhash 逐位核對；防公證到舊包）
APP_CD=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ && !p {print $2; p=1}')
MNT=$(mktemp -d)
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null
DMG_CD=$(codesign -dvvv "$MNT/Hearby.app" 2>&1 | awk -F= '/^CDHash=/ && !p {print $2; p=1}')
xcrun stapler validate "$MNT/Hearby.app" >/dev/null && echo "   ✓ DMG 內的 app 帶著票" || { echo "✗ DMG 內的 app 沒票"; hdiutil detach "$MNT" >/dev/null; exit 1; }
hdiutil detach "$MNT" >/dev/null
if [ -z "$APP_CD" ] || [ "$APP_CD" != "$DMG_CD" ]; then
  echo "✗ 擋下：DMG 內的 app（${DMG_CD:-?}）≠ 現在的 $APP（${APP_CD:-?}）"
  exit 1
fi
echo "   ✓ 同一顆（cdhash $APP_CD）"

echo "── ④/④ DMG 送審＋釘票 ──"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" >/dev/null && echo "   ✓ DMG 有票"

echo "── Gatekeeper 驗證 ──"
spctl -a -vv -t open --context context:primary-signature "$DMG" && echo "✓ DMG 通過 Gatekeeper"
spctl -a -vv -t execute "$APP" && echo "✓ app 通過 Gatekeeper"
echo "✅ 公證完成：$DMG（對方拖進 Applications、雙擊打開，零警告；離線也過）"
