#!/usr/bin/env bash
# Kiểm tra bộ agent team còn hợp lệ: frontmatter của agents và skills, link tương đối trong
# markdown, settings.json, các hook được tham chiếu, và cú pháp shell.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

errors=0
err() {
  printf '✘ %s\n' "$*" >&2
  errors=$((errors + 1))
}

has_frontmatter() {
  [ "$(head -n 1 "$1")" = "---" ] && awk 'NR > 1 && $0 == "---" { found = 1; exit } END { exit !found }' "$1"
}

fm_value() {
  awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$1" \
    | sed -n "s/^$2:[[:space:]]*//p" | head -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

in_list() {
  local value="$1" item
  shift
  for item in "$@"; do
    [ "$value" = "$item" ] && return 0
  done
  return 1
}

agent_count=0
seen_names=" "
for f in .claude/agents/*.md; do
  [ -e "$f" ] || continue
  agent_count=$((agent_count + 1))
  if ! has_frontmatter "$f"; then
    err "$f: thiếu frontmatter (--- ... ---)"
    continue
  fi
  name="$(fm_value "$f" name)"
  [ -n "$name" ] || err "$f: thiếu 'name'"
  [ -n "$(fm_value "$f" description)" ] || err "$f: thiếu 'description'"
  [ "$name" = "$(basename "$f" .md)" ] || err "$f: name '$name' phải trùng tên file"
  case "$name" in *:*) err "$f: name không được chứa ':'" ;; esac
  case "$seen_names" in *" $name "*) err "$f: trùng name '$name'" ;; esac
  seen_names="$seen_names$name "
  model="$(fm_value "$f" model)"
  if [ -n "$model" ] && ! in_list "$model" sonnet opus haiku fable inherit && [ "${model#claude-}" = "$model" ]; then
    err "$f: model '$model' không hợp lệ (sonnet|opus|haiku|fable|inherit|claude-...)"
  fi
  effort="$(fm_value "$f" effort)"
  if [ -n "$effort" ] && ! in_list "$effort" low medium high xhigh max; then
    err "$f: effort '$effort' không hợp lệ (low|medium|high|xhigh|max)"
  fi
  memory="$(fm_value "$f" memory)"
  if [ -n "$memory" ] && ! in_list "$memory" user project local; then
    err "$f: memory '$memory' không hợp lệ (user|project|local)"
  fi
done

skill_count=0
for d in .claude/skills/*/; do
  [ -d "$d" ] || continue
  skill_count=$((skill_count + 1))
  f="${d}SKILL.md"
  if [ ! -f "$f" ]; then
    err "$d: thiếu SKILL.md"
    continue
  fi
  if ! has_frontmatter "$f"; then
    err "$f: thiếu frontmatter"
    continue
  fi
  name="$(fm_value "$f" name)"
  [ -z "$name" ] || [ "$name" = "$(basename "$d")" ] || err "$f: name '$name' phải trùng tên thư mục"
  desc="$(fm_value "$f" description)"
  [ -n "$desc" ] || err "$f: thiếu 'description'"
  [ "${#desc}" -le 1536 ] || err "$f: description dài hơn 1536 ký tự"
  lines="$(wc -l < "$f")"
  [ "$lines" -le 500 ] || err "$f: $lines dòng (nên dưới 500, tách phần tham khảo ra file riêng)"
done

link_count=0
while IFS= read -r md; do
  base="$(dirname "$md")"
  while IFS= read -r target; do
    target="${target%%#*}"
    target="${target%% *}"
    case "$target" in '' | http://* | https://* | mailto:*) continue ;; esac
    link_count=$((link_count + 1))
    [ -e "$base/$target" ] || err "$md: link gãy → $target"
  done < <(grep -o '\]([^)]*)' "$md" | sed -e 's/^](//' -e 's/)$//')
done < <(git ls-files --cached --others --exclude-standard -- '*.md')

settings=.claude/settings.json
hook_count=0
if [ -f "$settings" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq empty "$settings" 2>/dev/null || err "$settings: JSON không hợp lệ"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$settings" >/dev/null 2>&1 || err "$settings: JSON không hợp lệ"
  elif command -v node >/dev/null 2>&1; then
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$settings" 2>/dev/null \
      || err "$settings: JSON không hợp lệ"
  else
    printf '⚠ không có jq/python3/node để kiểm tra JSON của %s\n' "$settings"
  fi
  while IFS= read -r hook; do
    hook_count=$((hook_count + 1))
    [ -f "$hook" ] || { err "$settings: hook không tồn tại → $hook"; continue; }
    [ -x "$hook" ] || err "$hook: chưa có quyền chạy (chmod +x)"
  done < <(grep -o '\.claude/hooks/[A-Za-z0-9_.-]*' "$settings" | sort -u)
fi

for sh in scripts/*.sh .claude/hooks/*.sh; do
  [ -e "$sh" ] || continue
  bash -n "$sh" 2>/dev/null || err "$sh: lỗi cú pháp bash"
done
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  shellcheck -x -S warning $(ls scripts/*.sh .claude/hooks/*.sh 2>/dev/null) || err "shellcheck báo lỗi"
fi

if [ "$errors" -gt 0 ]; then
  printf '✘ kit: %s lỗi\n' "$errors" >&2
  exit 1
fi
printf '✔ kit hợp lệ: %s agents, %s skills, %s hooks, %s link nội bộ\n' \
  "$agent_count" "$skill_count" "$hook_count" "$link_count"
