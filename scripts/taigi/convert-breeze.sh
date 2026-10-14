#!/bin/bash
# convert-breeze.sh — 聯發科 Breeze-ASR-26（台語聽打，Apache-2.0）官方權重 → Hearby 用的 whisper.cpp 模型檔
#
# 為什麼自己轉、不直接拿社群轉好的：成品要放進 Hearby 讓使用者下載，來源要能從官方權重一路重現、
# 每一步都對得上 sha256。社群版（weemed/Breeze-ASR-26-GGML 等）可以拿來對照，但不當正本。
#
# 需要：whisper.cpp v1.9.1 原始碼（轉檔腳本）、openai/whisper（mel 濾波表）、
#       Python 3.12 + torch + transformers + numpy、whisper-quantize（brew install whisper-cpp 就有）
# 用法：bash scripts/taigi/convert-breeze.sh <工作夾>
#   工作夾裡會有 hf/Breeze-ASR-26（官方權重）、src/whisper.cpp、src/openai-whisper、venv、models/（成品）
set -euo pipefail
W="${1:?工作夾}"; cd "$W"
REV=7b992682e7f5ceedd0a41ebec240f01ba469d19e     # Hugging Face MediaTek-Research/Breeze-ASR-26 的版本
HF=hf/Breeze-ASR-26
SHA=(   # 檔名:sha256（macOS 內建 bash 3.2 沒有關聯陣列）
  "model-00001-of-00002.safetensors:78e177c9a5228eed20f1f33485f8288bda5308a077fa7758281088c2a3100535"
  "model-00002-of-00002.safetensors:9c1f45081c3a2a606a1dc75e02653770956279d2942015587cf4880879952a7e"
)

echo "── ① 官方權重（$REV）"
mkdir -p "$HF"
for f in added_tokens.json config.json generation_config.json merges.txt model.safetensors.index.json normalizer.json \
         preprocessor_config.json special_tokens_map.json tokenizer_config.json vocab.json \
         model-00001-of-00002.safetensors model-00002-of-00002.safetensors; do
  [ -s "$HF/$f" ] || curl -sSL --retry 5 -C - -o "$HF/$f" "https://huggingface.co/MediaTek-Research/Breeze-ASR-26/resolve/$REV/$f"
done
for p in "${SHA[@]}"; do
  f=${p%%:*}; got=$(shasum -a 256 "$HF/$f" | cut -d' ' -f1)
  [ "$got" = "${p##*:}" ] || { echo "✗ $f sha256 不符：$got"; exit 1; }
done
echo "   兩個權重檔 sha256 跟官方一致"

echo "── ② 工具"
mkdir -p src models
[ -d src/whisper.cpp ] || git clone -q --branch v1.9.1 --depth 1 https://github.com/ggml-org/whisper.cpp src/whisper.cpp
[ -d src/openai-whisper ] || git clone -q --depth 1 https://github.com/openai/whisper src/openai-whisper
[ -x venv/bin/python ] || { uv venv -q --python 3.12 venv && VIRTUAL_ENV="$W/venv" uv pip install -q torch transformers numpy safetensors; }
Q=$(command -v whisper-quantize || echo src/whisper.cpp/build/bin/whisper-quantize)
[ -x "$Q" ] || { echo "✗ 找不到 whisper-quantize（brew install whisper-cpp）"; exit 1; }

echo "── ③ 轉成 ggml（f16）"
OUT=models/ggml-breeze-asr-26.bin
if [ ! -f "$OUT" ]; then
  tmp=$(mktemp -d)
  venv/bin/python src/whisper.cpp/models/convert-h5-to-ggml.py "$HF" src/openai-whisper "$tmp" > "$tmp/convert.log"
  mv "$tmp/ggml-model.bin" "$OUT"
fi

echo "── ④ 量化"
for q in q5_0 q8_0; do
  [ -f "models/ggml-breeze-asr-26-$q.bin" ] || "$Q" "$OUT" "models/ggml-breeze-asr-26-$q.bin" "$q" > /dev/null 2>&1
done

echo "── 成品"
for f in models/ggml-breeze-asr-26*.bin; do
  printf "  %-36s %6s MB  %s\n" "$(basename "$f")" "$(( $(stat -f %z "$f") / 1048576 ))" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
done
