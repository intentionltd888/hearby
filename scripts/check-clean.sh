#!/bin/bash
# check-clean.sh — 公開前的清洗總掃（原始碼與文件）
#
# 兩層：
#   ① 通用形狀（寫在這支裡）：私人路徑、這台機器的帳號名與主機名、信箱、金鑰形狀、vendor 不進 git。
#   ② 私有樣式（不在這個倉裡）：維護者自己不想公開的字——放在倉外的一張表，這支只負責讀。
#      位置：$HEARBY_CLEAN_PATTERNS，預設 ~/.config/hearby/clean-patterns.tsv
#      格式：說明<TAB>正則（grep -E）<TAB>允許出現的檔（空白分隔，可空）；# 開頭是註解。
#      為什麼分開：把「不准出現的字」列在公開的檔裡，等於把那些字公開。
# 用法：bash scripts/check-clean.sh            → 沒有私有樣式表就只跑通用層（給 fork 的人）
#       bash scripts/check-clean.sh --strict   → 出貨閘用：沒有私有樣式表＝紅燈
# 綠燈＝可以公開；紅燈＝列出檔案與行號。
set -uo pipefail
cd "$(dirname "$0")/.."

STRICT=0; [ "${1:-}" = "--strict" ] && STRICT=1
PRIVATE="${HEARBY_CLEAN_PATTERNS:-$HOME/.config/hearby/clean-patterns.tsv}"
FAIL=0

# 掃描範圍：git 追蹤的檔案（vendor/ build/ .build/ 已被 .gitignore 排除）
if git rev-parse --git-dir >/dev/null 2>&1; then
  FILES=$(git ls-files --cached --others --exclude-standard)
else
  FILES=$(find . -type f -not -path "./.git/*" -not -path "./vendor/*" -not -path "./build/*" -not -path "./.build/*" | sed 's|^\./||')
fi

check() { # 正則, 說明, [允許出現的檔…]
  local pattern="$1" label="$2"
  shift 2
  local hits=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.png|*.jpg|*.icns|*.docx) continue;; esac
    local skip=0
    for w in "$@"; do [ "$f" = "$w" ] && skip=1; done
    [ "$skip" = "1" ] && continue
    local m
    m=$(grep -nE "$pattern" "$f" 2>/dev/null || true)
    [ -n "$m" ] && hits="$hits
$(echo "$m" | sed "s|^|  $f:|")"
  done <<< "$FILES"
  if [ -n "$hits" ]; then
    echo "✗ $label"; echo "$hits" | sed '/^$/d'; FAIL=1
  else
    printf "  ok   %s\n" "$label"
  fi
}

echo "Hearby clean check"

# ── ① 通用形狀 ──
check '/Users/[A-Za-z0-9._-]+/|-Users-[A-Za-z0-9]|/private/tmp/|/var/folders/' '私人路徑' scripts/check-clean.sh scripts/check-binary.sh
ME=$(id -un); HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
[ "${#ME}" -ge 3 ] && check "$ME" '這台機器的帳號名'
[ "${#HOST}" -ge 3 ] && check "$HOST" '這台機器的主機名'
check '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' '信箱'
check 'sk-ant-|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|xox[bp]-|BEGIN [A-Z ]*PRIVATE KEY|SUPublicEDKey' '金鑰形狀' scripts/check-clean.sh

# ── ② 私有樣式（倉外）──
if [ -f "$PRIVATE" ]; then
  N=0
  while IFS=$'\t' read -r label pattern allow || [ -n "${label:-}" ]; do
    case "${label:-}" in ''|'#'*) continue;; esac
    [ -n "${pattern:-}" ] || continue
    # shellcheck disable=SC2086
    check "$pattern" "$label" ${allow:-}
    N=$((N+1))
  done < "$PRIVATE"
  printf "  （私有樣式 %s 條）\n" "$N"
elif [ "$STRICT" = "1" ]; then
  echo "✗ 找不到私有樣式表（$PRIVATE）——出貨閘要兩層都跑"; FAIL=1
else
  echo "  --   沒有私有樣式表，只跑了通用層"
fi

# 引擎二進位不得進 git
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git ls-files | grep -qE '^vendor/'; then
    echo "✗ vendor/ 被加進 git 了"; FAIL=1
  else
    printf "  ok   %s\n" "vendor/ 沒進 git"
  fi
fi

echo ""
if [ "$FAIL" = "0" ]; then echo "✅ 乾淨，可以公開"; exit 0; fi
echo "❌ 有東西沒清乾淨"; exit 1
