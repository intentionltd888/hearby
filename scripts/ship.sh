#!/bin/bash
# ship.sh — 把公證好的 DMG 放進出貨夾 ../2_版本/（給人的唯一來源），舊版移到 ../_archive/2_版本/。
#
# 為什麼要有這支：沒公證的 DMG 一旦被手動放進出貨夾，拿到的人會被 Gatekeeper 以「Unnotarized Developer ID」
# 擋下（看起來像「公鑰沒放進去」）。出貨夾只能放「清洗過、有票」的 DMG，這裡用機器擋。
# 用法：bash build.sh && bash scripts/notarize.sh && bash scripts/ship.sh
# 全程不刪檔：舊 DMG 只 mv 到 ../_archive/2_版本/。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${HEARBY_BUILD_DIR:-build}"
APP="$BUILD/Hearby.app"
SHIP="../2_版本"
OLD="../_archive/2_版本"
[ -d "$APP" ] || { echo "找不到 $APP——先跑 bash build.sh"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$BUILD/Hearby-$VER-build$BLD.dmg"
[ -f "$DMG" ] || { echo "找不到 $DMG——先跑 bash scripts/notarize.sh"; exit 1; }

echo "── 出貨閘：原始碼與成品都要洗乾淨 ──"
bash scripts/check-clean.sh --strict >/dev/null || { echo "✗ check-clean 沒過——跑 bash scripts/check-clean.sh --strict 看哪裡"; exit 1; }
bash scripts/check-binary.sh "$APP" >/dev/null || { echo "✗ 成品帶著建置機的痕跡——跑 bash scripts/check-binary.sh $APP 看哪裡"; exit 1; }
echo "   ✓ 原始碼與成品都乾淨"

echo "── 出貨閘：DMG 與裡面的 app 都要帶票 ──"
xcrun stapler validate "$DMG" >/dev/null || { echo "✗ $DMG 沒有公證票——先跑 bash scripts/notarize.sh，沒票的 DMG 不進出貨夾"; exit 1; }
MNT=$(mktemp -d)
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null
INNER_OK=0
xcrun stapler validate "$MNT/Hearby.app" >/dev/null && INNER_OK=1
INNER_BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$MNT/Hearby.app/Contents/Info.plist")
DMG_CLEAN=0; bash scripts/check-binary.sh "$MNT" >/dev/null && DMG_CLEAN=1   # 連 .DS_Store 與背景圖一起掃
hdiutil detach "$MNT" >/dev/null
[ "$INNER_OK" = "1" ] || { echo "✗ DMG 內的 app 沒票（對方離線也要能開）——重跑 notarize.sh"; exit 1; }
[ "$DMG_CLEAN" = "1" ] || { echo "✗ DMG 裡有檔案帶著建置機的痕跡——掛起來跑 bash scripts/check-binary.sh <掛載點> 看哪裡"; exit 1; }
[ "$INNER_BLD" = "$BLD" ] || { echo "✗ DMG 內是 build $INNER_BLD，不是 build $BLD"; exit 1; }
spctl -a -t open --context context:primary-signature "$DMG" >/dev/null 2>&1 || { echo "✗ Gatekeeper 不放行這顆 DMG"; exit 1; }
echo "   ✓ DMG 有票、app 有票、Gatekeeper 放行（build $BLD）"

echo "── 放進出貨夾 ──"
mkdir -p "$OLD"
for f in "$SHIP"/Hearby-*.dmg; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "$(basename "$DMG")" ] && continue
  mv "$f" "$OLD/" && echo "   舊版 → _archive/2_版本/$(basename "$f")"
done
cp -f "$DMG" "$SHIP/"
touch "$SHIP/$(basename "$DMG")"
echo "✅ $SHIP/$(basename "$DMG")（給人就拿這顆）"
