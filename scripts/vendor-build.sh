#!/bin/bash
# vendor-build.sh — 從源碼編 whisper.cpp 成「macOS 14 起可用」的可攜引擎包（vendor/whisper）
# 為什麼要自己編：brew bottle 是當前 macOS 編的，在舊系統上 Metal 後端 dlopen 失敗→悄悄退 CPU、慢 30 倍。
# -ffile-prefix-map：斷言訊息裡的 __FILE__ 會把「編譯時的絕對路徑」寫進二進位；對映成相對路徑，成品不帶建置機的目錄。
set -euo pipefail
cd "$(dirname "$0")/.."
WHISPER_TAG="${WHISPER_TAG:-v1.9.1}"
TARGET="14.0"
SRC="${VENDOR_SRC:-/tmp/hearby-engine-src}"
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$SRC"
if [ ! -d "$SRC/whisper.cpp/.git" ]; then git clone --branch "$WHISPER_TAG" --depth 1 https://github.com/ggml-org/whisper.cpp "$SRC/whisper.cpp"; fi
cmake -S "$SRC/whisper.cpp" -B "$SRC/whisper.cpp/build-t14" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
  -DBUILD_SHARED_LIBS=ON -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$SRC=." -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$SRC=." -DCMAKE_OBJC_FLAGS="-ffile-prefix-map=$SRC=." >/dev/null
cmake --build "$SRC/whisper.cpp/build-t14" -j "$JOBS" --target whisper-cli >/dev/null
dest=vendor/whisper
[ -d "$dest" ] && mv "$dest" "$(mktemp -d)/whisper-superseded"
mkdir -p "$dest"
tree="$SRC/whisper.cpp/build-t14"
cp -f "$(find "$tree/bin" -name whisper-cli -type f | head -1)" "$dest/"
# -L：連「libwhisper.1.dylib → libwhisper.1.9.1.dylib」這種符號連結也複製成實體檔（whisper-cli 連的是短名；build.sh 只帶短名那份）
find "$tree/bin" \( -name "*.dylib" -o -name "*.so" \) \( -type f -o -type l \) -exec cp -fL {} "$dest/" \;
chmod u+w "$dest"/*
# 參照全改 @loader_path
for f in "$dest"/*; do
  file -b "$f" | grep -q "Mach-O" || continue
  # cmake 會把建置目錄寫成 rpath：拿掉，只留 @loader_path（不然成品帶著建置機的路徑，而且只有這台機器跑得動）
  otool -l "$f" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | { grep -v '^@loader_path$' || true; } | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
  done
  install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
  otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E "^(/|@rpath)" | while read -r dep; do
    base=$(basename "$dep")
    [ -f "$dest/$base" ] && install_name_tool -change "$dep" "@loader_path/$base" "$f" 2>/dev/null || true
  done
  codesign --force -s - "$f" >/dev/null 2>&1 || true
done
echo "✅ vendor/whisper 編好（$WHISPER_TAG，minos $TARGET）"
