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
to_crlf() { awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }'; } # file đã CRLF (clone trên Windows) giữ nguyên
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

# H. Template có đúng một dòng dấu, là dòng cuối, kết thúc bằng newline (LF, hoặc CRLF khi clone trên Windows).
assert "H: template phải có đúng một dòng bắt đầu bằng $mark" [ "$(grep -c "^$mark" "$tpl")" = 1 ]
case "$(tail -n 1 "$tpl" | tr -d '\r')" in
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

# MA. Phần riêng có byte không phải UTF-8 (Latin-1 é = \351), installer chạy ở locale UTF-8: trên macOS từng dừng
#     (ca Q của PR #22, mục 4.2 của docs/viec-can-lam.md). Phải exit 0 và giữ phần riêng nguyên byte, có dấu hay bản cũ.
utf8_loc=""
for l8 in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  [ "$(LC_ALL="$l8" locale charmap 2>/dev/null)" = UTF-8 ] && utf8_loc="$l8" && break
done
if [ -n "$utf8_loc" ]; then
  ma="$tmp/latin1"
  rules_repo "$ma"
  own_l1="$tmp/own-latin1.md"
  printf '## Riêng Z\n- caf\351\n' > "$own_l1"
  cat "$tpl" "$own_l1" > "$ma/.claude/rules/agent-team.md"
  LC_ALL="$utf8_loc" run_install "$ma"
  rc=$?
  assert "MA: cài lại khi phần riêng có byte Latin-1 phải exit 0 ($utf8_loc) → $(cat "$tmp/err")" [ "$rc" -eq 0 ]
  assert "MA: Latin-1 có dấu: phần của kit phải đúng template mới" kit_part_ok "$ma/.claude/rules/agent-team.md"
  assert "MA: Latin-1 có dấu: dưới dấu phải còn nguyên byte" own_part_is "$ma/.claude/rules/agent-team.md" "$own_l1"
  { echo; cat "$own_l1"; } > "$tmp/sep-own-latin1.md"
  cat "$old_tpl" "$tmp/sep-own-latin1.md" > "$ma/.claude/rules/agent-team.md"
  LC_ALL="$utf8_loc" run_install "$ma" --force
  rc=$?
  assert "MA: cài lại lên bản cũ có Latin-1 phải exit 0 ($utf8_loc) → $(cat "$tmp/err")" [ "$rc" -eq 0 ]
  assert "MA: Latin-1 bản cũ: phần của kit phải đúng template mới" kit_part_ok "$ma/.claude/rules/agent-team.md"
  assert "MA: Latin-1 bản cũ: phải giữ mục riêng nguyên byte" own_part_is "$ma/.claude/rules/agent-team.md" \
    "$tmp/sep-own-latin1.md"
else
  printf '⚠ install: bỏ qua ca MA (không có locale UTF-8 trên máy này)\n'
fi

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
# Câu thông báo trong chuỗi nháy đơn (không chạy): hook không được có here-doc (ca NB).
case "$msg" in *"'"*) bad "N: thông báo của lint không được có nháy đơn → $msg" ;; esac
printf ": '%s'\n" "$msg" >> "$lib"
out="$(cd "$n" && ./scripts/validate-kit.sh 2>&1)"
assert "N: validate-kit không được báo ||, grep không pipe, pipe không quiet, comment, thông báo của lint → $out" [ $? -eq 0 ]
cp "$tmp/lib.sh.orig" "$lib"
(cd "$n" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "N: validate-kit phải xanh sau khi khôi phục" [ $? -eq 0 ]

# NB. Hook dùng here-doc, <<< hay <(...): bash đọc chúng qua file tạm hay /dev/fd, đĩa đầy hay TMPDIR không ghi được
#     thì vòng đọc không chạy lần nào và guard cho qua (PR #21; mục 4.4 của docs/viec-can-lam.md). validate-kit
#     đỏ, nêu file:dòng. Comment và < đơn (redirect, chữ trong regex) không bị báo.
first=$(($(wc -l < "$lib") + 1))
printf '%s\n' "while read -r x; do :; done <<'E'" E 'read -r x <<< "$y"' 'while read -r x; do :; done < <(printf x)' \
  'cat <<-E' E 'diff <(printf a) /dev/null' 'printf x > >(cat)' >> "$lib"
out="$(cd "$n" && ./scripts/validate-kit.sh 2>&1)"
assert "NB: validate-kit phải đỏ khi hook dùng here-doc, <<< hay <(...)" [ $? -ne 0 ]
for i in 0 2 3 4 6 7; do
  case "$out" in
    *".claude/hooks/lib.sh:$((first + i)): "*) ok ;;
    *) bad "NB: phải báo .claude/hooks/lib.sh:$((first + i)) → $out" ;;
  esac
done
assert "NB: chỉ báo đúng 6 dòng vi phạm → $out" [ "$(grep -c 'lib\.sh:[0-9]*: ' <<<"$out")" = 6 ]
cp "$tmp/lib.sh.orig" "$lib"
printf '%s\n' '# không dùng <<< hay <(...), xem text_grep' '  # cat <<EOF' ': "$(cat < /dev/null)"' ": '[;&|)<>]'" \
  'printf "%s" a >/dev/null 2>&1' >> "$lib"
out="$(cd "$n" && ./scripts/validate-kit.sh 2>&1)"
assert "NB: validate-kit không được báo comment, < đơn, <> trong regex → $out" [ $? -eq 0 ]
cp "$tmp/lib.sh.orig" "$lib"

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
# Hook của plugin (plugin/run-hook.sh, chỉ repo kit có) cũng không được dùng here-doc, <<< hay <(...) (ca NB): từng có
# `exec bash "$hook" <<<"$input"`, đĩa đầy thì Stop gate của plugin không chạy (reviewer PR #35).
printf '%s\n' 'cat <<< "$x"' 'printf x > >(cat)' >> "$p/plugin/run-hook.sh"
last=$(wc -l < "$p/plugin/run-hook.sh" | tr -d ' ')
out="$(cd "$p" && ./scripts/validate-kit.sh 2>&1)"
for l in $((last - 1)) "$last"; do
  case "$out" in
    *"plugin/run-hook.sh:$l: hook dùng"*) ok ;;
    *) bad "O: ở repo kit phải báo here-string, >(...) ở plugin/run-hook.sh:$l → $out" ;;
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
noc_lf="$tmp/noc-CLAUDE-lf.md" # bỏ \r: kit checkout CRLF (Windows) thì khung CLAUDE.md cũng CRLF
tr -d '\r' < "$noc/CLAUDE.md" > "$noc_lf"
# Agent, skill và hook của kit trỏ tới các mục này "trong CLAUDE.md".
assert "R: CLAUDE.md mới phải có quy ước commit" grep -qF 'Conventional Commits' "$noc/CLAUDE.md"
assert "R: CLAUDE.md mới phải có mục Quyền tự chủ" grep -qx '## Quyền tự chủ' "$noc_lf"
assert "R: mục cuối của CLAUDE.md mới phải là bảng Rule ↔ Thứ thực thi → $(grep '^## ' "$noc_lf" | tail -n 1)" \
  [ "$(grep '^## ' "$noc_lf" | tail -n 1)" = '## Rule ↔ Thứ thực thi' ]
assert "R: bảng Rule ↔ Thứ thực thi của dự án phải có header, chưa có dòng nào → $(tail -n 2 "$noc_lf")" \
  [ "$(tail -n 2 "$noc_lf")" = '| Rule | Thực thi bởi |
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

# AB. CLAUDE.md là symlink gãy: installer báo ✘ và exit 1 trước khi đụng repo, không báo đã tạo. Có chủ ý cả khi
#     thư mục của đích có sẵn: cp của BSD (macOS) từng ghi xuyên symlink, tạo file ở nơi nó trỏ tới (có thể ngoài repo).
dang="$tmp/dangling claude"
new_repo "$dang"
if ln -s khong-co/khong-co.md "$dang/CLAUDE.md" 2>/dev/null && [ -L "$dang/CLAUDE.md" ]; then
  run_install "$dang"
  assert "AB: không tạo được CLAUDE.md thì phải exit khác 0" [ $? -ne 0 ]
  if grep -qF '✔ tạo CLAUDE.md' "$tmp/out"; then bad "AB: cp lỗi thì không được báo ✔ tạo CLAUDE.md"; else ok; fi
  assert "AB: phải báo ✘ (stderr) không tạo được CLAUDE.md → $(cat "$tmp/err")" grep -q '^✘.*CLAUDE\.md' "$tmp/err"
  # Như C/E: dừng trước khi đụng repo (4.5 của docs/viec-can-lam.md, ghi nhận của PR #25).
  assert "AB: CLAUDE.md là symlink gãy thì không được chép file nào" [ ! -e "$dang/.claude/agents/architect.md" ]
  assert "AB: CLAUDE.md là symlink gãy thì không được tạo settings.json" [ ! -e "$dang/.claude/settings.json" ]
  assert "AB: CLAUDE.md là symlink gãy thì không được tạo .gitattributes" [ ! -e "$dang/.gitattributes" ]
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

# AD. File kit bị sửa riêng trong repo đã cài. Có --force thì ghi đè là việc sẽ làm, không phải lỗi:
#     báo ⚠ ghi đè (stderr), không có dòng ✘ nào. Không --force thì vẫn dừng với dòng ✘ như ca C.
fo="$tmp/force overwrite"
fo_p=.claude/agents/architect.md
new_repo "$fo"
install "$fo"
echo "sửa riêng" >> "$fo/$fo_p"
run_install "$fo" --force
assert "AD: cài lại với --force phải exit 0" [ $? -eq 0 ]
assert "AD: --force phải báo ⚠ ghi đè $fo_p (stderr) → $(cat "$tmp/err")" \
  grep -qxF "⚠ ghi đè $fo_p: bản trong repo khác bản của kit" "$tmp/err"
if grep -q '^✘' "$tmp/err"; then bad "AD: --force không được báo ✘ cho file sẽ ghi đè → $(cat "$tmp/err")"; else ok; fi
assert "AD: --force phải ghi đè bằng bản của kit" cmp -s "$kit/$fo_p" "$fo/$fo_p"
echo "sửa riêng" >> "$fo/$fo_p"
run_install "$fo"
assert "AD: không --force thì file trùng phải exit 1" [ $? -eq 1 ]
assert "AD: không --force phải báo ✘ $fo_p (stderr) → $(cat "$tmp/err")" \
  grep -qxF "✘ $fo_p đã tồn tại và khác bản của kit" "$tmp/err"
assert "AD: không --force phải báo ✘ dừng → $(cat "$tmp/err")" grep -q '^✘ dừng: 1 file trùng' "$tmp/err"
if grep -qF '⚠ ghi đè' "$tmp/err"; then bad "AD: không --force thì không được báo ⚠ ghi đè"; else ok; fi
assert "AD: không --force thì không được ghi đè bản sửa riêng" [ "$(tail -n 1 "$fo/$fo_p")" = "sửa riêng" ]

# AE..AL. Cập nhật kit (git pull rồi cài lại, không --force). File trong repo trùng một bản đã commit
#   trong lịch sử kit là file dự án chưa sửa: chép bản mới, không tính là trùng, không cần manifest.
#   Không trùng bản nào (dự án đã sửa, đã commit hay chưa) thì dừng như ca C. Kit không phải git repo: như ca C.
commit_all() { # commit_all <repo> <message>
  git -C "$1" -c core.autocrlf=false add -A
  git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "$2"
}
has_cr() { [ "$(($(tr -cd '\r' < "$1" | wc -c)))" -gt 0 ]; } # có \r; không dùng grep: grep của Git for Windows bỏ \r
to_lf_file() { tr -d '\r' < "$1" > "$tmp/to-lf" && cat "$tmp/to-lf" > "$1"; } # kit_copy trên Windows chép bản CRLF
run_kit() { local k="$1"; shift; "$k/scripts/install-kit.sh" "$@" > "$tmp/out" 2> "$tmp/err"; } # run_kit <kit> <repo> [--force]
no_conflict_line() { ! grep -q '^✘' "$tmp/err"; }
arch_p=.claude/agents/architect.md
guard_p=.claude/hooks/guard-irreversible.sh
uk="$tmp/update kit"
new_repo "$uk"
kit_copy "$uk"
commit_all "$uk" "kit A"
ua="$tmp/update clean"
ub="$tmp/update no manifest"
for t in "$ua" "$ub"; do
  new_repo "$t"
  "$uk/scripts/install-kit.sh" "$t" >/dev/null 2>&1
  commit_all "$t" "cài kit A"
done
echo "Dòng mới của kit (B)." >> "$uk/$arch_p"
commit_all "$uk" "kit B"

# AE. Kit đổi một file, dự án chưa sửa nó: cài lại không --force thì cập nhật.
run_kit "$uk" "$ua"
assert "AE: kit đổi file mà dự án chưa sửa thì cài lại không --force phải exit 0" [ $? -eq 0 ]
assert "AE: $arch_p phải là bản mới của kit" cmp -s "$uk/$arch_p" "$ua/$arch_p"
assert "AE: không được có dòng ✘ → $(cat "$tmp/err")" no_conflict_line
assert "AE: phải báo ✔ cập nhật 1 file kit → $(cat "$tmp/out")" grep -qxF '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out"
assert "AE: dòng ngay sau ✔ cập nhật phải là tên file, thụt hai dấu cách → $(cat "$tmp/out")" \
  [ "$(grep -xF -A1 '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out" | tail -n 1)" = "  $arch_p" ]

# AF. Bản cài cũ chưa có manifest: phân loại không cần kit-commit.
rm "$ub/$man"
run_kit "$uk" "$ub"
assert "AF: bản cài không có $man vẫn phải cập nhật, exit 0" [ $? -eq 0 ]
assert "AF: $arch_p phải là bản mới của kit" cmp -s "$uk/$arch_p" "$ub/$arch_p"
assert "AF: không được có dòng ✘ → $(cat "$tmp/err")" no_conflict_line
assert "AF: phải báo ✔ cập nhật 1 file kit → $(cat "$tmp/out")" grep -qxF '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out"

# AG. Dự án vá guard (đã commit), kit cũng đổi guard và architect.md: dừng, không chép gì, bản vá còn nguyên.
ug="$tmp/update patched"
uh="$tmp/update uncommitted"
for t in "$ug" "$uh"; do
  new_repo "$t"
  "$uk/scripts/install-kit.sh" "$t" >/dev/null 2>&1
  commit_all "$t" "cài kit B"
  echo "# bản vá của dự án" >> "$t/$guard_p"
done
commit_all "$ug" "vá guard"
cp "$uk/$arch_p" "$tmp/arch-B"
echo "# kit đổi guard (C)" >> "$uk/$guard_p"
echo "Dòng mới của kit (C)." >> "$uk/$arch_p"
commit_all "$uk" "kit C"
run_kit "$uk" "$ug"
assert "AG: dự án đã sửa file mà kit cũng đổi thì không --force phải exit 1" [ $? -eq 1 ]
assert "AG: phải báo ✘ $guard_p → $(cat "$tmp/err")" grep -qxF "✘ $guard_p đã tồn tại và khác bản của kit" "$tmp/err"
assert "AG: chỉ guard là trùng (architect.md là bản kit cũ) → $(cat "$tmp/err")" grep -q '^✘ dừng: 1 file trùng' "$tmp/err"
assert "AG: dừng thì không được chép $arch_p bản mới" cmp -s "$tmp/arch-B" "$ug/$arch_p"
assert "AG: bản vá guard phải còn nguyên" [ "$(tail -n 1 "$ug/$guard_p")" = "# bản vá của dự án" ]
run_kit "$uk" "$ug" --force
assert "AG: --force phải exit 0" [ $? -eq 0 ]
assert "AG: --force chỉ báo ⚠ ghi đè guard, không báo file dự án chưa sửa → $(cat "$tmp/err")" \
  [ "$(grep '^⚠ ghi đè' "$tmp/err")" = "⚠ ghi đè $guard_p: bản trong repo khác bản của kit" ]
assert "AG: --force phải cập nhật $arch_p" cmp -s "$uk/$arch_p" "$ug/$arch_p"
assert "AG: --force phải báo ✔ cập nhật 1 file kit → $(cat "$tmp/out")" grep -qxF '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out"

# AH. Bản vá guard chưa commit: vẫn là dự án đã sửa.
run_kit "$uk" "$uh"
assert "AH: bản sửa chưa commit thì không --force phải exit 1" [ $? -eq 1 ]
assert "AH: phải báo ✘ $guard_p → $(cat "$tmp/err")" grep -qxF "✘ $guard_p đã tồn tại và khác bản của kit" "$tmp/err"
assert "AH: dừng thì không được chép $arch_p bản mới" cmp -s "$tmp/arch-B" "$uh/$arch_p"
assert "AH: bản vá chưa commit phải còn nguyên" [ "$(tail -n 1 "$uh/$guard_p")" = "# bản vá của dự án" ]

# AI. Kit không phải git repo (bản chép không có .git): không có lịch sử để đối chiếu, file khác thì ✘ như ca C.
uz="$tmp/update zip kit"
cp -R "$uk" "$uz"
rm -rf "$uz/.git"
cp "$ub/$arch_p" "$tmp/ub-arch"
run_kit "$uz" "$ub"
assert "AI: kit không phải git repo, file khác thì phải exit 1" [ $? -eq 1 ]
assert "AI: phải báo ✘ $arch_p → $(cat "$tmp/err")" grep -qxF "✘ $arch_p đã tồn tại và khác bản của kit" "$tmp/err"
assert "AI: dừng thì không được chép $arch_p bản mới" cmp -s "$tmp/ub-arch" "$ub/$arch_p"

# AJ. Kit clone với core.autocrlf=true (mặc định Git for Windows): .md trong thư mục làm việc của kit là CRLF,
#     blob đã commit là LF. File chỉ khác bản kit đã commit ở dòng kết thúc là dự án chưa sửa: cập nhật.
ck="$tmp/crlf kit upstream"
new_repo "$ck"
kit_copy "$ck"
cp "$kit/.gitattributes" "$ck/"
to_lf_file "$ck/$arch_p" # blob LF như trên Linux; kit checkout CRLF (Windows) thì blob sẽ CRLF và AK không còn là ca băm lỗi
commit_all "$ck" "kit A"
cw="$tmp/crlf kit"
git -c core.autocrlf=true clone -q "$ck" "$cw"
git -C "$cw" config core.autocrlf true
ct="$tmp/crlf target"
new_repo "$ct"
"$cw/scripts/install-kit.sh" "$ct" >/dev/null 2>&1
commit_all "$ct" "cài kit A"
assert "AJ: điều kiện của ca: $arch_p trong repo phải có CRLF (\r)" has_cr "$ct/$arch_p"
echo "Dòng mới của kit (B)." >> "$ck/$arch_p"
commit_all "$ck" "kit B"
git -C "$cw" pull -q --ff-only
run_kit "$cw" "$ct"
assert "AJ: kit autocrlf=true, dự án chưa sửa thì cài lại không --force phải exit 0" [ $? -eq 0 ]
assert "AJ: $arch_p phải là bản mới của kit" cmp -s "$cw/$arch_p" "$ct/$arch_p"
assert "AJ: không được có dòng ✘ → $(cat "$tmp/err")" no_conflict_line
assert "AJ: phải báo ✔ cập nhật 1 file kit → $(cat "$tmp/out")" grep -qxF '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out"
# AJb. Cùng kit autocrlf=true: lần cài đầu chép settings.json nguyên văn (CRLF), cài lại gộp bằng Python từng ghi LF,
#      git diff hiện cả file dù nội dung không đổi (mục 4.7 cũ). Cài, commit, cài lại: repo đích phải sạch.
cs="$tmp/crlf settings target"
new_repo "$cs"
git -C "$cs" config core.autocrlf false # so đúng byte, cả trên runner Windows (autocrlf=true ở system)
"$cw/scripts/install-kit.sh" "$cs" >/dev/null 2>&1
commit_all "$cs" "cài kit"
assert "AJb: điều kiện của ca: settings.json của kit phải có CRLF (\r)" has_cr "$cw/.claude/settings.json"
run_kit "$cw" "$cs"
rc=$?
assert "AJb: cài lại phải exit 0 → $(cat "$tmp/err")" [ "$rc" -eq 0 ]
assert "AJb: cài lại kit không đổi thì repo đích phải sạch → $(git -C "$cs" status --porcelain)" [ -z "$(git -C "$cs" status --porcelain)" ]
# Có thứ để gộp (dự án bỏ một luật deny của kit): ghi lại file nhưng giữ CRLF, không dòng nào chỉ có LF. Gộp cần
# Python (installer cũng vậy).
if [ -n "$py" ]; then
  "$py" -c 'import json, sys
p = sys.argv[1]; d = json.loads(open(p, "rb").read().decode("utf-8-sig")); d["permissions"]["deny"].pop()
open(p, "w", encoding="utf-8", newline="\r\n").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")' "$cs/.claude/settings.json"
  commit_all "$cs" "bỏ một luật deny"
  run_kit "$cw" "$cs"
  assert "AJb: gộp lại luật deny của kit → $(git -C "$cs" diff --stat)" [ -n "$(git -C "$cs" status --porcelain)" ]
  lines="$(wc -l < "$cs/.claude/settings.json" | tr -d ' ')"
  crlf="$(tr -cd '\r' < "$cs/.claude/settings.json" | wc -c | tr -d ' ')"
  assert "AJb: gộp xong settings.json phải giữ CRLF ở mọi dòng ($crlf \\r trên $lines dòng)" [ "$crlf" = "$lines" ]
  # Kit ghi settings.json đúng định dạng của bộ gộp (indent 2): gộp lại luật đã bỏ thì ra đúng từng byte bản của kit.
  assert "AJb: gộp xong settings.json phải trùng bản (CRLF) của kit" cmp -s "$cw/.claude/settings.json" "$cs/.claude/settings.json"
fi

# AK. Git lỗi khi băm file của dự án (clean filter bắt buộc của kit lỗi): coi như không trùng bản nào, ✘ như ca C.
cp "$ct/$arch_p" "$tmp/ct-arch"
echo "Dòng mới của kit (C)." >> "$ck/$arch_p"
commit_all "$ck" "kit C"
git -C "$cw" pull -q --ff-only
echo '*.md filter=boom' > "$cw/.git/info/attributes"
git -C "$cw" config filter.boom.clean false
git -C "$cw" config filter.boom.required true
run_kit "$cw" "$ct"
assert "AK: băm lỗi thì phải exit 1" [ $? -eq 1 ]
assert "AK: phải báo ✘ $arch_p → $(cat "$tmp/err")" grep -qxF "✘ $arch_p đã tồn tại và khác bản của kit" "$tmp/err"
assert "AK: dừng thì không được chép $arch_p bản mới" cmp -s "$tmp/ct-arch" "$ct/$arch_p"

# AL. Lịch sử kit có blob CRLF (commit với core.autocrlf=false) mà git của kit là core.autocrlf=true: filter eol đổi
#     CRLF sang LF, nhưng file trùng từng byte với một bản đã commit vẫn là dự án chưa sửa.
cr="$tmp/crlf blob kit"
new_repo "$cr"
kit_copy "$cr"
cp "$kit/.gitattributes" "$cr/"
to_crlf < "$kit/$arch_p" > "$cr/$arch_p"
commit_all "$cr" "kit A"
git -C "$cr" config core.autocrlf true
crt="$tmp/crlf blob target"
new_repo "$crt"
"$cr/scripts/install-kit.sh" "$crt" >/dev/null 2>&1
commit_all "$crt" "cài kit A"
assert "AL: điều kiện của ca: $arch_p trong repo phải có CRLF (\r)" has_cr "$crt/$arch_p"
printf 'Dòng mới của kit (B).\r\n' >> "$cr/$arch_p"
commit_all "$cr" "kit B"
run_kit "$cr" "$crt"
assert "AL: blob CRLF trong lịch sử, dự án chưa sửa thì cài lại không --force phải exit 0" [ $? -eq 0 ]
assert "AL: $arch_p phải là bản mới của kit" cmp -s "$cr/$arch_p" "$crt/$arch_p"
assert "AL: không được có dòng ✘ → $(cat "$tmp/err")" no_conflict_line
assert "AL: phải báo ✔ cập nhật 1 file kit → $(cat "$tmp/out")" grep -qxF '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out"

# AM. Bản chỉ merge commit mới có (người dùng commit bản vá vào clone kit rồi git pull): nhánh X nối dòng cuối,
#     main chèn dòng đầu, merge tự gộp ra bản D mà không commit thường nào có. Dự án cài ở D, chưa sửa; kit merge
#     thêm nhánh Y. Cài lại không --force thì cập nhật.
mk="$tmp/merge kit"
new_repo "$mk"
git -C "$mk" config core.autocrlf false # runner Windows đặt autocrlf=true ở system: checkout nhánh sẽ đổi dòng kết thúc
kit_copy "$mk"
to_lf_file "$mk/$arch_p"
commit_all "$mk" "kit A"
mk_main="$(git -C "$mk" symbolic-ref --short HEAD)"
merge_into() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false merge -q --no-ff --no-edit "$2" >/dev/null; } # merge_into <repo> <nhánh>
git -C "$mk" checkout -q -b X
echo "Dòng cuối của nhánh X." >> "$mk/$arch_p"
commit_all "$mk" "X"
git -C "$mk" checkout -q "$mk_main"
{ echo "Dòng đầu của kit (C)."; cat "$mk/$arch_p"; } > "$tmp/arch-C"
cp "$tmp/arch-C" "$mk/$arch_p"
commit_all "$mk" "C"
git -C "$mk" branch Y
merge_into "$mk" X
assert "AM: điều kiện của ca: merge X phải tự gộp được" [ $? -eq 0 ]
mk_d="$(git -C "$mk" rev-parse "HEAD:$arch_p")"
case "$(git -C "$mk" log --no-merges --format= --raw --no-abbrev -- "$arch_p")" in
  *" $mk_d "*) bad "AM: điều kiện của ca: bản D không được có ở commit thường nào" ;;
  *) ok ;;
esac
mt="$tmp/merge target"
new_repo "$mt"
"$mk/scripts/install-kit.sh" "$mt" >/dev/null 2>&1
commit_all "$mt" "cài kit D"
git -C "$mk" checkout -q Y
awk 'NR == 3 { $0 = $0 " (Y)" } { print }' "$mk/$arch_p" > "$tmp/arch-Y"
cp "$tmp/arch-Y" "$mk/$arch_p"
commit_all "$mk" "Y"
git -C "$mk" checkout -q "$mk_main"
merge_into "$mk" Y
assert "AM: điều kiện của ca: merge Y phải tự gộp được" [ $? -eq 0 ]
run_kit "$mk" "$mt"
assert "AM: bản chỉ merge commit có, dự án chưa sửa thì cài lại không --force phải exit 0" [ $? -eq 0 ]
assert "AM: $arch_p phải là bản mới của kit" cmp -s "$mk/$arch_p" "$mt/$arch_p"
assert "AM: không được có dòng ✘ → $(cat "$tmp/err")" no_conflict_line
assert "AM: phải báo ✔ cập nhật 1 file kit → $(cat "$tmp/out")" grep -qxF '✔ cập nhật 1 file kit mà dự án chưa sửa' "$tmp/out"
# AMb. Như AM, nhưng git của kit đặt log.diffMerges=off hay remerge (config của người dùng): `-m` bị config đè, git
#      log không đọc merge hay đọc thêm blob giả, bản D không được nhận (reviewer PR #25, mục 4.6 cũ). Cài ở D
#      (commit merge X), kit đã tiến tới merge Y: cài lại không --force phải cập nhật.
mk_x="$(git -C "$mk" rev-parse "$mk_main^1")"
for dm in off remerge; do
  t="$tmp/merge target $dm"
  new_repo "$t"
  git -C "$mk" checkout -q "$mk_x"
  "$mk/scripts/install-kit.sh" "$t" >/dev/null 2>&1
  commit_all "$t" "cài kit D"
  git -C "$mk" checkout -q "$mk_main"
  git -C "$mk" config log.diffMerges "$dm"
  run_kit "$mk" "$t"
  rc=$?
  assert "AMb: log.diffMerges=$dm, bản chỉ merge commit có: cài lại không --force phải exit 0 → $(cat "$tmp/err")" [ "$rc" -eq 0 ]
  assert "AMb: log.diffMerges=$dm: $arch_p phải là bản mới của kit" cmp -s "$mk/$arch_p" "$t/$arch_p"
  git -C "$mk" config --unset log.diffMerges
done
# AMc. Lọc theo đường dẫn, git log cắt bớt lịch sử: ở merge mà file trùng một parent, git chỉ đi theo parent đó.
#      main sửa file (M1, dự án cài ở đây) rồi sửa tiếp (M2); nhánh Z sửa khác; main gộp Z lấy đúng bản Z (merge trùng
#      parent Z) rồi sửa tiếp. Bản M1 có trong lịch sử kit nhưng git log -- <file> chỉ đi nhánh Z. Ở git 2.43 `-m` tắt
#      việc cắt bớt, nhưng log.diffMerges=off đè `-m` và git lại cắt: cài lại (với config đó) phải cập nhật, không ✘
#      (mục 4.6 cũ).
git -C "$mk" branch Z
awk 'NR == 2 { $0 = $0 " (M1)" } { print }' "$mk/$arch_p" > "$tmp/arch-M1"
cp "$tmp/arch-M1" "$mk/$arch_p"
commit_all "$mk" "M1"
tz="$tmp/merge target M1"
new_repo "$tz"
"$mk/scripts/install-kit.sh" "$tz" >/dev/null 2>&1
commit_all "$tz" "cài kit M1"
echo "Dòng M2." >> "$mk/$arch_p"
commit_all "$mk" "M2"
git -C "$mk" checkout -q Z
awk 'NR == 4 { $0 = $0 " (Z)" } { print }' "$mk/$arch_p" > "$tmp/arch-Z"
cp "$tmp/arch-Z" "$mk/$arch_p"
commit_all "$mk" "Z"
git -C "$mk" checkout -q "$mk_main"
git -C "$mk" -c user.email=t@t -c user.name=t -c commit.gpgsign=false merge -q -s ours --no-commit Z >/dev/null 2>&1
git -C "$mk" checkout Z -- "$arch_p"
git -C "$mk" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --no-edit
assert "AMc: điều kiện của ca: HEAD phải là merge của Z" [ "$(git -C "$mk" rev-parse HEAD^2 2>/dev/null)" = "$(git -C "$mk" rev-parse Z)" ]
assert "AMc: điều kiện của ca: merge phải trùng parent Z ở $arch_p" git -C "$mk" diff --quiet HEAD^2 HEAD -- "$arch_p"
echo "Dòng sau khi gộp Z." >> "$mk/$arch_p"
commit_all "$mk" "sau Z"
git -C "$mk" config log.diffMerges off
case "$(git -C "$mk" log --format= --raw --no-abbrev --no-renames -m -- "$arch_p")" in
  *" $(git -C "$tz" hash-object -- "$arch_p") "*) bad "AMc: điều kiện của ca: git log -m với log.diffMerges=off không được thấy bản M1" ;;
  *) ok ;;
esac
run_kit "$mk" "$tz"
rc=$?
assert "AMc: bản trên main bị cắt khỏi lịch sử theo đường dẫn: cài lại không --force phải exit 0 → $(cat "$tmp/err")" [ "$rc" -eq 0 ]
assert "AMc: $arch_p phải là bản mới của kit" cmp -s "$mk/$arch_p" "$tz/$arch_p"
git -C "$mk" config --unset log.diffMerges

# AN. Clone trên Windows (Git for Windows mặc định core.autocrlf=true): agent và skill của kit là CRLF.
#    Claude Code đọc được, nên validate-kit phải xanh, và vẫn bắt được lỗi frontmatter trong file CRLF.
crc="$tmp/crlf checkout"
new_repo "$crc"
install "$crc"
for f in "$crc"/.claude/agents/*.md "$crc"/.claude/skills/*/SKILL.md; do
  to_crlf < "$f" > "$tmp/crlf.md" && cat "$tmp/crlf.md" > "$f"
done
out="$(cd "$crc" && ./scripts/validate-kit.sh 2>&1)"
assert "AN: validate-kit phải xanh khi agent và skill của kit là CRLF → $out" [ $? -eq 0 ]
# to_crlf sau awk: gawk của Git for Windows bỏ \r khi đọc, file sẽ thành LF.
awk '{ sub(/^name: verifier/, "name: khac-ten"); print }' "$crc/.claude/agents/verifier.md" | to_crlf > "$tmp/crlf.md"
cat "$tmp/crlf.md" > "$crc/.claude/agents/verifier.md"
out="$(cd "$crc" && ./scripts/validate-kit.sh 2>&1)"
assert "AN: validate-kit phải đỏ khi agent CRLF sai name → $out" [ $? -ne 0 ]
case "$out" in
  *"verifier.md: name phải là 'verifier'"*) ok ;;
  *) bad "AN: phải báo name sai của agent CRLF, không báo lỗi khác → $out" ;;
esac
assert "AN: chỉ báo đúng một lỗi → $out" [ "$(grep -c '^✘ \.claude' <<<"$out")" = 1 ]

# AO. Khối "Bước tiếp theo": có thay đổi thì chỉ cách xem (git diff HEAD) trước khi commit; cài lại mà không có gì
#     đổi so với HEAD thì không bảo commit (4.5).
ao="$tmp/next steps"
new_repo "$ao"
run_install "$ao"
assert "AO: cài mới phải nhắc git diff HEAD → $(cat "$tmp/out")" grep -qF 'git diff HEAD' "$tmp/out"
git -C "$ao" add -A
git -C "$ao" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit
run_install "$ao"
assert "AO: cài lại không đổi gì phải exit 0" [ $? -eq 0 ]
assert "AO: không có gì đổi thì không được bảo git add -A && git commit → $(cat "$tmp/out")" \
  sh -c '! grep -qF "git add -A" "$1"' _ "$tmp/out"
assert "AO: không có gì đổi thì phải nói rõ → $(cat "$tmp/out")" grep -qF 'không có gì đổi' "$tmp/out"

# AP. Script đã theo dõi mà kit đổi nội dung: chỉ đặt bit chạy trong index, không stage nội dung, để git diff vẫn hiện
#     thay đổi của kit (4.5). Script mới (chưa theo dõi) vẫn được stage với bit chạy.
ap="$tmp/chmod only"
new_repo "$ap"
install "$ap"
echo "# bản kit cũ" >> "$ap/scripts/check.sh"
git -C "$ap" add -A
git -C "$ap" update-index --chmod=-x scripts/check.sh # bản cũ commit thiếu bit chạy (commit từ Windows)
git -C "$ap" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit
rm -f "$ap/scripts/validate-kit.sh"
git -C "$ap" rm -q --cached scripts/validate-kit.sh
git -C "$ap" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "bỏ validate-kit"
run_install "$ap" --force
assert "AP: cài lại --force phải exit 0 → $(cat "$tmp/err")" [ $? -eq 0 ]
nl=$'\n'
unstaged="$(git -C "$ap" diff --name-only)"
case "$nl$unstaged$nl" in
  *"${nl}scripts/check.sh$nl"*) ok ;;
  *) bad "AP: nội dung kit đổi phải còn trong git diff (chưa stage) → $unstaged" ;;
esac
for f in scripts/check.sh scripts/validate-kit.sh; do
  mode="$(git -C "$ap" ls-files -s "$f")"
  case "$mode" in
    100755*) ok ;;
    *) bad "AP: $f phải có bit chạy trong index → $mode" ;;
  esac
done

# AQ. Dòng sửa tay trong manifest không phải đường file trong repo (../x, /tuyệt đối, -rf, tên thư mục): không báo
#     "kit đã bỏ" (4.5).
aq="$tmp/manifest junk"
new_repo "$aq"
install "$aq"
echo x > "$tmp/x"
echo x > "$aq/-rf"
{
  echo "kit-commit: unknown"
  echo "kit-files:"
  printf '%s\n' ../x "$tmp/x" -rf scripts .claude/agents ./scripts/check.sh scripts//check.sh scripts/./check.sh
} > "$aq/$man"
run_install "$aq"
assert "AQ: cài lại phải exit 0" [ $? -eq 0 ]
assert "AQ: dòng không phải file kit trong repo thì không được báo kit đã bỏ → $(cat "$tmp/err")" no_dropped_warning

# AR. CLAUDE.md riêng có /team-lead <task> và bảng Rule ↔ Thứ thực thi (gardener hay /correct tạo) nhưng không có câu mô
#     tả dự án của kit: không phải bản chép CLAUDE.md của kit cũ, không cảnh báo (4.5).
ar="$tmp/own rules table"
new_repo "$ar"
# shellcheck disable=SC2016  # dấu ` là chữ markdown
printf '%s\n' '# Dự án X' 'Task lớn dùng `/team-lead <task>`.' '' '## Rule ↔ Thứ thực thi' '| Rule | Thực thi bởi |' > "$ar/CLAUDE.md"
run_install "$ar"
assert "AR: install phải exit 0" [ $? -eq 0 ]
assert "AR: CLAUDE.md riêng có bảng Rule ↔ Thứ thực thi thì không được cảnh báo → $(cat "$tmp/err")" no_claude_warning

# AS. kit-commit trong manifest không phải tổ tiên của HEAD của kit (kit đang ở bản cũ hơn bản đã cài): cảnh báo, vì
#     file trùng bản mới hơn sẽ bị đưa về bản cũ (4.5).
ask="$tmp/kit rollback"
new_repo "$ask"
kit_copy "$ask"
git -C "$ask" -c core.autocrlf=false add -A
git -C "$ask" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit1
ask1="$(git -C "$ask" rev-parse HEAD)"
echo "ghi chú" > "$ask/NOTES.md"
git -C "$ask" add NOTES.md
git -C "$ask" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit2
ast="$tmp/rollback target"
new_repo "$ast"
"$ask/scripts/install-kit.sh" "$ast" > "$tmp/out" 2> "$tmp/err"
assert "AS: cài từ kit2 phải exit 0 → $(cat "$tmp/err")" [ $? -eq 0 ]
assert "AS: kit mới hơn bản đã cài thì không được cảnh báo bản cũ → $(cat "$tmp/err")" \
  sh -c '! grep -q "cũ hơn" "$1"' _ "$tmp/err"
git -C "$ask" checkout -q "$ask1"
"$ask/scripts/install-kit.sh" "$ast" > "$tmp/out" 2> "$tmp/err"
assert "AS: cài từ kit1 phải exit 0 → $(cat "$tmp/err")" [ $? -eq 0 ]
assert "AS: kit cũ hơn bản đã cài phải cảnh báo ⚠ → $(cat "$tmp/err")" grep -q '^⚠.*cũ hơn' "$tmp/err"

# AT. Bản chép CLAUDE.md của kit cũ mà người dùng đã điền TODO (thay câu mô tả dự án của kit): vẫn là quy ước đội
#     của kit cũ, phải cảnh báo (reviewer PR #50).
at="$tmp/old claude filled"
new_repo "$at"
install "$at"
awk '/^Bộ khởi động đội AI agent/ { print "Ứng dụng web bán hàng (Next.js)."; next } /TODO khi cài/ { next } { print }' \
  "$kit/CLAUDE.md" > "$at/CLAUDE.md"
run_install "$at"
assert "AT: install phải exit 0" [ $? -eq 0 ]
assert "AT: bản chép kit cũ đã điền mô tả dự án vẫn phải cảnh báo ⚠ → $(cat "$tmp/err")" claude_warned

# AU. Kit clone nông (git clone --depth 1, rồi fetch --depth 1 + reset): commit đã cài còn trong kho nhưng ngoài lịch
#     sử nông, merge-base không kết luận được. Không được báo "kit cũ hơn" khi kit thật ra mới hơn (reviewer PR #50).
au_up="$tmp/upstream kit"
new_repo "$au_up"
kit_copy "$au_up"
git -C "$au_up" -c core.autocrlf=false add -A
git -C "$au_up" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit1
au_k="$tmp/shallow kit"
git clone -q --depth 1 "file://$au_up" "$au_k"
au_t="$tmp/shallow target"
new_repo "$au_t"
"$au_k/scripts/install-kit.sh" "$au_t" >/dev/null 2>&1
echo "ghi chú" > "$au_up/NOTES.md"
git -C "$au_up" add NOTES.md
git -C "$au_up" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m kit2
git -C "$au_k" fetch -q --depth 1 origin
git -C "$au_k" reset -q --hard FETCH_HEAD
"$au_k/scripts/install-kit.sh" "$au_t" > "$tmp/out" 2> "$tmp/err"
assert "AU: cài lại từ kit nông phải exit 0 → $(cat "$tmp/err")" [ $? -eq 0 ]
assert "AU: kit nông mới hơn thì không được báo kit cũ hơn → $(cat "$tmp/err")" sh -c '! grep -q "cũ hơn" "$1"' _ "$tmp/err"

if [ "$fails" -gt 0 ]; then
  printf '✘ install: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ install: %s test xanh\n' "$pass"
