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
  "$py" -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["hooks"].get(sys.argv[2], [])))' "$1" "$2"
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
git -C "$b" add -A
git -C "$b" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m project
install "$b"
assert "B: install phải exit 0" [ $? -eq 0 ]
assert "B: không được sửa CLAUDE.md có sẵn" [ "$(cat "$b/CLAUDE.md")" = "# CLAUDE.md của dự án" ]
assert "B: thiếu .claude/rules/agent-team.md" [ -f "$b/.claude/rules/agent-team.md" ]
assert "B: phải giữ enabledPlugins" json_has "$b/.claude/settings.json" enabledPlugins
assert "B: phải gộp hooks" json_has "$b/.claude/settings.json" hooks
for p in .claude/agents/architect.md .claude/hooks/stop-gate.sh .claude/rules/agent-team.md; do
  if git -C "$b" check-ignore -q "$p"; then bad "B: $p vẫn bị .gitignore bỏ qua"; else ok; fi
done
install "$b"
assert "B: chạy lại install phải exit 0" [ $? -eq 0 ]
for ev in PreToolUse PostToolUse Stop; do
  assert "B: chạy lại không được nhân đôi hook $ev" [ "$(hook_groups "$b/.claude/settings.json" "$ev")" = 1 ]
done
(cd "$b" && ./scripts/validate-kit.sh >/dev/null 2>&1)
assert "B: validate-kit chỉ được kiểm file của kit, bỏ qua skill/tài liệu của dự án" [ $? -eq 0 ]

# C. Trùng tên agent: dừng, không chép gì.
c="$tmp/conflict"
new_repo "$c"
mkdir -p "$c/.claude/agents"
echo "agent riêng của dự án" > "$c/.claude/agents/reviewer.md"
install "$c"
assert "C: trùng file phải exit khác 0" [ $? -ne 0 ]
assert "C: không được chép một phần" [ ! -e "$c/.claude/agents/architect.md" ]
assert "C: không được ghi đè file của dự án" [ "$(cat "$c/.claude/agents/reviewer.md")" = "agent riêng của dự án" ]

if [ "$fails" -gt 0 ]; then
  printf '✘ install: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ install: %s test xanh\n' "$pass"
