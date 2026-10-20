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
install "$b"
assert "B: install phải exit 0" [ $? -eq 0 ]
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
repo_only="scripts/install-kit.sh scripts/test-install.sh scripts/test-plugin.sh plugin/run-hook.sh"
o="$tmp/own scripts"
new_repo "$o"
mkdir -p "$o/scripts" "$o/plugin"
for f in $repo_only; do
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

if [ "$fails" -gt 0 ]; then
  printf '✘ install: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ install: %s test xanh\n' "$pass"
