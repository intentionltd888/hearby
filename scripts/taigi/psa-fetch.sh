#!/bin/bash
# psa-fetch.sh — 下載行政院「廣播公益廣告月包」當國台語測試素材（官方 benchmark 同一個來源）
# 來源頁：https://www.ey.gov.tw/Page/AA7FD03FF4A55EF8（音檔下載區）；每包內含華／臺／客語音檔與廣告腳本
# 用法：bash scripts/taigi/psa-fetch.sh <輸出夾>
set -euo pipefail
OUT="${1:?輸出夾}"; mkdir -p "$OUT"; cd "$OUT"
PACKS=(  # 月份:檔案代號（取自各月月包頁的下載連結）
  "11302:69490A841325D976"
  "11507:845B51EEEE0DF17F"
  "11508:3DB9C5897C7A39F1"
  "11509:9F1E287FCEE6B20C"
  "11510:F6486039EEC76561"
)
for p in "${PACKS[@]}"; do
  n=${p%%:*}; f=${p##*:}
  [ -d "x$n" ] && continue
  curl -sSL --retry 3 -A "Mozilla/5.0" -o "ey_$n.zip" "https://www.ey.gov.tw/File/$f?A=C"
  mkdir -p "x$n" && ditto -x -k "ey_$n.zip" "x$n"
  echo "✓ $n：$(find "x$n" \( -name '*.mp3' -o -name '*.wav' \) | wc -l | tr -d ' ') 個音檔"
done
