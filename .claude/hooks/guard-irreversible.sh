#!/usr/bin/env bash
# PreToolUse(Bash): buộc hỏi người trước hành động không đảo ngược được.
# Khớp mẫu thì in permissionDecision "ask". Không khớp thì im lặng cho qua.
# Thêm mẫu: gọi thêm một dòng `rule '<regex ERE>' '<lý do>'` ở dưới.
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

input="$(cat)"
cmd="$(json_get "$input" tool_input.command)"
[ -n "$cmd" ] || cmd="$input"

reason=""
rule() {
  if [ -z "$reason" ] && printf '%s' "$cmd" | grep -Eiq -- "$1"; then
    reason="$2"
  fi
}

S='[[:space:]]'
E='([[:space:];&|]|$)'
rule "git${S}+push[^;&|]*${S}(-f|--force|--force-with-lease|--mirror|--delete|-d)([[:space:]=]|$)" "force-push hoặc xoá nhánh remote"
rule "git${S}+push[^;&|]*${S}\+[^[:space:]]" "force-push bằng refspec +"
rule "git${S}+push[^;&|]*[[:space:]:](main|master|trunk|production|release)${E}" "push thẳng lên nhánh chính"
rule "git${S}+reset${S}+[^;&|]*--hard" "git reset --hard làm mất thay đổi chưa commit"
rule "git${S}+clean${S}+-[a-z]*f" "git clean -f xoá file chưa track"
rule "(^|[;&|[:space:]])rm${S}+[^;&|]*-[a-z]*r[^;&|]*${S}(/|/\*|~|~/|~/\*|\\\$HOME|\\\$\{HOME\}|\.|\./|\.\.|\.\./|\*|\./\*)${E}" "rm -r trên thư mục rộng"
rule "(psql|mysql|mariadb|sqlite3|sqlcmd|duckdb|clickhouse)[^|&]*(drop${S}+(table|database|schema)|truncate${S})" "lệnh SQL xoá dữ liệu"
rule "(^|[;&|[:space:]])dropdb${S}|prisma${S}+migrate${S}+reset|db:(drop|reset)${E}" "xoá hoặc reset database"
rule "(^|[;&|[:space:]])(npm|pnpm|yarn|bun|cargo)${S}+publish" "publish package"
rule "twine${S}+upload|docker${S}+push" "đẩy artifact lên registry"
rule "terraform${S}+(apply|destroy)|kubectl${S}+(apply|delete|replace|rollout)|helm${S}+(install|upgrade|uninstall|delete)" "thay đổi hạ tầng"
rule "(vercel|netlify)[^;&|]*--prod|fly(ctl)?${S}+deploy|(^|[;&|])${S}*((npm|pnpm|yarn|bun)${S}+(run${S}+)?deploy|make${S}+deploy)${E}" "deploy"
rule "gh${S}+pr${S}+merge|gh${S}+release${S}+create" "merge PR hoặc tạo release (quyết định của người)"

if [ -n "$reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Hành động không đảo ngược được (%s). Cần người xác nhận, xem mục Quyền tự chủ trong CLAUDE.md."}}\n' "$reason"
fi
exit 0
