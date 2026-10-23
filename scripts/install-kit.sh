#!/usr/bin/env bash
# Cài bộ agent team vào một git repo khác.
#   ./scripts/install-kit.sh <repo-đích> [--force]
# - Chép agents, hooks, 4 skill của kit, scripts/{check,validate-kit,test-hooks,audit-agent,test-audit}.sh, audit-agent.py, guard-ask-floor.
# - Gộp permissions + hooks vào .claude/settings.json sẵn có (giữ nguyên các khoá khác).
# - Repo chưa có CLAUDE.md: tạo từ templates/project-CLAUDE.md. Đã có thì không đụng (CLAUDE.md còn quy ước
#   đội chép từ kit cũ thì cảnh báo).
# - Luôn tạo hoặc cập nhật .claude/rules/agent-team.md (quy ước đội). Cài lại chỉ thay phần của kit
#   (tới dòng <!-- agent-team:kit-end ... -->), giữ quy ước riêng dự án viết dưới dòng đó.
# - Ghi .claude/agent-team-kit.txt: commit kit đã cài và danh sách file của kit. Cài lại thì báo ⚠ file mà kit
#   đã bỏ nhưng repo vẫn còn (không tự xoá), báo tiếp ở mọi lần cài cho tới khi người dùng xoá.
# - Thêm "*.sh text eol=lf" vào .gitattributes; thêm ngoại lệ .gitignore nếu kit bị ignore; ignore artifacts/.
# - File của kit mà repo đã có và khác bản kit hiện tại: trùng một bản đã commit trong lịch sử kit (dự án chưa
#   sửa; chỉ khác dòng kết thúc cũng tính là trùng) thì cập nhật luôn. Không trùng bản nào (dự án đã sửa, hoặc
#   file riêng trùng tên) thì dừng, không chép gì (trừ khi --force).
# Chạy lại nhiều lần vẫn cho cùng kết quả.
set -uo pipefail

kit="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
force="${2:-}"
if [ -z "$target" ] || [ ! -d "$target" ]; then
  echo "Cách dùng: $0 <repo-đích> [--force]" >&2
  exit 2
fi
target="$(cd "$target" && pwd)"
if ! git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "✘ $target không phải git repo" >&2
  exit 1
fi
if [ "$target" = "$kit" ]; then
  echo "✘ repo đích trùng với kit" >&2
  exit 1
fi

py=""
for c in python3 python py; do
  if "$c" -c 'import json' >/dev/null 2>&1; then
    py="$c"
    break
  fi
done

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(
  cd "$kit" && find .claude/agents .claude/hooks \
    .claude/skills/team-lead .claude/skills/create-verify-skill .claude/skills/correct .claude/skills/agent-audit \
    -type f | sort
  printf '%s\n' scripts/check.sh scripts/validate-kit.sh scripts/test-hooks.sh scripts/guard-ask-floor \
    scripts/audit-agent.sh scripts/audit-agent.py scripts/test-audit.sh
)

# Chỉ khi kit là gốc repo: kit giải nén vào trong một repo khác thì HEAD và lịch sử là của repo đó.
kit_repo=""
cdup="$(git -C "$kit" rev-parse --show-cdup 2>/dev/null)" && [ -z "$cdup" ] && kit_repo=1

# kit_had <f>: file <f> của repo đích trùng một bản đã commit của <f> trong lịch sử kit, kể cả bản chỉ merge commit
# mới có (-m: diff của merge với từng parent; thiếu nó thì git log --raw bỏ qua merge). log.diffMerges=separate đặt
# lại nghĩa của -m (config off hay remerge của người dùng đè nó: bỏ merge, hay thêm blob giả); --full-history không
# cắt lịch sử ở merge trùng một parent (lọc theo đường dẫn thì git chỉ đi theo parent đó). Băm hai cách, cách nào
# trùng cũng được: qua filter eol của kit (--path; kit clone với core.autocrlf=true có file CRLF mà blob là LF) và
# byte thô (--no-filters; lịch sử có blob CRLF thì filter lại đổi file sang LF). Git lỗi thì coi như không trùng.
kit_had() {
  local blob hist opt
  [ -n "$kit_repo" ] || return 1
  hist="$(git -c log.diffMerges=separate -C "$kit" log --format= --raw --no-abbrev --no-renames -m --full-history \
    -- "$1" 2>/dev/null)" || return 1
  for opt in --path="$1" --no-filters; do
    blob="$(git -C "$kit" hash-object "$opt" -- "$target/$1" 2>/dev/null)" || continue
    case "$hist" in *" $blob "*) return 0 ;; esac
  done
  return 1
}

conflicts=0
updated=()
for f in "${files[@]}"; do
  if [ -e "$target/$f" ] && ! cmp -s "$kit/$f" "$target/$f"; then
    if kit_had "$f"; then
      updated+=("$f")
    elif [ "$force" = "--force" ]; then
      echo "⚠ ghi đè $f: bản trong repo khác bản của kit" >&2
    else
      echo "✘ $f đã tồn tại và khác bản của kit" >&2
      conflicts=$((conflicts + 1))
    fi
  fi
done
if [ "$conflicts" -gt 0 ]; then
  echo "✘ dừng: $conflicts file trùng. Đổi tên file của bạn, hoặc chạy lại với --force để ghi đè." >&2
  exit 1
fi

# Gộp settings.json TRƯỚC khi chép file: JSON hỏng thì dừng mà repo đích chưa bị đụng tới.
settings="$target/.claude/settings.json"
merged=""
if [ -f "$settings" ] && [ -n "$py" ]; then
  merged="$(mktemp)"
  errf="$(mktemp)"
  trap 'rm -f "$merged" "$errf"' EXIT
  # Heredoc không đặt trong $(...): bash 3.2 (macOS) parse sai trường hợp đó.
  if ! "$py" - "$kit/.claude/settings.json" "$settings" "$merged" 2>"$errf" <<'PYEOF'
import json, sys
kit = json.load(open(sys.argv[1], encoding="utf-8"))
# utf-8-sig: chấp nhận BOM mà Notepad trên Windows hay thêm vào đầu file.
cur = json.load(open(sys.argv[2], encoding="utf-8-sig"))
perm = cur.setdefault("permissions", {})
for key in ("allow", "deny"):
    rules = perm.setdefault(key, [])
    for rule in kit["permissions"][key]:
        if rule not in rules:
            rules.append(rule)
hooks = cur.setdefault("hooks", {})
for event, groups in kit["hooks"].items():
    existing = hooks.setdefault(event, [])
    for group in groups:
        kit_cmds = {h.get("command") for h in group["hooks"]}
        same = [g for g in existing if any(h.get("command") in kit_cmds for h in g.get("hooks", []))]
        if not same:
            existing.append(group)
            continue
        # Đã có hook của kit (bản cũ): thêm vào matcher những tool kit mới cần (vd PowerShell), giữ phần riêng.
        if "matcher" in group:
            for g in same:
                if (g.get("matcher") or "") in ("", "*"):
                    continue  # đã khớp mọi tool
                have = [t for t in g["matcher"].split("|") if t]
                g["matcher"] = "|".join(have + [t for t in group["matcher"].split("|") if t not in have])
out = {"$schema": cur.pop("$schema", kit.get("$schema"))}
out.update(cur)
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF
  then
    echo "✘ không đọc được .claude/settings.json nên chưa chép gì: $(tail -n 1 "$errf")" >&2
    echo "  Sửa file (JSON chuẩn, không comment) rồi chạy lại, hoặc gộp tay theo $kit/.claude/settings.json" >&2
    exit 1
  fi
fi

for f in "${files[@]}"; do
  mkdir -p "$target/$(dirname "$f")"
  cp "$kit/$f" "$target/$f"
  case "$f" in *.sh) chmod +x "$target/$f" ;; esac
done
echo "✔ đã chép ${#files[@]} file của kit"
if [ "${#updated[@]}" -gt 0 ]; then
  echo "✔ cập nhật ${#updated[@]} file kit mà dự án chưa sửa"
  printf '  %s\n' "${updated[@]}"
fi

if [ ! -f "$settings" ]; then
  cp "$kit/.claude/settings.json" "$settings"
  echo "✔ tạo .claude/settings.json"
elif [ -n "$merged" ]; then
  cp "$merged" "$settings"
  echo "✔ gộp permissions + hooks vào .claude/settings.json"
else
  echo "⚠ không có Python: hãy gộp tay phần permissions + hooks từ $kit/.claude/settings.json" >&2
fi

# .claude/rules/agent-team.md: phần của kit chạy từ đầu file tới dòng dấu (dòng cuối của template).
rules_tpl="$kit/templates/agent-team-rules.md"
rules_mark='<!-- agent-team:kit-end'
# own_part <file cũ> <có dấu 0|1>: in phần dự án tự viết trong file cũ.
# Có dấu: mọi thứ sau dòng dấu đầu tiên, nguyên văn. Không có dấu (bản cài cũ): dòng trống + các mục
# heading # hoặc ## (ngoài code fence) mà template không có, nguyên văn; ### trở xuống thuộc mục cha.
# \r đi qua awk dưới dạng \001: gawk của Git for Windows bỏ \r khi đọc, phần riêng CRLF sẽ thành LF.
own_part() {
  tr '\r' '\001' < "$1" | awk -v has_mark="$2" -v mark="$rules_mark" '
    function is_heading(s,   t, c, n) { # cập nhật trạng thái code fence; 1 nếu s là heading cấp 1-2 ngoài fence
      t = s # fence được thụt tối đa 3 dấu cách (không dùng / ? ? ?/: mawk 1.3.4 chỉ khớp 1 dấu cách)
      if (match(t, /^ +/) && RLENGTH <= 3) t = substr(t, RLENGTH + 1)
      c = substr(t, 1, 1)
      n = 0
      if (c == "`" || c == "~") while (substr(t, n + 1, 1) == c) n++
      if (fence != "") {
        if (c == substr(fence, 1, 1) && n >= length(fence) && substr(t, n + 1) ~ /^[ \t]*$/) fence = ""
        return 0
      }
      if (n >= 3) {
        fence = substr(t, 1, n)
        return 0
      }
      return s ~ /^##?[ \t]/ || s ~ /^##?$/
    }
    FNR == 1 { fence = "" }
    { line = $0; sub(/(\r|\001)$/, "", line) }
    NR == FNR { if (is_heading(line)) { sub(/[ \t]+$/, "", line); kit[line] = 1 }; next }
    has_mark == 1 { if (after) print; else after = index(line, mark) == 1; next }
    is_heading(line) {
      sub(/[ \t]+$/, "", line)
      keep = !(line in kit)
      if (keep && !kept++) print ""
    }
    keep
  ' "$rules_tpl" - | tr '\001' '\r'
}

kept="CLAUDE.md đã có nên giữ nguyên; "
if [ ! -f "$target/CLAUDE.md" ]; then
  if ! cp "$kit/templates/project-CLAUDE.md" "$target/CLAUDE.md"; then
    echo "✘ không tạo được CLAUDE.md (symlink gãy thì xoá hoặc sửa nó rồi chạy lại)" >&2
    exit 1
  fi
  echo "✔ tạo CLAUDE.md (điền các mục TODO)"
  kept=""
fi

rules="$target/.claude/rules/agent-team.md"
mkdir -p "$target/.claude/rules"
if [ ! -f "$rules" ]; then
  cp "$rules_tpl" "$rules"
  echo "✔ ${kept}quy ước đội ở .claude/rules/agent-team.md"
else
  has_mark=0
  grep -q "^$rules_mark" "$rules" && has_mark=1
  # Đọc hết phần riêng trước khi ghi. "x" giữ newline cuối mà $(...) cắt mất.
  if ! own="$(own_part "$rules" "$has_mark" && echo x)"; then
    echo "✘ không đọc được .claude/rules/agent-team.md nên chưa cập nhật nó" >&2
    exit 1
  fi
  own="${own%x}"
  # Ghi thẳng vào file, không mv từ mktemp: giữ quyền của file.
  { cat "$rules_tpl"; printf '%s' "$own"; } > "$rules"
  if [ -n "$own" ]; then
    n=$(($(printf '%s' "$own" | wc -l)))
    echo "✔ ${kept}.claude/rules/agent-team.md: thay phần của kit, giữ $n dòng riêng của dự án"
  else
    echo "✔ ${kept}quy ước đội ở .claude/rules/agent-team.md"
  fi
  if [ "$has_mark" = 0 ]; then
    echo "  (bản cài cũ chưa có dòng $rules_mark -->: chỉ giữ được mục #/## mà template không có, sửa trong phần của kit đã bị thay; xem git diff)"
  fi
fi

# Kit cũ chép nguyên CLAUDE.md của kit sang dự án; mọi bản đó đều có cả hai chuỗi này.
if grep -qsF '/team-lead <task>' "$target/CLAUDE.md" && grep -qsF 'Rule ↔ Thứ thực thi' "$target/CLAUDE.md"; then
  echo "⚠ CLAUDE.md còn quy ước đội chép từ bản kit cũ, trùng với .claude/rules/agent-team.md (bản được cập nhật mỗi lần cài)." >&2
  echo "  Xoá các dòng đó khỏi CLAUDE.md, giữ phần riêng của dự án." >&2
fi

# .claude/agent-team-kit.txt: commit kit đã cài và file của kit, để biết repo nào đang dùng kit cũ.
# Không ghi ngày giờ: chạy lại cùng commit kit cho file y hệt.
manifest="$target/.claude/agent-team-kit.txt"
commit=unknown
if [ -n "$kit_repo" ] && sha="$(git -C "$kit" rev-parse HEAD 2>/dev/null)"; then
  commit="$sha"
  [ -n "$(git -C "$kit" status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$sha-dirty"
fi
nl=$'\n'
cr=$'\r'
kit_list="$(printf '%s\n' "${files[@]}")"
# File kit mà lần cài trước liệt kê (kit-files, kit-dropped), kit mới không còn nhưng repo vẫn có: báo, không
# xoá, ghi vào kit-dropped để lần sau vẫn báo. Chỉ đọc đường dẫn, không thực thi gì trong file.
prev=""
dropped=""
ndropped=0
if [ -f "$manifest" ]; then
  in_list=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$cr"}"
    case "$line" in
      'kit-commit: '*) prev="${line#kit-commit: }" ;;
      kit-files: | kit-dropped:) in_list=1 ;;
      '' | '#'*) ;;
      *)
        [ "$in_list" = 1 ] && [ -e "$target/$line" ] || continue
        # Còn trong kit mới, hoặc đã có trong danh sách (file sửa tay có thể lặp dòng).
        case "$nl$kit_list$nl$dropped" in *"$nl$line$nl"*) continue ;; esac
        dropped="$dropped$line$nl"
        ndropped=$((ndropped + 1))
        ;;
    esac
  done < "$manifest"
fi
{
  echo "# Bản Agents-Team-coding cài vào repo này. install-kit.sh ghi file này, đừng sửa tay."
  echo "# Kit có gì mới: git -C <thư mục kit> log --oneline <kit-commit>..HEAD -- .claude scripts templates"
  echo "kit-commit: $commit"
  echo "kit-files:"
  printf '%s\n' "$kit_list"
  echo "kit-dropped:"
  printf '%s' "$dropped"
} > "$manifest"
short() { case "$1" in *-dirty) printf '%s-dirty' "${1:0:7}" ;; *) printf '%s' "${1:0:7}" ;; esac; }
was=""
[ -n "$prev" ] && [ "$prev" != "$commit" ] && was=" (trước: $(short "$prev"))"
echo "✔ .claude/agent-team-kit.txt: kit $(short "$commit")$was"
if [ "$ndropped" -gt 0 ]; then
  echo "⚠ kit đã bỏ $ndropped file mà repo này vẫn còn. Dự án không dùng thì xoá (git rm):" >&2
  printf '%s' "$dropped" | sed 's/^/  /' >&2
fi

attrs="$target/.gitattributes"
if ! grep -qsxF '*.sh text eol=lf' "$attrs"; then
  [ -s "$attrs" ] && [ -n "$(tail -c 1 "$attrs")" ] && echo >> "$attrs"
  echo '*.sh text eol=lf' >> "$attrs"
  echo "✔ .gitattributes: giữ LF cho *.sh (Windows)"
fi

ignored=()
for probe in .claude/agents/architect.md .claude/hooks/stop-gate.sh .claude/skills/team-lead/SKILL.md \
             .claude/rules/agent-team.md .claude/settings.json .claude/agent-team-kit.txt scripts/check.sh; do
  [ -e "$target/$probe" ] || continue
  git -C "$target" check-ignore -q "$probe" && ignored+=("$probe")
done
if [ "${#ignored[@]}" -gt 0 ]; then
  {
    echo
    echo "# Bộ agent team (Agents-Team-coding)"
    # Git không bật lại được file nằm trong thư mục cha đã bị ignore, nên mở từ thư mục cấp cao nhất.
    # Chỉ ghi !dir/ (không ghi !dir/**): dạng ** đứng cuối file sẽ đè luật .env, *.log... phía trên.
    for p in "${ignored[@]}"; do
      case "$p" in
        .claude/settings.json | .claude/agent-team-kit.txt) echo "!$p" ;;
        .claude/*) d="${p#.claude/}"; printf '!.claude/%s/\n' "${d%%/*}" ;;
        *) printf '!%s/\n' "${p%%/*}" ;;
      esac
    done
  } >> "$target/.gitignore"
  still=()
  for p in "${ignored[@]}"; do
    git -C "$target" check-ignore -q "$p" && still+=("$p")
  done
  if [ "${#still[@]}" -gt 0 ]; then
    echo "✘ .gitignore vẫn bỏ qua: ${still[*]} (thư mục cha bị ignore cả cụm; sửa tay .gitignore)" >&2
    exit 1
  fi
  echo "✔ .gitignore: thêm ngoại lệ cho ${ignored[*]}"
fi

# Bằng chứng của verifier (artifacts/verify/<slug>/) không thuộc mã nguồn. Không ignore thì Stop gate
# coi là thay đổi và chạy check ở mọi lượt, và agent có thể lỡ commit nó.
if ! git -C "$target" check-ignore -q artifacts/verify/probe.txt; then
  {
    echo
    echo "# Bằng chứng của verifier (Agents-Team-coding)"
    echo "artifacts/"
  } >> "$target/.gitignore"
  echo "✔ .gitignore: bỏ qua artifacts/ (bằng chứng của verifier)"
fi

sh_files=()
for f in "${files[@]}"; do
  case "$f" in *.sh) sh_files+=("$f") ;; esac
done
if git -C "$target" add --chmod=+x -- "${sh_files[@]}" 2>/dev/null; then
  echo "✔ đã stage ${#sh_files[@]} script với quyền chạy (giữ được cả khi commit từ Windows)"
fi

echo
echo "Bước tiếp theo trong $target:"
[ -f "$target/scripts/check.local.sh" ] || echo "  1. Tạo scripts/check.local.sh (lint + test nhanh của dự án)"
echo "  2. ./scripts/check.sh"
echo "  3. git add -A && git commit -m \"chore: cài bộ agent team\""
