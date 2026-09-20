#!/bin/bash
# check-binary.sh — 公開前的清洗總掃（成品）：.app／DMG 掛載點／任何資料夾裡，不得帶著建置機的痕跡
#
# 為什麼：編譯器會把「編譯當下的絕對路徑」寫進二進位（斷言訊息的 __FILE__、cmake 的 rpath、除錯資訊），
#   路徑裡有帳號名與資料夾結構。原始碼乾淨不代表成品乾淨，所以成品另外掃。
# 怎麼掃：對每個檔做整檔位元組比對（grep -a）。不用 strings——macOS 的 strings -a 看不到載入指令裡的 rpath。
# 用法：bash scripts/check-binary.sh build/Hearby.app
set -uo pipefail
TARGET="${1:-build/Hearby.app}"
[ -e "$TARGET" ] || { echo "找不到 $TARGET"; exit 1; }
ME=$(id -un); HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
# /tmp 底下的中性建置路徑（vendor-build.sh、build.sh 的預設）不算——裡面沒有帳號名；帳號名與主機名另外比對
PAT="/Users/[A-Za-z0-9._-]+/|-Users-[A-Za-z0-9]|/var/folders/"
[ "${#ME}" -ge 3 ] && PAT="$PAT|$ME"
[ "${#HOST}" -ge 3 ] && PAT="$PAT|$HOST"
FAIL=0; N=0
while IFS= read -r f; do
  N=$((N+1))
  c=$(LC_ALL=C grep -acE "$PAT" "$f" 2>/dev/null || true)
  [ "${c:-0}" -gt 0 ] || continue
  FAIL=1
  echo "✗ ${f#$TARGET/}（$c 處）"
  LC_ALL=C grep -aoE "[ -~]{0,24}($PAT)[ -~]{0,60}" "$f" 2>/dev/null | sort -u | head -3 | sed 's/^/     /'
done < <(find "$TARGET" -type f)
if [ "$FAIL" = "0" ]; then echo "✅ 成品乾淨（$N 檔，沒有建置機的路徑、帳號名、主機名）"; exit 0; fi
echo "❌ 成品帶著建置機的痕跡——引擎請用 scripts/vendor-build.sh 重編；主程式請查是誰把絕對路徑寫進字串"; exit 1
