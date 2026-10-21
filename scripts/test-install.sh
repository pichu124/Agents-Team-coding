#!/usr/bin/env bash
# Test hành vi của scripts/install-kit.sh trên các repo tạm.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
kit="$PWD"

py=""
for c in python3 python py; do
  if "$c" -c 'import json' >/dev/null 2>&1; then
    py="$c"
    break
  fi
done
if [ -z "$py" ]; then
  printf '⚠ bỏ qua test install: cần Python để đọc settings.json\n'
  exit 0
fi

fails=0
pass=0
ok() { pass=$((pass + 1)); }
bad() {
  printf '✘ %s\n' "$*" >&2
  fails=$((fails + 1))
}
assert() {
  local msg="$1"
  shift
  if "$@"; then ok; else bad "$msg"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
}
install() { "$kit/scripts/install-kit.sh" "$@" >/dev/null 2>&1; }
run_install() { "$kit/scripts/install-kit.sh" "$@" > "$tmp/out" 2> "$tmp/err"; } # giữ stdout, stderr của lần cài
claude_warned() { grep -q '^⚠.*CLAUDE\.md' "$tmp/err"; }
no_claude_warning() { ! grep -q '^⚠.*CLAUDE\.md' "$tmp/out" "$tmp/err"; }
hook_groups() { # hook_groups <settings.json> <event>
  "$py" -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["hooks"].get(sys.argv[2], [])))' "$1" "$2" | tr -d '\r'
}
json_has() { # json_has <settings.json> <khoá cấp 1>
  "$py" -c 'import json, sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' "$1" "$2"
}

# A. Repo trống: kit được cài đầy đủ và tự kiểm tra xanh.
a="$tmp/fresh"
new_repo "$a"
install "$a"
assert "A: install phải exit 0" [ $? -eq 0 ]
assert "A: thiếu agent" [ -f "$a/.claude/agents/verifier.md" ]
assert "A: hook phải có quyền chạy" [ -x "$a/.claude/hooks/stop-gate.sh" ]
assert "A: thiếu CLAUDE.md" [ -f "$a/CLAUDE.md" ]
assert "A: thiếu .gitattributes LF" grep -qxF '*.sh text eol=lf' "$a/.gitattributes"
assert "A: settings thiếu Stop hook" [ "$(hook_groups "$a/.claude/settings.json" Stop)" = 1 ]
assert "A: thiếu skill /agent-audit" [ -f "$a/.claude/skills/agent-audit/SKILL.md" ]
assert "A: script dò sự cố phải có quyền chạy" [ -x "$a/scripts/audit-agent.sh" ]
assert "A: thiếu sàn số ca phải hỏi" [ -f "$a/scripts/guard-ask-floor" ]
# Bằng chứng verifier lưu ở artifacts/: phải bị ignore, không thì Stop gate chạy check ở mọi lượt.
assert "A: artifacts/ (bằng chứng của verifier) phải bị .gitignore bỏ qua" git -C "$a" check-ignore -q artifacts/verify/x/out.txt
(cd "$a" && ./scripts/test-hooks.sh >/dev/null 2>&1)
assert "A: test hook trong repo đích phải xanh (sàn số ca đúng)" [ $? -eq 0 ]
(cd "$a" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "A: validate-kit trong repo đích phải xanh" [ $? -eq 0 ]

# B. Repo giống vnstock-dashboard: có CLAUDE.md, settings có plugin, .gitignore chặn .claude/*,
#    skill lạ dài 600 dòng và link gãy trong tài liệu của dự án.
b="$tmp/existing"
new_repo "$b"
mkdir -p "$b/.claude/skills/big" "$b/docs"
echo "# CLAUDE.md của dự án" > "$b/CLAUDE.md"
printf '{\n  "enabledPlugins": {"x@y": true}\n}\n' > "$b/.claude/settings.json"
printf '.claude/*\n!.claude/settings.json\n!.claude/skills/\n!.claude/skills/**\n' > "$b/.gitignore"
{ echo "---"; echo "name: khac-ten"; echo "---"; for _ in $(seq 600); do echo "dòng"; done; } > "$b/.claude/skills/big/SKILL.md"
echo "[gãy](khong-ton-tai.md)" > "$b/docs/note.md"
git -C "$b" -c core.autocrlf=false add -A
git -C "$b" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m project
run_install "$b"
assert "B: install phải exit 0" [ $? -eq 0 ]
assert "B: CLAUDE.md riêng không chép quy ước đội thì không được cảnh báo về CLAUDE.md" no_claude_warning
assert "B: không được sửa CLAUDE.md có sẵn" [ "$(cat "$b/CLAUDE.md")" = "# CLAUDE.md của dự án" ]
assert "B: thiếu .claude/rules/agent-team.md" [ -f "$b/.claude/rules/agent-team.md" ]
assert "B: lần cài đầu .claude/rules/agent-team.md phải đúng bằng template" \
  cmp -s "$kit/templates/agent-team-rules.md" "$b/.claude/rules/agent-team.md"
assert "B: phải giữ enabledPlugins" json_has "$b/.claude/settings.json" enabledPlugins
assert "B: phải gộp hooks" json_has "$b/.claude/settings.json" hooks
for p in .claude/agents/architect.md .claude/hooks/stop-gate.sh .claude/rules/agent-team.md; do
  if git -C "$b" check-ignore -q "$p"; then bad "B: $p vẫn bị .gitignore bỏ qua"; else ok; fi
done
install "$b"
assert "B: chạy lại install phải exit 0" [ $? -eq 0 ]
assert "B: cài lại khi không có phần riêng thì .claude/rules/agent-team.md vẫn đúng bằng template" \
  cmp -s "$kit/templates/agent-team-rules.md" "$b/.claude/rules/agent-team.md"
for ev in PreToolUse PostToolUse Stop; do
  assert "B: chạy lại không được nhân đôi hook $ev" [ "$(hook_groups "$b/.claude/settings.json" "$ev")" = 1 ]
done
(cd "$b" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "B: validate-kit chỉ được kiểm file của kit, bỏ qua skill/tài liệu của dự án" [ $? -eq 0 ]
assert "B: artifacts/ phải bị ignore ở repo đã có .gitignore" git -C "$b" check-ignore -q artifacts/verify/x/out.txt
assert "B: chạy lại install không được thêm trùng dòng artifacts/" [ "$(grep -c '^artifacts/$' "$b/.gitignore")" = 1 ]

# C. Trùng tên agent: dừng, không chép gì.
c="$tmp/conflict"
new_repo "$c"
mkdir -p "$c/.claude/agents"
echo "agent riêng của dự án" > "$c/.claude/agents/reviewer.md"
install "$c"
assert "C: trùng file phải exit khác 0" [ $? -ne 0 ]
assert "C: không được chép một phần" [ ! -e "$c/.claude/agents/architect.md" ]
assert "C: không được ghi đè file của dự án" [ "$(cat "$c/.claude/agents/reviewer.md")" = "agent riêng của dự án" ]

# D. settings.json có BOM (Notepad trên Windows) + hook riêng của dự án; .gitignore có luật bí mật.
d="$tmp/windows proj"
new_repo "$d"
mkdir -p "$d/.claude/hooks" "$d/scripts"
printf '\357\273\277{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "python .claude/hooks/notify.py"}, {"type": "command", "command": "~/.claude/hooks/session.sh"}]}]}}\n' > "$d/.claude/settings.json"
echo "print(1)" > "$d/.claude/hooks/notify.py"
printf '.env\n*.log\n__pycache__/\n.claude/*\n!.claude/settings.json\nscripts/\n' > "$d/.gitignore"
echo "SECRET=1" > "$d/scripts/.env"
echo "log" > "$d/scripts/run.log"
echo "SECRET=1" > "$d/.claude/hooks/.env"
(cd / && "$kit/scripts/install-kit.sh" "$d" >/dev/null 2>&1)
assert "D: settings.json có BOM vẫn phải cài được" [ $? -eq 0 ]
assert "D: phải giữ hook riêng của dự án" grep -q 'notify.py' "$d/.claude/settings.json"
assert "D: phải gộp Stop hook của kit" grep -q 'stop-gate.sh' "$d/.claude/settings.json"
for p in .claude/hooks/stop-gate.sh scripts/check.sh; do
  if git -C "$d" check-ignore -q "$p"; then bad "D: $p vẫn bị ignore"; else ok; fi
done
for p in scripts/.env scripts/run.log .claude/hooks/.env; do
  if git -C "$d" check-ignore -q "$p"; then ok; else bad "D: ngoại lệ .gitignore làm lộ $p"; fi
done
mode="$(git -C "$d" ls-files -s .claude/hooks/stop-gate.sh | cut -c1-6)"
assert "D: script của kit phải được stage với quyền chạy (Windows) → $mode" [ "$mode" = 100755 ]
(cd "$d" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "D: validate-kit không được kiểm hook riêng của dự án" [ $? -eq 0 ]

# E. settings.json là JSONC (có comment): dừng trước khi chép bất cứ gì.
e="$tmp/jsonc"
new_repo "$e"
mkdir -p "$e/.claude"
printf '{\n  // comment\n  "enabledPlugins": {}\n}\n' > "$e/.claude/settings.json"
install "$e"
assert "E: settings.json không đọc được thì phải exit khác 0" [ $? -ne 0 ]
assert "E: không được chép file nào khi settings.json hỏng" [ ! -e "$e/.claude/agents/architect.md" ]
assert "E: không được tạo .gitattributes khi dừng" [ ! -e "$e/.gitattributes" ]

# F. Cài lại lên bản kit cũ có matcher "Bash" (thiếu PowerShell): nới matcher, giữ matcher riêng, không nhân đôi.
guard_matcher() {
  "$py" -c 'import json, sys
for g in json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]:
    if any("guard-irreversible.sh" in h.get("command", "") for h in g.get("hooks", [])):
        print(g.get("matcher", ""))' "$1" | tr -d '\r'
}
f="$tmp/old kit"
new_repo "$f"
install "$f"
"$py" - "$f/.claude/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["hooks"]["PreToolUse"]:
    g["matcher"] = "Bash|Monitor"
json.dump(d, open(p, "w"), indent=2)
PYEOF
(cd "$f" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "F: validate-kit phải đỏ khi guard không khớp PowerShell" [ $? -ne 0 ]
install "$f"
assert "F: cài lại phải exit 0" [ $? -eq 0 ]
assert "F: matcher phải thêm PowerShell và giữ phần riêng → $(guard_matcher "$f/.claude/settings.json")" \
  [ "$(guard_matcher "$f/.claude/settings.json")" = "Bash|Monitor|PowerShell" ]
assert "F: không được nhân đôi PreToolUse" [ "$(hook_groups "$f/.claude/settings.json" PreToolUse)" = 1 ]
(cd "$f" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "F: validate-kit phải xanh sau khi cài lại" [ $? -eq 0 ]

# G. Guard đăng ký ở hai nhóm (Bash, PowerShell) vẫn là đủ; nhóm có "matcher": null không làm hỏng việc gộp.
"$py" - "$f/.claude/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
pre = d["hooks"]["PreToolUse"]
guard = [h for g in pre for h in g["hooks"] if "guard-irreversible.sh" in h["command"]]
d["hooks"]["PreToolUse"] = [{"matcher": "Bash", "hooks": guard}, {"matcher": "PowerShell", "hooks": guard}]
d["hooks"]["PostToolUse"][0]["matcher"] = None
json.dump(d, open(p, "w"), indent=2)
PYEOF
(cd "$f" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "G: guard ở hai nhóm Bash và PowerShell phải được coi là đủ" [ $? -eq 0 ]
install "$f"
assert "G: matcher null không được làm hỏng việc gộp" [ $? -eq 0 ]
(cd "$f" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "G: validate-kit phải xanh sau khi cài lại lên guard hai nhóm" [ $? -eq 0 ]

# H..M. Cập nhật kit không được xoá quy ước riêng mà dự án viết thêm vào .claude/rules/agent-team.md.
tpl="$kit/templates/agent-team-rules.md"
mark='<!-- agent-team:kit-end'
tpl_bytes=$(($(wc -c < "$tpl")))
kit_part_ok() { head -c "$tpl_bytes" "$1" | cmp -s - "$tpl"; } # file mở đầu đúng bằng toàn bộ template mới
own_part_is() { tail -c +"$((tpl_bytes + 1))" "$1" | cmp -s - "$2"; } # phần sau template giống hệt file $2
to_crlf() { awk '{ printf "%s\r\n", $0 }'; }
rules_repo() { # rules_repo <thư mục>: repo có CLAUDE.md riêng, đã có .claude/rules/
  new_repo "$1"
  echo "# CLAUDE.md của dự án" > "$1/CLAUDE.md"
  mkdir -p "$1/.claude/rules"
}
# Bản template mà các repo cài kit sớm đang có (chưa có dòng dấu).
old_tpl="$tmp/old-template.md"
cat > "$old_tpl" <<'EOF'
# Đội agent (Agents-Team-coding)

- Task không tầm thường thì dùng `/team-lead <task>`. Chốt điều kiện xong dạng pass/fail trước khi làm.
- "Xong" nghĩa là `./scripts/check.sh` exit 0 cộng bằng chứng hành vi. Không chạy được check thì nói "inconclusive".
- Bug: tái hiện trước bằng test fail, rồi mới sửa nguyên nhân gốc.
- Người viết không tự kiểm: verify và review bằng subagent mới (`verifier`, `reviewer`).
- Bị người dùng sửa cùng một lỗi lần thứ hai thì đề xuất `/correct`.
- Cứ làm: đọc, sửa trong branch hoặc worktree, commit cục bộ, chạy test. Luôn hỏi người: force-push, push hoặc merge vào nhánh chính, xoá dữ liệu, deploy, publish.

| Rule | Thực thi bởi |
|---|---|
| Không kết thúc lượt khi check đỏ | `.claude/hooks/stop-gate.sh` (Stop) |
| Hỏi người trước hành động không đảo ngược được | `.claude/hooks/guard-irreversible.sh` (PreToolUse) |
| Không đọc file bí mật (`.env`, `*.pem`, `secrets/`) | `permissions.deny` trong `.claude/settings.json` |
| Format theo cấu hình của dự án | `.claude/hooks/post-edit-format.sh` (PostToolUse) |
EOF
# Mục riêng của dự án: có mục con ### và code fence chứa dòng giống heading (kể cả heading của kit).
own_x="$tmp/own-x.md"
cat > "$own_x" <<'EOF'
## Riêng CASA Mầm non

- Check nhanh: `./scripts/check.sh` (bộ --fast).
- Trước khi mở PR: `CHECK_FULL=1 ./scripts/check.sh`.

### Dữ liệu mẫu

```markdown
# Đội agent (Agents-Team-coding)
## không phải heading
```

- Không commit `data/`. Fence thụt lề vẫn là fence:

  ~~~
# Đội agent (Agents-Team-coding)
  ~~~

# Phụ lục

Mục cấp 1 riêng cũng được giữ, đúng thứ tự.
EOF
sep_own_x="$tmp/sep-own-x.md" # dòng trống ngăn cách + mục riêng
{ echo; cat "$own_x"; } > "$sep_own_x"

# H. Template có đúng một dòng dấu, là dòng cuối, kết thúc bằng newline.
assert "H: template phải có đúng một dòng bắt đầu bằng $mark" [ "$(grep -c "^$mark" "$tpl")" = 1 ]
case "$(tail -n 1 "$tpl")" in
  "$mark"*'-->') ok ;;
  *) bad "H: dòng cuối của template phải là dòng dấu $mark ... -->" ;;
esac
assert "H: template phải kết thúc bằng newline" [ -z "$(tail -c 1 "$tpl")" ]

# I. Bản cài cũ (chưa có dấu) + mục riêng ở cuối, cài lại với --force:
#    phần của kit thay bằng template mới, mục riêng còn nguyên văn.
i="$tmp/old rules"
rules_repo "$i"
cat "$old_tpl" "$sep_own_x" > "$i/.claude/rules/agent-team.md"
perm_before="$(ls -l "$i/.claude/rules/agent-team.md" | cut -c1-10)"
install "$i" --force
assert "I: cài lại lên bản cũ có mục riêng phải exit 0" [ $? -eq 0 ]
assert "I: file phải mở đầu bằng toàn bộ template mới" kit_part_ok "$i/.claude/rules/agent-team.md"
assert "I: sau template phải là dòng trống + mục riêng nguyên văn" own_part_is "$i/.claude/rules/agent-team.md" "$sep_own_x"
assert "I: không được đổi quyền của file" [ "$(ls -l "$i/.claude/rules/agent-team.md" | cut -c1-10)" = "$perm_before" ]

# J. Chạy lại (không --force) trên kết quả của I: file y hệt.
cp "$i/.claude/rules/agent-team.md" "$tmp/i-after.md"
install "$i"
assert "J: chạy lại phải exit 0" [ $? -eq 0 ]
assert "J: chạy lại phải cho file y hệt (idempotent)" cmp -s "$tmp/i-after.md" "$i/.claude/rules/agent-team.md"

# K. Có dấu: sửa tay một dòng trên dấu, viết thêm dưới dấu (không heading ngay sau dấu) → trên dấu về template, dưới giữ.
k="$tmp/marked"
rules_repo "$k"
own_k="$tmp/own-k.md"
printf 'Ghi chú ngay dưới dấu, chưa có heading.\n\n## Riêng Y\n- y\n' > "$own_k"
{ awk 'NR == 3 { print "- Sửa tay trong phần của kit."; next } { print }' "$tpl"; cat "$own_k"; } \
  > "$k/.claude/rules/agent-team.md"
install "$k"
assert "K: cài lại lên file có dấu phải exit 0" [ $? -eq 0 ]
assert "K: phần trên dấu phải về đúng template mới" kit_part_ok "$k/.claude/rules/agent-team.md"
assert "K: mọi thứ dưới dấu phải còn nguyên văn" own_part_is "$k/.claude/rules/agent-team.md" "$own_k"

# L. Bản cài cũ không có phần riêng (heading của kit lỡ có khoảng trắng cuối) → --force → đúng bằng template mới.
l="$tmp/old plain"
rules_repo "$l"
awk 'NR == 1 { $0 = $0 " \t" } { print }' "$old_tpl" > "$l/.claude/rules/agent-team.md"
install "$l" --force
assert "L: cài lại lên bản cũ không có phần riêng phải exit 0" [ $? -eq 0 ]
assert "L: file phải đúng bằng template mới" cmp -s "$tpl" "$l/.claude/rules/agent-team.md"

# M. File CRLF (checkout trên Windows): vẫn nhận ra dấu và heading của kit, không nhân đôi phần của kit.
m="$tmp/crlf"
rules_repo "$m"
crlf_own_k="$tmp/crlf-own-k.md"
to_crlf < "$own_k" > "$crlf_own_k"
cat "$tpl" "$own_k" | to_crlf > "$m/.claude/rules/agent-team.md"
install "$m"
assert "M: cài lại lên file CRLF có dấu phải exit 0" [ $? -eq 0 ]
assert "M: CRLF có dấu: phần của kit phải đúng một bản template mới" kit_part_ok "$m/.claude/rules/agent-team.md"
assert "M: CRLF có dấu: dưới dấu phải còn nguyên văn" own_part_is "$m/.claude/rules/agent-team.md" "$crlf_own_k"
cat "$old_tpl" "$sep_own_x" | to_crlf > "$m/.claude/rules/agent-team.md"
crlf_kept_x="$tmp/crlf-kept-x.md" # installer thêm dòng trống (LF), mục riêng giữ CRLF nguyên văn
{ echo; to_crlf < "$own_x"; } > "$crlf_kept_x"
install "$m" --force
assert "M: cài lại lên bản cũ CRLF phải exit 0" [ $? -eq 0 ]
assert "M: CRLF bản cũ: phần của kit phải đúng một bản template mới" kit_part_ok "$m/.claude/rules/agent-team.md"
assert "M: CRLF bản cũ: phải giữ mục riêng nguyên văn" own_part_is "$m/.claude/rules/agent-team.md" "$crlf_kept_x"

# N. grep có cờ quiet nhận stdin từ pipe trong file shell của kit: validate-kit đỏ, nêu file:dòng và cách sửa.
#    Dòng vi phạm dựng bằng $bar để chính file này không vi phạm. Dòng code của lint nằm trong
#    validate-kit.sh đã cài, nên lần chạy xanh cũng là bằng chứng lint không tự báo mình.
n="$tmp/pipe grep"
new_repo "$n"
install "$n"
lib="$n/.claude/hooks/lib.sh"
cp "$lib" "$tmp/lib.sh.orig"
first=$(($(wc -l < "$lib") + 1))
bar='|'
cat >> "$lib" <<EOF
printf '%s' abc $bar grep -q b
printf '%s' abc $bar grep -Eiq B
printf '%s' abc ${bar}grep -qxF abc
printf '%s' abc $bar tr -d c $bar grep --quiet b
git status --porcelain $bar grep --silent .
printf '%s' abc \\
  $bar grep -s -q b
EOF
out="$(cd "$n" && ./scripts/validate-kit.sh 2>&1)"
assert "N: validate-kit phải đỏ khi grep -q nhận stdin từ pipe" [ $? -ne 0 ]
for i in 0 1 2 3 4 6; do
  case "$out" in
    *".claude/hooks/lib.sh:$((first + i)): "*) ok ;;
    *) bad "N: phải báo .claude/hooks/lib.sh:$((first + i)) → $out" ;;
  esac
done
assert "N: chỉ báo đúng 6 dòng vi phạm → $out" [ "$(grep -c 'lib\.sh:[0-9]*: ' <<<"$out")" = 6 ]
# shellcheck disable=SC2016  # $(...) là chữ trong thông báo
case "$out" in
  *'text_grep (lib.sh)'*'[ -n "$(...)" ]'*) ok ;;
  *) bad "N: thông báo phải nêu cách sửa: text_grep (lib.sh) hoặc [ -n \"\$(...)\" ] → $out" ;;
esac
msg="$(grep -m 1 'lib\.sh:[0-9]*: ' <<<"$out")"
cp "$tmp/lib.sh.orig" "$lib"
cat >> "$lib" <<'EOF'
false || grep -q x f
grep -q x f
grep -Eiq x f || true
printf '%s' abc | grep -c b
text_grep abc -q b
[ -n "$(git status --porcelain)" ]
# printf '%s' abc | grep -q b
  # printf '%s' abc | grep -Eiq b
EOF
printf '%s\n' "cat <<'EOF' >/dev/null" "$msg" EOF >> "$lib"
out="$(cd "$n" && ./scripts/validate-kit.sh 2>&1)"
assert "N: validate-kit không được báo ||, grep không pipe, pipe không quiet, comment, thông báo của lint → $out" [ $? -eq 0 ]
cp "$tmp/lib.sh.orig" "$lib"
(cd "$n" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "N: validate-kit phải xanh sau khi khôi phục" [ $? -eq 0 ]

# O. File shell chỉ repo kit mới có (installer không chép): ở repo đích, file cùng tên là của dự án,
#    validate-kit không kiểm (lint, bash -n, shellcheck). Ở bản chép repo kit thì vẫn kiểm.
repo_only="scripts/install-kit.sh scripts/test-install.sh scripts/test-plugin.sh plugin/run-hook.sh
  .claude/skills/verify-kit/helpers/sandbox.sh"
o="$tmp/own scripts"
new_repo "$o"
for f in $repo_only; do
  mkdir -p "$o/$(dirname "$f")"
  printf '#!/usr/bin/env bash\nif printf x %s grep -q x; then echo ok; fi\n' "$bar" > "$o/$f"
done
echo 'if then' >> "$o/plugin/run-hook.sh" # lỗi cú pháp: bash -n cũng không được chạy trên file của dự án
install "$o"
assert "O: install phải exit 0 khi dự án có file trùng tên mà kit không chép" [ $? -eq 0 ]
out="$(cd "$o" && ./scripts/validate-kit.sh 2>&1)"
assert "O: validate-kit không được kiểm file shell của dự án → $out" [ $? -eq 0 ]
p="$tmp/kit copy"
mkdir -p "$p/.claude"
cp -R "$kit/.claude/agents" "$kit/.claude/skills" "$kit/.claude/hooks" "$kit/.claude/settings.json" "$p/.claude/"
cp -R "$kit/.claude-plugin" "$kit/plugin" "$kit/scripts" "$p/"
(cd "$p" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "O: validate-kit trong bản chép repo kit phải xanh" [ $? -eq 0 ]
for f in $repo_only; do
  printf 'printf x %s grep -q x\n' "$bar" >> "$p/$f"
done
out="$(cd "$p" && ./scripts/validate-kit.sh 2>&1)"
assert "O: validate-kit ở repo kit phải đỏ khi file chỉ repo kit có vi phạm" [ $? -ne 0 ]
for f in $repo_only; do
  case "$out" in
    *"$f:$(wc -l < "$p/$f" | tr -d ' '): "*) ok ;;
    *) bad "O: ở repo kit phải báo $f:<dòng cuối> → $out" ;;
  esac
done

# P. check.sh: bước plugin và việc file plugin đổi kích hoạt test của kit chỉ có ở repo kit. Ở repo đích,
#    scripts/test-plugin.sh, plugin/, .claude-plugin/ là của dự án. test-hooks.sh và test-audit.sh thay bằng
#    stub exit 0 (bản thật mất ~2 phút): ca này chỉ kiểm check.sh quyết định chạy gì.
plugin_paths="scripts/test-plugin.sh plugin/run-hook.sh plugin/hooks.json .claude-plugin/marketplace.json"
edit_valid() { # edit_valid <file>: sửa mà JSON vẫn parse được, shell vẫn qua bash -n
  case "$1" in
    *.json) echo >> "$1" ;;
    *) echo '# sửa' >> "$1" ;;
  esac
}
q="$tmp/own plugin"
new_repo "$q"
mkdir -p "$q/scripts" "$q/plugin" "$q/.claude-plugin"
cat > "$q/scripts/test-plugin.sh" <<'EOF'
#!/usr/bin/env bash
# test-plugin.sh riêng của dự án: cần tên plugin.
[ $# -gt 0 ] || { echo "cách dùng: $0 <plugin>" >&2; exit 1; }
EOF
chmod +x "$q/scripts/test-plugin.sh"
printf '#!/usr/bin/env bash\necho hook\n' > "$q/plugin/run-hook.sh"
echo '{}' > "$q/plugin/hooks.json"
echo '{}' > "$q/.claude-plugin/marketplace.json"
install "$q"
assert "P: install phải exit 0 khi dự án có test-plugin.sh, plugin/, .claude-plugin/ riêng" [ $? -eq 0 ]
for s in test-hooks test-audit; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$q/scripts/$s.sh"
done
git -C "$q" -c core.autocrlf=false add -A
git -C "$q" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m project
out="$(cd "$q" && env -u CI KIT_SELFTEST=1 ./scripts/check.sh 2>&1)"
assert "P: ở repo đích, KIT_SELFTEST=1 check.sh phải xanh dù test-plugin.sh của dự án đỏ → $out" [ $? -eq 0 ]
case "$out" in
  *"▶ plugin"*) bad "P: ở repo đích, check.sh không được chạy scripts/test-plugin.sh của dự án → $out" ;;
  *"▶ hooks"*) ok ;;
  *) bad "P: KIT_SELFTEST=1 check.sh phải chạy test của kit (▶ hooks) → $out" ;;
esac
for f in $plugin_paths; do
  edit_valid "$q/$f"
  out="$(cd "$q" && env -u CI KIT_SELFTEST=0 ./scripts/check.sh 2>&1)"
  case "$out" in
    *"▶ hooks"*) bad "P: ở repo đích, sửa $f (của dự án) không được kích hoạt test của kit → $out" ;;
    *"bỏ qua test của kit"*) ok ;;
    *) bad "P: ở repo đích, sửa $f phải in 'bỏ qua test của kit' → $out" ;;
  esac
  git -C "$q" checkout -q -- .
done
# Repo kit: giữ nguyên hành vi. check.local.sh của repo kit chạy test-install.sh: thay bằng stub để không đệ quy.
r="$tmp/kit repo"
new_repo "$r"
mkdir -p "$r/.claude"
cp -R "$kit/.claude/agents" "$kit/.claude/skills" "$kit/.claude/hooks" "$kit/.claude/settings.json" "$r/.claude/"
cp -R "$kit/.claude-plugin" "$kit/plugin" "$kit/scripts" "$r/"
for s in test-hooks test-audit check.local; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$r/scripts/$s.sh"
done
printf '#!/usr/bin/env bash\necho "test-plugin (stub ca P)"\n' > "$r/scripts/test-plugin.sh"
git -C "$r" -c core.autocrlf=false add -A
git -C "$r" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit
out="$(cd "$r" && env -u CI KIT_SELFTEST=1 ./scripts/check.sh 2>&1)"
case "$out" in
  *"▶ plugin"*"test-plugin (stub ca P)"*) ok ;;
  *) bad "P: ở repo kit, KIT_SELFTEST=1 check.sh phải chạy scripts/test-plugin.sh → $out" ;;
esac
for f in $plugin_paths; do
  edit_valid "$r/$f"
  out="$(cd "$r" && env -u CI KIT_SELFTEST=0 ./scripts/check.sh 2>&1)"
  case "$out" in
    *"▶ hooks"*) ok ;;
    *) bad "P: ở repo kit, sửa $f phải kích hoạt test của kit (▶ hooks) → $out" ;;
  esac
  git -C "$r" checkout -q -- .
done

# Q. Skill chỉ repo kit có (verify-kit): ở repo kit, validate-kit kiểm frontmatter và link của nó, và
#    manifest plugin chỉ được phát 4 skill của kit (trỏ cả .claude/skills/ thì verify-kit lọt sang mọi
#    dự án cài plugin). Ở repo đích, skill cùng tên là của dự án, không bị kiểm.
vq="$tmp/kit copy Q"
mkdir -p "$vq/.claude"
cp -R "$kit/.claude/agents" "$kit/.claude/skills" "$kit/.claude/hooks" "$kit/.claude/settings.json" "$vq/.claude/"
cp -R "$kit/.claude-plugin" "$kit/plugin" "$kit/scripts" "$vq/"
vk="$vq/.claude/skills/verify-kit"
cp "$vk/SKILL.md" "$tmp/vk-skill.orig"
cp "$vk/features/README.md" "$tmp/vk-features.orig"
cp "$vq/.claude-plugin/plugin.json" "$tmp/plugin.json.orig"
(cd "$vq" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "Q: bản chép repo kit phải xanh trước khi sửa" [ $? -eq 0 ]
sed 's/^name: verify-kit$/name: verify-khac/' "$tmp/vk-skill.orig" > "$vk/SKILL.md"
out="$(cd "$vq" && ./scripts/validate-kit.sh 2>&1)"
assert "Q: repo kit: verify-kit sai name phải đỏ" [ $? -ne 0 ]
case "$out" in
  *".claude/skills/verify-kit/SKILL.md: name phải là 'verify-kit'"*) ok ;;
  *) bad "Q: phải báo name sai của verify-kit → $out" ;;
esac
cp "$tmp/vk-skill.orig" "$vk/SKILL.md"
printf '\n[gãy](khong-co.md)\n' >> "$vk/features/README.md"
out="$(cd "$vq" && ./scripts/validate-kit.sh 2>&1)"
assert "Q: repo kit: link gãy trong feature map của verify-kit phải đỏ" [ $? -ne 0 ]
case "$out" in
  *".claude/skills/verify-kit/features/README.md: link gãy → khong-co.md"*) ok ;;
  *) bad "Q: phải báo link gãy trong features/README.md → $out" ;;
esac
cp "$tmp/vk-features.orig" "$vk/features/README.md"
"$py" - "$vq/.claude-plugin/plugin.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["skills"] = "./.claude/skills/"
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PYEOF
out="$(cd "$vq" && ./scripts/validate-kit.sh 2>&1)"
assert "Q: plugin.json trỏ cả .claude/skills/ (phát luôn verify-kit) phải đỏ" [ $? -ne 0 ]
case "$out" in *"plugin.json skills"*) ok ;; *) bad "Q: phải báo plugin.json skills → $out" ;; esac
cp "$tmp/plugin.json.orig" "$vq/.claude-plugin/plugin.json"
(cd "$vq" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "Q: bản chép repo kit phải xanh sau khi khôi phục" [ $? -eq 0 ]
vr="$tmp/own verify skill"
new_repo "$vr"
mkdir -p "$vr/.claude/skills/verify-kit"
printf 'không có frontmatter\n[gãy](khong-co.md)\n' > "$vr/.claude/skills/verify-kit/SKILL.md"
install "$vr"
assert "Q: install phải exit 0 khi dự án có skill verify-kit riêng" [ $? -eq 0 ]
out="$(cd "$vr" && ./scripts/validate-kit.sh 2>&1)"
assert "Q: repo đích: validate-kit không được kiểm skill verify-kit của dự án → $out" [ $? -eq 0 ]
case "$out" in *"4 skills"*) ok ;; *) bad "Q: repo đích chỉ kiểm 4 skill của kit → $out" ;; esac

# R. Repo chưa có CLAUDE.md: tạo từ khung của dự án, không chép CLAUDE.md của repo kit.
#    Quy ước đội chỉ nằm ở .claude/rules/agent-team.md. Cài lại không đổi CLAUDE.md.
proj_tpl="$kit/templates/project-CLAUDE.md"
lacks_team_rules() { ! grep -qF '/team-lead <task>' "$1"; }
noc="$tmp/no claude"
new_repo "$noc"
run_install "$noc"
assert "R: install phải exit 0" [ $? -eq 0 ]
assert "R: CLAUDE.md phải đúng bằng templates/project-CLAUDE.md" cmp -s "$proj_tpl" "$noc/CLAUDE.md"
assert "R: CLAUDE.md mới không được chứa quy ước đội" lacks_team_rules "$noc/CLAUDE.md"
assert "R: báo điền TODO thì CLAUDE.md mới phải có TODO" grep -q 'TODO' "$noc/CLAUDE.md"
# Agent, skill và hook của kit trỏ tới các mục này "trong CLAUDE.md".
assert "R: CLAUDE.md mới phải có quy ước commit" grep -qF 'Conventional Commits' "$noc/CLAUDE.md"
assert "R: CLAUDE.md mới phải có mục Quyền tự chủ" grep -qx '## Quyền tự chủ' "$noc/CLAUDE.md"
assert "R: mục cuối của CLAUDE.md mới phải là bảng Rule ↔ Thứ thực thi → $(grep '^## ' "$noc/CLAUDE.md" | tail -n 1)" \
  [ "$(grep '^## ' "$noc/CLAUDE.md" | tail -n 1)" = '## Rule ↔ Thứ thực thi' ]
assert "R: bảng Rule ↔ Thứ thực thi của dự án phải có header, chưa có dòng nào → $(tail -n 2 "$noc/CLAUDE.md")" \
  [ "$(tail -n 2 "$noc/CLAUDE.md")" = '| Rule | Thực thi bởi |
|---|---|' ]
assert "R: lần cài đầu .claude/rules/agent-team.md phải đúng bằng template" cmp -s "$tpl" "$noc/.claude/rules/agent-team.md"
assert "R: không được cảnh báo về CLAUDE.md" no_claude_warning
if grep -q 'CLAUDE.md đã có' "$tmp/out"; then bad "R: vừa tạo CLAUDE.md thì không được báo CLAUDE.md đã có"; else ok; fi
run_install "$noc" --force
assert "R: cài lại với --force phải exit 0" [ $? -eq 0 ]
assert "R: cài lại với --force không được đổi CLAUDE.md" cmp -s "$proj_tpl" "$noc/CLAUDE.md"
assert "R: cài lại với --force thì .claude/rules/agent-team.md vẫn đúng bằng template" cmp -s "$tpl" "$noc/.claude/rules/agent-team.md"
assert "R: cài lại với --force không được cảnh báo về CLAUDE.md" no_claude_warning
run_install "$noc"
assert "R: cài lại không --force phải exit 0" [ $? -eq 0 ]
assert "R: cài lại không --force không được đổi CLAUDE.md" cmp -s "$proj_tpl" "$noc/CLAUDE.md"
assert "R: cài lại không --force thì .claude/rules/agent-team.md vẫn đúng bằng template" cmp -s "$tpl" "$noc/.claude/rules/agent-team.md"
assert "R: cài lại không --force không được cảnh báo về CLAUDE.md" no_claude_warning

# S. Bản cài cũ: CLAUDE.md là bản chép từ CLAUDE.md của kit, chưa có .claude/rules/agent-team.md.
#    Cài lại: tạo rules, không sửa CLAUDE.md, cảnh báo quy ước đội nằm hai nơi ở mọi lần chạy.
oldc="$tmp/old claude"
new_repo "$oldc"
install "$oldc"
rm -f "$oldc/.claude/rules/agent-team.md"
cp "$kit/CLAUDE.md" "$oldc/CLAUDE.md"
run_install "$oldc" --force
assert "S: cài lại lên bản cũ phải exit 0" [ $? -eq 0 ]
assert "S: không được sửa CLAUDE.md chép từ kit cũ" cmp -s "$kit/CLAUDE.md" "$oldc/CLAUDE.md"
assert "S: phải tạo .claude/rules/agent-team.md đúng bằng template" cmp -s "$tpl" "$oldc/.claude/rules/agent-team.md"
assert "S: phải cảnh báo ⚠ (stderr) CLAUDE.md còn quy ước đội của kit cũ" claude_warned
run_install "$oldc"
assert "S: chạy lại phải exit 0" [ $? -eq 0 ]
assert "S: CLAUDE.md còn quy ước đội thì chạy lại vẫn phải cảnh báo" claude_warned

# T. Cài mới ghi .claude/agent-team-kit.txt: commit kit đã cài và đúng danh sách file kit đã chép.
man=.claude/agent-team-kit.txt
kit_sha="$(git -C "$kit" rev-parse HEAD 2>/dev/null || echo unknown)"
section() { # section <manifest> <kit-files|kit-dropped>: in các dòng của mục đó
  awk -v s="$2:" '/^kit-(commit|files|dropped):/ { on = ($0 == s); next } on' "$1"
}
no_dropped_warning() { ! grep -q 'kit đã bỏ' "$tmp/out" "$tmp/err"; }
tm="$tmp/manifest"
new_repo "$tm"
run_install "$tm"
assert "T: install phải exit 0" [ $? -eq 0 ]
assert "T: phải tạo $man" [ -f "$tm/$man" ]
assert "T: hai dòng đầu phải là comment, dòng 2 là lệnh xem kit có gì mới → $(head -n 2 "$tm/$man")" \
  [ "$(head -n 2 "$tm/$man")" = "# Bản Agents-Team-coding cài vào repo này. install-kit.sh ghi file này, đừng sửa tay.
# Kit có gì mới: git -C <thư mục kit> log --oneline <kit-commit>..HEAD -- .claude scripts templates" ]
assert "T: phải có các mục kit-commit, kit-files, kit-dropped theo thứ tự → $(grep '^kit-' "$tm/$man")" \
  [ "$(grep -o '^kit-[a-z]*:' "$tm/$man" | tr '\n' ' ')" = "kit-commit: kit-files: kit-dropped: " ]
assert "T: kit-commit phải là HEAD của kit $kit_sha (kit đang sửa thì kèm -dirty) → $(grep '^kit-commit' "$tm/$man")" \
  grep -qE "^kit-commit: $kit_sha(-dirty)?\$" "$tm/$man"
if grep -q $'\r' "$tm/$man"; then bad "T: $man phải là LF"; else ok; fi
copied="$(sed -n 's/^✔ đã chép \([0-9]*\) file của kit$/\1/p' "$tmp/out")"
listed="$(section "$tm/$man" kit-files)"
listed_n="$(printf '%s\n' "$listed" | grep -c .)"
assert "T: kit-files phải có đúng $copied file đã chép → $listed_n" [ "$listed_n" = "$copied" ]
for p in .claude/agents/architect.md scripts/check.sh; do
  if grep -qxF "$p" <<<"$listed"; then ok; else bad "T: kit-files thiếu $p"; fi
done
mismatch=""
while IFS= read -r p; do
  [ -f "$tm/$p" ] && cmp -s "$kit/$p" "$tm/$p" || mismatch="$mismatch $p"
done <<<"$listed"
assert "T: mỗi dòng trong kit-files phải là file đã cài, giống hệt bản của kit → khác:$mismatch" [ -z "$mismatch" ]
assert "T: lần cài đầu kit-dropped phải rỗng → $(section "$tm/$man" kit-dropped)" [ -z "$(section "$tm/$man" kit-dropped)" ]
assert "T: lần cài đầu không được báo file kit đã bỏ" no_dropped_warning
assert "T: phải báo ✔ commit kit đã ghi, dạng 7 ký tự → $(cat "$tmp/out")" \
  grep -qxE "✔ $man: kit ${kit_sha:0:7}(-dirty)?" "$tmp/out"

# U. Chạy lại cùng commit kit (có và không --force): manifest y hệt từng byte, không báo commit trước.
cp "$tm/$man" "$tmp/man-T"
run_install "$tm"
assert "U: chạy lại phải exit 0" [ $? -eq 0 ]
assert "U: chạy lại phải cho $man y hệt" cmp -s "$tmp/man-T" "$tm/$man"
if grep -q 'trước:' "$tmp/out"; then bad "U: cùng commit kit thì không được báo commit trước"; else ok; fi
run_install "$tm" --force
assert "U: chạy lại với --force phải exit 0" [ $? -eq 0 ]
assert "U: chạy lại với --force phải cho $man y hệt" cmp -s "$tmp/man-T" "$tm/$man"

# V. Lần cài trước (commit khác) có old.md mà kit đã bỏ, repo vẫn còn, và gone.md đã bị xoá khỏi repo.
#    Dừng vì trùng file thì giữ nguyên manifest cũ. Cài lại: báo old.md, không xoá, ghi vào kit-dropped.
assert "V: dừng vì trùng file (ca C) thì không được tạo $man" [ ! -e "$c/$man" ]
assert "V: dừng vì settings.json hỏng (ca E) thì không được tạo $man" [ ! -e "$e/$man" ]
old_p=.claude/skills/team-lead/playbooks/old.md
gone_p=.claude/agents/gone.md
old_sha=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
mkdir -p "$tm/$(dirname "$old_p")"
echo "playbook mà kit đã bỏ" > "$tm/$old_p"
awk -v a="$old_p" -v b="$gone_p" -v s="$old_sha" '
  /^kit-commit:/ { print "kit-commit: " s; next }
  { print }
  $0 == "kit-files:" { print a; print b }' "$tmp/man-T" > "$tm/$man"
cp "$tm/$man" "$tmp/man-V"
echo "sửa riêng" >> "$tm/.claude/agents/architect.md"
run_install "$tm"
assert "V: trùng file phải exit khác 0" [ $? -ne 0 ]
assert "V: dừng vì trùng file thì không được ghi lại $man" cmp -s "$tmp/man-V" "$tm/$man"
cp "$kit/.claude/agents/architect.md" "$tm/.claude/agents/architect.md"
run_install "$tm"
assert "V: cài lại phải exit 0" [ $? -eq 0 ]
assert "V: phải cảnh báo ⚠ (stderr) kit đã bỏ 1 file → $(cat "$tmp/err")" grep -q '^⚠ kit đã bỏ 1 file' "$tmp/err"
assert "V: cảnh báo phải nêu $old_p trên một dòng thụt lề" grep -qxF "  $old_p" "$tmp/err"
if grep -qF gone.md "$tmp/err"; then bad "V: file đã xoá khỏi repo thì không được báo"; else ok; fi
assert "V: không được xoá file kit đã bỏ" [ -f "$tm/$old_p" ]
assert "V: kit-files phải đúng danh sách của kit mới" [ "$(section "$tm/$man" kit-files)" = "$listed" ]
assert "V: kit-dropped phải đúng là $old_p → $(section "$tm/$man" kit-dropped)" [ "$(section "$tm/$man" kit-dropped)" = "$old_p" ]
if grep -qF gone.md "$tm/$man"; then bad "V: manifest mới không được ghi lại file đã xoá"; else ok; fi
assert "V: phải báo commit trước → $(grep "^✔ $man" "$tmp/out")" \
  grep -qxE "✔ $man: kit ${kit_sha:0:7}(-dirty)? \(trước: ${old_sha:0:7}\)" "$tmp/out"

# W. Chạy lại: vẫn báo old.md (đọc từ kit-dropped) tới khi người dùng xoá. Manifest CRLF (checkout trên
#    Windows) có old.md ở cả hai mục: báo đúng một lần, không có \r trong tên, file ghi lại là LF.
cp "$tm/$man" "$tmp/man-V2"
run_install "$tm"
assert "W: chạy lại phải exit 0" [ $? -eq 0 ]
assert "W: chạy lại vẫn phải báo $old_p" grep -qxF "  $old_p" "$tmp/err"
assert "W: chạy lại phải cho $man y hệt" cmp -s "$tmp/man-V2" "$tm/$man"
awk -v a="$old_p" '{ print } $0 == "kit-files:" { print a }' "$tmp/man-V2" | to_crlf > "$tm/$man"
run_install "$tm" --force
assert "W: manifest CRLF: cài lại phải exit 0" [ $? -eq 0 ]
assert "W: manifest CRLF: phải báo $old_p đúng một lần → $(cat "$tmp/err")" [ "$(grep -cxF "  $old_p" "$tmp/err")" = 1 ]
if grep -q $'\r' "$tmp/err"; then bad "W: manifest CRLF: tên file báo ra không được có \\r"; else ok; fi
if grep -q 'trước:' "$tmp/out"; then bad "W: manifest CRLF cùng commit kit thì không được báo commit trước"; else ok; fi
assert "W: manifest CRLF: file ghi lại phải đúng bản LF như lần trước" cmp -s "$tmp/man-V2" "$tm/$man"

# X. Người dùng xoá file kit đã bỏ: cài lại thì không báo nữa, manifest về như lần cài đầu (kit-dropped rỗng).
rm "$tm/$old_p"
run_install "$tm"
assert "X: cài lại phải exit 0" [ $? -eq 0 ]
assert "X: đã xoá file kit đã bỏ thì không được báo" no_dropped_warning
assert "X: manifest phải về như lần cài đầu" cmp -s "$tmp/man-T" "$tm/$man"

# Y. Repo ignore .claude/*: manifest phải được mở ngoại lệ (là file, không phải thư mục), cài lại không thêm trùng.
ig="$tmp/ignore claude"
new_repo "$ig"
printf '.claude/*\n' > "$ig/.gitignore"
install "$ig"
assert "Y: install phải exit 0" [ $? -eq 0 ]
if git -C "$ig" check-ignore -q "$man"; then bad "Y: $man vẫn bị .gitignore bỏ qua"; else ok; fi
install "$ig"
assert "Y: cài lại phải exit 0" [ $? -eq 0 ]
assert "Y: cài lại không được thêm trùng ngoại lệ cho $man" [ "$(grep -cxF "!$man" "$ig/.gitignore")" = 1 ]

# Z. Kit không phải git repo (tải zip): kit-commit: unknown. Kit là git repo: sạch thì đúng HEAD; sửa file đã
#    theo dõi thì thêm -dirty; file chưa theo dõi không tính.
kit_copy() { # kit_copy <thư mục>: chép phần installer cần của kit (bản đang sửa, không phải bản đã commit)
  mkdir -p "$1/.claude"
  cp -R "$kit/.claude/agents" "$kit/.claude/skills" "$kit/.claude/hooks" "$kit/.claude/settings.json" "$1/.claude/"
  cp -R "$kit/scripts" "$kit/templates" "$1/"
}
zk="$tmp/zip kit"
kit_copy "$zk"
zt="$tmp/from zip"
new_repo "$zt"
"$zk/scripts/install-kit.sh" "$zt" >/dev/null 2>&1
assert "Z: cài từ kit không phải git repo phải exit 0" [ $? -eq 0 ]
assert "Z: kit không phải git repo thì phải ghi kit-commit: unknown → $(grep '^kit-commit' "$zt/$man")" \
  grep -qx 'kit-commit: unknown' "$zt/$man"
gk="$tmp/git kit"
new_repo "$gk"
kit_copy "$gk"
echo "ghi chú" > "$gk/NOTES.md"
git -C "$gk" -c core.autocrlf=false add -A
git -C "$gk" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit
gk_sha="$(git -C "$gk" rev-parse HEAD)"
gt="$tmp/from git kit"
new_repo "$gt"
echo "chưa theo dõi" > "$gk/untracked.txt"
"$gk/scripts/install-kit.sh" "$gt" >/dev/null 2>&1
assert "Z: kit sạch (chỉ có file chưa theo dõi) thì kit-commit phải đúng HEAD, không -dirty → $(grep '^kit-commit' "$gt/$man")" \
  grep -qx "kit-commit: $gk_sha" "$gt/$man"
echo "sửa" >> "$gk/NOTES.md"
"$gk/scripts/install-kit.sh" "$gt" > "$tmp/out" 2>/dev/null
assert "Z: kit có file đã theo dõi bị sửa thì kit-commit phải kèm -dirty → $(grep '^kit-commit' "$gt/$man")" \
  grep -qx "kit-commit: $gk_sha-dirty" "$gt/$man"
assert "Z: phải báo commit trước khi trạng thái kit đổi → $(grep "^✔ $man" "$tmp/out")" \
  grep -qxF "✔ $man: kit ${gk_sha:0:7}-dirty (trước: ${gk_sha:0:7})" "$tmp/out"

# AA. CLAUDE.md riêng có nhắc /team-lead <task> nhưng không có bảng Rule ↔ Thứ thực thi: không phải bản chép
#     CLAUDE.md của kit cũ (mọi bản đó có cả hai chuỗi), nên không cảnh báo.
own_tl="$tmp/own team-lead"
new_repo "$own_tl"
# shellcheck disable=SC2016  # dấu ` là chữ markdown
echo 'Dùng `/team-lead <task>` cho task lớn.' > "$own_tl/CLAUDE.md"
cp "$own_tl/CLAUDE.md" "$tmp/own-tl-claude.orig"
run_install "$own_tl"
assert "AA: install phải exit 0" [ $? -eq 0 ]
assert "AA: CLAUDE.md riêng chỉ nhắc /team-lead <task> thì không được cảnh báo về CLAUDE.md → $(cat "$tmp/err")" no_claude_warning
assert "AA: không được sửa CLAUDE.md có sẵn" cmp -s "$tmp/own-tl-claude.orig" "$own_tl/CLAUDE.md"

# AB. CLAUDE.md là symlink gãy: coi như chưa có, cp không ghi qua được thì báo ✘ và exit 1, không báo đã tạo.
#     Đích nằm trong thư mục không có để cp của GNU lẫn BSD đều lỗi.
dang="$tmp/dangling claude"
new_repo "$dang"
if ln -s khong-co/khong-co.md "$dang/CLAUDE.md" 2>/dev/null && [ -L "$dang/CLAUDE.md" ]; then
  run_install "$dang"
  assert "AB: không tạo được CLAUDE.md thì phải exit khác 0" [ $? -ne 0 ]
  if grep -qF '✔ tạo CLAUDE.md' "$tmp/out"; then bad "AB: cp lỗi thì không được báo ✔ tạo CLAUDE.md"; else ok; fi
  assert "AB: phải báo ✘ (stderr) không tạo được CLAUDE.md → $(cat "$tmp/err")" grep -q '^✘.*CLAUDE\.md' "$tmp/err"
else
  printf '⚠ bỏ qua ca AB: không tạo được symlink ở máy này\n'
fi

# AC. Kit giải nén vào thư mục con của một git repo khác (vd home là repo dotfiles): kit không phải gốc repo
#     nên kit-commit: unknown, không lấy commit hay trạng thái -dirty của repo bên ngoài.
outer="$tmp/dotfiles"
new_repo "$outer"
echo "dotfiles" > "$outer/README"
git -C "$outer" add README
git -C "$outer" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m dotfiles
echo "sửa" >> "$outer/README"
kit_copy "$outer/tools/kit"
nk="$tmp/from nested kit"
new_repo "$nk"
"$outer/tools/kit/scripts/install-kit.sh" "$nk" >/dev/null 2>&1
assert "AC: cài từ kit trong repo khác phải exit 0" [ $? -eq 0 ]
assert "AC: kit không phải gốc repo thì phải ghi kit-commit: unknown → $(grep '^kit-commit' "$nk/$man")" \
  grep -qx 'kit-commit: unknown' "$nk/$man"

if [ "$fails" -gt 0 ]; then
  printf '✘ install: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ install: %s test xanh\n' "$pass"
