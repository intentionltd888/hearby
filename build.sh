#!/bin/bash
# Hearby — build：swift build → 組 .app → 帶資源 bundle 與品牌 → 圖示 → 引擎 → 簽名
#
# 只做「能跑的 .app」，不出 DMG、不公證（那兩步在 scripts/make-dmg.sh 與 scripts/notarize.sh）。
# 引擎（whisper）從 vendor/ 拿；vendor/ 不進 git。
# 簽名：鑰匙圈有 Developer ID Application 就用它（hardened runtime＋時間戳，可公證）；沒有就 ad-hoc。
#       指定憑證：HEARBY_SIGN_IDENTITY="Developer ID Application: …" bash build.sh；強制 ad-hoc：HEARBY_SIGN_IDENTITY=-
# 全程不刪檔（覆蓋式重建；要換掉的舊夾一律 mv 走，不 rm）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Hearby"
BUILD="${HEARBY_BUILD_DIR:-build}"
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
SIGN="${HEARBY_SIGN_IDENTITY:-}"
if [ -z "$SIGN" ]; then
  SIGN=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  SIGN="${SIGN:--}"
fi

mkdir -p "$MACOS" "$RES" "$BUILD"

echo "── 1/5 swift build（release）──"
# 出貨用的 release 在中性的暫存路徑建：SwiftPM 自動產生的資源包存取器會把「建置目錄的絕對路徑」寫死進二進位，
# 在專案夾裡建的話，成品就帶著這台機器的帳號名與資料夾結構。開發用的 swift build／swift test 照舊用 .build。
SCRATCH="${HEARBY_SCRATCH:-/tmp/hearby-release-build}"
swift build -c release --product "$APP_NAME" --scratch-path "$SCRATCH" 2>&1 | tail -3
BIN="$SCRATCH/release/$APP_NAME"
cp "$BIN" "$MACOS/$APP_NAME"
# release 也帶除錯符號表（每個原始檔的絕對目錄都在裡面）：出貨的那份剝掉。-S 除錯符號、-x 本地符號；簽名在後面才做。
strip -S -x "$MACOS/$APP_NAME" 2>/dev/null || true
cp app/Info.plist "$APP/Contents/Info.plist"

echo "── 2/5 資源 bundle（HearbyUI 的 Resources/Brand）與 AGENTS.md ──"
RB="$SCRATCH/release/hearby-mac_HearbyUI.bundle"
if [ -d "$RB" ]; then
  [ -d "$RES/hearby-mac_HearbyUI.bundle" ] && mv "$RES/hearby-mac_HearbyUI.bundle" "$(mktemp -d)/superseded.bundle"
  cp -R "$RB" "$RES/"
else
  echo "   ⚠ 找不到 $RB——品牌圖會退成文字"
fi
cp AGENTS.md "$RES/AGENTS.md"
# 授權聲明跟著成品走（MIT 要求版權聲明隨每一份拷貝）
cp LICENSE "$RES/LICENSE"
cp THIRD-PARTY.md "$RES/THIRD-PARTY.md"

echo "── 3/5 App 圖示 ──"
ICON_SRC="Sources/HearbyUI/Resources/Brand/hearby_appicon_1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz * 2))
  sips -z $dbl $dbl "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

echo "── 4/5 引擎 ──"
if [ -d vendor/whisper ]; then
  [ -d "$RES/whisper" ] && { chmod -R u+w "$RES/whisper"; mv "$RES/whisper" "$(mktemp -d)/whisper-superseded"; }
  mkdir -p "$RES/whisper"
  # 只帶 app 會用到的：whisper-cli＋它連的 libwhisper.1／libggml.0／libggml-base.0＋後端 .so。
  # 不帶 whisper-server（app 不開伺服器）與帶完整版號的重複 dylib（libggml.0.15.1 等＝同一檔另一個名字，各 0.4–0.7 MB）。
  for f in vendor/whisper/*; do
    b=$(basename "$f")
    case "$b" in
      whisper-server) continue;;
      *.[0-9]*.[0-9]*.[0-9]*.dylib) continue;;
      libwhisper.dylib|libggml.dylib|libggml-base.dylib) continue;;   # 不帶版號的那份也是同一檔另一個名字
    esac
    cp "$f" "$RES/whisper/"
  done
  chmod u+w "$RES/whisper"/*
  echo "   whisper：$(ls "$RES/whisper" | wc -l | tr -d ' ') 檔（$(du -sh "$RES/whisper" | cut -f1)）"
else
  echo "   （尚無 vendor/whisper——先跑 bash scripts/vendor-fetch.sh；這顆 .app 不會自帶引擎）"
fi

echo "── 4b 出貨閘：資源包要從 app 自己的路徑找得到（不能靠這台的 .build）──"
"$MACOS/$APP_NAME" --check-resources || { echo "✗ 資源包位置不對，這顆 app 在別人機器上會退成文字字標"; exit 1; }

echo "── 5/5 簽名（$SIGN）──"
# 由內而外、每個 Mach-O 各簽一次（不用 --deep：--deep 不會把 hardened runtime 帶進巢狀二進位，公證會退件）。
# Developer ID＝hardened runtime＋時間戳；ad-hoc 沒有時間戳可打。
# 展開寫法 ${OPTS[@]+"${OPTS[@]}"}：macOS 內建 bash 3.2 在 set -u 下展開空陣列會 unbound variable 中止
OPTS=()
if [ "$SIGN" = "-" ]; then echo "   ad-hoc（只能自己機器跑；要給人裝請裝 Developer ID 憑證）"; else OPTS=(--options runtime --timestamp); echo "   hardened runtime＋時間戳"; fi
if [ -d "$RES/whisper" ]; then
  for f in "$RES/whisper"/*; do
    file -b "$f" | grep -q "Mach-O" || continue
    codesign --force --sign "$SIGN" ${OPTS[@]+"${OPTS[@]}"} "$f" 2>&1 | grep -v "replacing existing signature" || true
  done
fi
codesign --force --sign "$SIGN" ${OPTS[@]+"${OPTS[@]}"} --entitlements app/Hearby.entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$APP" && echo "   簽名驗證 ok"

# 出貨閘：包內每個 Mach-O 的 minos 不得高於 LSMinimumSystemVersion（引擎在新系統抓來的話，舊系統 Metal 載不起、悄悄退 CPU 慢 30 倍）
MINOS_REQ=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" app/Info.plist 2>/dev/null || echo "14.0")
BAD=0
while IFS= read -r f; do
  file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
  m=$(otool -l "$f" 2>/dev/null | grep -A4 LC_BUILD_VERSION | grep minos | head -1 | awk '{print $2}')
  [ -z "$m" ] && continue
  if [ "$(printf '%s\n%s\n' "$MINOS_REQ" "$m" | sort -V | tail -1)" != "$MINOS_REQ" ]; then echo "   ✗ $(basename "$f") minos $m > $MINOS_REQ"; BAD=1; fi
done < <(find "$APP" -type f)
[ "$BAD" = "1" ] && { echo "✗ 有二進位的最低系統版高於 $MINOS_REQ——引擎請用 scripts/vendor-build.sh 重編"; exit 1; }
echo "   minos ≤ $MINOS_REQ ok"

# 出貨閘：成品不得帶著建置機的路徑、帳號名、主機名（原始碼乾淨不代表二進位乾淨）
bash scripts/check-binary.sh "$APP" || exit 1
echo "✅ $APP"
