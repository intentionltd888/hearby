#!/bin/bash
# vendor-fetch.sh — 把聽打引擎（whisper.cpp 可攜包）放進 vendor/whisper（build.sh 會從那裡拿）
#   ① 這台機器上已有組好的引擎（姊妹專案的 vendor/whisper）→ 直接複製
#   ② 沒有 → scripts/vendor-build.sh 從源碼編（M 系列約 10 分鐘）
# 指定來源：HEARBY_ENGINE_SRC=/path/to/vendor bash scripts/vendor-fetch.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${HEARBY_ENGINE_SRC:-}"
if [ -z "$SRC" ]; then
  for c in ../../*/*/vendor ../../*/vendor ../../*/*/*/vendor; do
    [ -d "$c/whisper" ] && [ -x "$c/whisper/whisper-cli" ] && { SRC="$c"; break; }
  done
fi
if [ -n "$SRC" ] && [ -d "$SRC/whisper" ]; then
  echo "── 從本機既有引擎複製：$SRC/whisper ──"
  if [ -d vendor/whisper ]; then chmod -R u+w vendor/whisper; mv vendor/whisper "$(mktemp -d)/whisper-superseded"; fi
  mkdir -p vendor/whisper
  cp "$SRC/whisper"/* vendor/whisper/
  chmod u+w vendor/whisper/*
  echo "   whisper：$(ls vendor/whisper | wc -l | tr -d ' ') 檔"
else
  echo "── 找不到現成引擎，改從源碼編 ──"
  bash scripts/vendor-build.sh
fi
echo "── 驗證 ──"
BAD=0
for f in vendor/whisper/*; do
  file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
  while IFS= read -r dep; do echo "   ✗ $(basename "$f") 連到包外絕對路徑：$dep"; BAD=1; done \
    < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E '^/(opt|usr/local)/' || true)
done
[ "$BAD" = "1" ] && { echo "✗ 引擎包不乾淨，請改跑 bash scripts/vendor-build.sh"; exit 1; }
# 複製來的引擎可能是在別的目錄編的，二進位裡會帶那台機器的路徑：一樣要過成品清洗
bash scripts/check-binary.sh vendor/whisper >/dev/null || { echo "✗ 這包引擎帶著建置機的路徑——請改跑 bash scripts/vendor-build.sh 從源碼重編"; exit 1; }
echo "✅ vendor/whisper 就緒（$(vendor/whisper/whisper-cli --help 2>&1 | head -1 | cut -c1-60)）"
