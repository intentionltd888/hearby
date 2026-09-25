#!/bin/bash
# Hearby for Windows — build on macOS or Linux: contract tests → publish (win-x64, self-contained .NET) → Microsoft C++
# runtime next to Hearby.exe → installer (Velopack: Setup.exe + update packages).
#
# Needs: .NET SDK 10 (global.json), cabextract (brew install cabextract), internet the first time (NuGet packages, the
# Microsoft Visual C++ redistributable, the vpk packaging tool). Unsigned: Windows SmartScreen shows "unknown publisher".
# Nothing is deleted: earlier outputs are moved aside into build/windows/superseded/.
#
#   bash windows/build.sh            → build/windows/release/Hearby-Setup.exe (+ packages for updates, SHA256SUMS.txt)
#   HEARBY_SKIP_TESTS=1 bash windows/build.sh
set -euo pipefail
cd "$(dirname "$0")"
WIN="$(pwd)"
ROOT="$(cd .. && pwd)"
OUT="${HEARBY_WIN_OUT:-$ROOT/build/windows}"
CACHE="${HEARBY_WIN_CACHE:-$HOME/.cache/hearby-windows}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
if ! command -v dotnet >/dev/null 2>&1; then export PATH="$HOME/.dotnet:$PATH"; fi
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname "$(readlink -f "$(command -v dotnet)" 2>/dev/null || command -v dotnet)")}"
VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' Directory.Build.props | head -1)
PACK_ID="HearbyApp"   # install folder %LOCALAPPDATA%\HearbyApp (not "Hearby": that name is the app's data folder)
VPK_VERSION="1.2.158"

# Microsoft Visual C++ 2015–2022 runtime (x64), 14.44.35211: the speech engine's DLLs need it. Shipped next to Hearby.exe
# (app-local deployment) so people never see an administrator prompt for it. Pinned: the redistributable's own address
# contains its SHA-256, and each DLL taken from it is checked too.
VCREDIST_URL="https://download.visualstudio.microsoft.com/download/pr/bd1c8d9d-ba95-4eee-bc6e-df1fcc876373/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe"
VCREDIST_SHA="cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"
VC_DLLS="msvcp140:0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9
vcruntime140:d5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066
vcruntime140_1:1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f
vcomp140:55aba23cdcd6484fbb06f4155b8ca75adfce7a881f10afd0c49457165e677164"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
aside() { # move an existing output out of the way (never delete)
  [ -e "$1" ] || return 0
  mkdir -p "$OUT/superseded"
  mv "$1" "$OUT/superseded/$(basename "$1")-$(date +%Y%m%d-%H%M%S)"
}

CORE_VERSION=$(sed -n 's/.*const string Version = "\(.*\)";.*/\1/p' src/Hearby.Core/Basics.cs | head -1)
[ "$VERSION" = "$CORE_VERSION" ] || { echo "✗ version mismatch: Directory.Build.props $VERSION vs Basics.cs $CORE_VERSION"; exit 1; }
echo "Hearby for Windows $VERSION"
mkdir -p "$OUT" "$CACHE"

echo "── 1/4 contract tests（C# core == macOS core）──"
if [ "${HEARBY_SKIP_TESTS:-0}" = "1" ]; then echo "   skipped"; else
  LOG="$(mktemp)"
  if ! dotnet test tests/Hearby.Core.Tests -c Release >"$LOG" 2>&1; then grep -E "Failed|error" "$LOG" | head -20; echo "✗ contract tests failed"; exit 1; fi
  grep -E "Passed!|通過!|Total tests|測試總數" "$LOG" | tail -2
fi

echo "── 2/4 publish（win-x64, self-contained）──"
aside "$OUT/publish"
dotnet publish src/Hearby.App -c Release -r win-x64 --self-contained true -o "$OUT/publish" 2>&1 | grep -E "error|->" | tail -2
[ -f "$OUT/publish/Hearby.exe" ] || { echo "✗ publish failed"; exit 1; }

echo "── 3/4 Microsoft C++ runtime（app-local）──"
command -v cabextract >/dev/null 2>&1 || { echo "✗ needs cabextract (brew install cabextract / apt install cabextract)"; exit 1; }
VC="$CACHE/vcredist-14.44.35211"
mkdir -p "$VC"
if [ ! -f "$VC/VC_redist.x64.exe" ] || [ "$(sha "$VC/VC_redist.x64.exe")" != "$VCREDIST_SHA" ]; then
  curl -fsSL -o "$VC/VC_redist.x64.exe.part" "$VCREDIST_URL"
  [ "$(sha "$VC/VC_redist.x64.exe.part")" = "$VCREDIST_SHA" ] || { echo "✗ VC_redist.x64.exe checksum mismatch"; exit 1; }
  mv "$VC/VC_redist.x64.exe.part" "$VC/VC_redist.x64.exe"
fi
if [ ! -f "$VC/x64/vcruntime140.dll_amd64" ]; then
  mkdir -p "$VC/bundle" "$VC/x64"
  cabextract -q -d "$VC/bundle" "$VC/VC_redist.x64.exe" >/dev/null 2>&1 || true
  CAB=$(python3 - "$VC/bundle/0" <<'PY'
import re, sys
x = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'FilePath="packages\\vcRuntimeMinimum_amd64\\cab1\.cab"[^>]*SourcePath="(a\d+)"', x)
print(m.group(1) if m else "")
PY
)
  [ -n "$CAB" ] || { echo "✗ runtime cab not found in the redistributable"; exit 1; }
  cabextract -q -d "$VC/x64" "$VC/bundle/$CAB" >/dev/null 2>&1 || true
fi
while IFS=: read -r name want; do
  f="$VC/x64/$name.dll_amd64"
  [ -f "$f" ] && [ "$(sha "$f")" = "$want" ] || { echo "✗ $name.dll missing or checksum mismatch"; exit 1; }
  cp "$f" "$OUT/publish/$name.dll"
done <<< "$VC_DLLS"
echo "   msvcp140 vcruntime140 vcruntime140_1 vcomp140（14.44.35211）"

echo "── 4/4 installer（Velopack $VPK_VERSION）──"
VPK="$CACHE/tools/vpk"
if [ ! -x "$VPK" ]; then dotnet tool install vpk --version "$VPK_VERSION" --tool-path "$CACHE/tools" >/dev/null; fi
aside "$OUT/release"
mkdir -p "$OUT/release"
"$VPK" "[win]" pack --packId "$PACK_ID" --packVersion "$VERSION" --packDir "$OUT/publish" --mainExe Hearby.exe \
  --packTitle Hearby --packAuthors Hearby --icon "$WIN/src/Hearby.App/Assets/hearby.ico" \
  --outputDir "$OUT/release" --yes 2>&1 | grep -E -i "error|warn|done|complete" | tail -5 || true
SETUP=$(ls "$OUT/release"/*-Setup.exe 2>/dev/null | head -1)
[ -n "$SETUP" ] || { echo "✗ no Setup.exe produced"; exit 1; }
cp "$SETUP" "$OUT/release/Hearby-Setup.exe"
(cd "$OUT/release" && for f in *; do [ -f "$f" ] && [ "$f" != "SHA256SUMS.txt" ] && printf '%s  %s\n' "$(sha "$f")" "$f"; done > SHA256SUMS.txt)
echo ""
ls -la "$OUT/release"
echo "✅ $OUT/release/Hearby-Setup.exe"
