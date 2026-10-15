#!/usr/bin/env bash
# PreToolUse(Bash): buộc hỏi người trước hành động không đảo ngược được.
# Khớp mẫu thì in permissionDecision "ask". Không khớp thì im lặng cho qua.
# Khớp thừa chỉ tốn một câu hỏi, bỏ sót thì mất dữ liệu, nên các mẫu cố ý bắt rộng.
# Thêm mẫu: gọi thêm một dòng `rule '<regex ERE>' '<lý do>'` ở dưới, và thêm ca vào scripts/test-hooks.sh.
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

input="$(cat)"
cwd="$(json_get "$input" cwd)"
if have_jq || hook_python >/dev/null; then
  cmd="$(json_get "$input" tool_input.command)"
else
  # Không đọc được JSON chính xác: so mẫu trên toàn bộ input thô thay vì một mẩu bị cắt.
  cmd=""
fi
[ -n "$cmd" ] || cmd="$input"

reason=""
rule() {
  if [ -z "$reason" ] && printf '%s' "$cmd" | grep -Eiq -- "$1"; then
    reason="$2"
  fi
}

S='[[:space:]]'
# Kết thúc một từ: khoảng trắng, dấu nối lệnh, dấu nháy (kể cả \" trong JSON thô) hoặc hết chuỗi.
# shellcheck disable=SC1003  # dấu \ trong bracket là ký tự cần khớp
E='([[:space:];&|)"\'"'"']|$)'
# Option chen giữa tên tool và subcommand: git -C dir, kubectl -n prod, terraform -chdir=infra...
O='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
# Vị trí bắt đầu một lệnh (để `git rm` không bị coi là `rm`).
B='(^|[;&|(`"'"'"']|\$\()[[:space:]]*(sudo[[:space:]]+)?'
G="git${O}${S}+"
MAIN='(main|master|trunk|production|release)'
# shellcheck disable=SC2016  # $HOME ở đây là ký tự cần khớp, không phải biến
RMT='\\?"?(/|/\*|~/?|~/\*|\$HOME/?|\$\{HOME\}/?|\.|\./|\.\.|\.\./|\*|\./\*)\\?"?'

rule "${G}push[^;&|]*${S}(-f|--force|--force-with-lease|--force-if-includes|--mirror|--delete|-d)${E}" "force-push hoặc xoá nhánh remote"
rule "${G}push[^;&|]*${S}\+[^[:space:]]" "force-push bằng refspec +"
rule "${G}push[^;&|]*([[:space:]:]|refs/heads/)${MAIN}${E}" "push thẳng lên nhánh chính"
rule "${G}reset[^;&|]*${S}--hard" "git reset --hard làm mất thay đổi chưa commit"
rule "${G}clean[^;&|]*${S}(-[a-z]*f[a-z]*|--force)${E}" "git clean -f xoá file chưa track"
rule "${B}rm${S}+[^;&|]*(-[a-z]*r[a-z]*|--recursive)[^;&|]*${S}${RMT}${E}" "rm -r trên thư mục rộng"
rule "(psql|mysql|mariadb|sqlite3|sqlcmd|duckdb|clickhouse)[^|&]*(drop${S}+(table|database|schema)|truncate${S})" "lệnh SQL xoá dữ liệu"
rule "${B}dropdb${S}|prisma${S}+migrate${S}+reset|db:(drop|reset)${E}" "xoá hoặc reset database"
rule "(npm|pnpm|yarn|bun|cargo)${O}${S}+publish" "publish package"
rule "twine${S}+upload|docker${O}${S}+push" "đẩy artifact lên registry"
rule "terraform${O}${S}+(apply|destroy)|kubectl${O}${S}+(apply|delete|replace|rollout|scale|drain)|helm${O}${S}+(install|upgrade|uninstall|delete|rollback)" "thay đổi hạ tầng"
rule "(vercel|netlify)[^;&|]*--prod|fly(ctl)?${O}${S}+deploy|${B}((npm|pnpm|yarn|bun)${S}+(run${S}+)?deploy|make${S}+deploy)${E}" "deploy"
rule "gh${O}${S}+pr${S}+merge|gh${O}${S}+release${S}+create" "merge PR hoặc tạo release (quyết định của người)"

# `git push` không ghi refspec (hoặc chỉ ghi HEAD) đẩy nhánh hiện tại: hỏi nếu đó là nhánh chính.
if [ -z "$reason" ]; then
  while IFS= read -r seg; do
    read -r -a words <<< "$seg"
    dir="${cwd:-.}"
    positional=()
    seen_push=0
    i=1
    while [ "$i" -lt "${#words[@]}" ]; do
      w="${words[$i]}"
      if [ "$seen_push" = 0 ]; then
        case "$w" in
          -C)
            i=$((i + 1))
            d="${words[$i]:-.}"
            case "$d" in /* | [A-Za-z]:*) dir="$d" ;; *) dir="${cwd:-.}/$d" ;; esac
            ;;
          push) seen_push=1 ;;
        esac
      else
        case "$w" in -*) ;; *) positional+=("$w") ;; esac
      fi
      i=$((i + 1))
    done
    pushes_current=0
    [ "${#positional[@]}" -le 1 ] && pushes_current=1
    # ${arr[@]+...}: mảng rỗng không lỗi "unbound variable" với set -u trên bash 3.2 (macOS).
    for p in ${positional[@]+"${positional[@]}"}; do
      [ "$p" = HEAD ] && pushes_current=1
    done
    if [ "$pushes_current" = 1 ]; then
      branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      if printf '%s' "$branch" | grep -Eqx "$MAIN"; then
        reason="push nhánh hiện tại ($branch) lên remote"
        break
      fi
    fi
  done < <(printf '%s' "$cmd" | grep -Eio "${G}push[^;&|]*")
fi

if [ -n "$reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Hành động không đảo ngược được (%s). Cần người xác nhận, xem mục Quyền tự chủ trong CLAUDE.md."}}\n' "$reason"
fi
exit 0
