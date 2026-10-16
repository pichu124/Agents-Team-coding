#!/usr/bin/env bash
# Plugin (cài một lần cho mọi dự án) gọi hook của kit qua đây: run-hook.sh <tên hook>.
# Guard KHÔNG BAO GIỜ nhường: settings của dự án sai schema thì Claude Code bỏ cả file và hook của
# dự án không chạy, plugin không biết được. Hai hook cùng trả "ask" thì Claude Code gộp thành một câu hỏi.
# Stop gate và format thì nhường cho bản của dự án đã cài kit (chạy hai lần song song = check hai lần
# trên cùng repo), khi đọc được đăng ký đó: đúng sự kiện, matcher khớp tool. Không có Python thì dựa
# vào tên hook có trong settings.
set -uo pipefail
name="${1:-}"
here="$(dirname "$0")"
hook="$here/../.claude/hooks/$name.sh"
if [ -z "$name" ] || [ ! -f "$hook" ]; then
  echo "agent-team: không có hook '$name' trong plugin" >&2
  exit 1
fi
[ "$name" = guard-irreversible ] && exec bash "$hook"

# shellcheck source=SCRIPTDIR/../.claude/hooks/lib.sh
. "$here/../.claude/hooks/lib.sh"
input="$(cat)"

registered() {
  local py s
  if py="$(hook_python)"; then
    printf '%s' "$input" | "$py" -c '
import json, re, sys
proj, name = sys.argv[1], sys.argv[2]
try:
    ev = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except ValueError:
    sys.exit(1)
event, tool = ev.get("hook_event_name") or "", ev.get("tool_name") or ""
own = re.compile(r"(^|[/\"\x27\s])\.claude/hooks/" + re.escape(name) + r"\.sh([\"\x27\s]|$)")

def matches(m, t):
    if m in ("", "*"):
        return True
    try:
        return re.fullmatch(m, t) is not None
    except re.error:
        return m == t

for f in ("settings.json", "settings.local.json"):
    try:
        with open(f"{proj}/.claude/{f}", encoding="utf-8-sig") as fh:
            groups = json.load(fh)["hooks"][event]
    except (OSError, ValueError, KeyError, TypeError):
        continue  # file hỏng thì Claude Code bỏ qua cả file: đăng ký trong đó không có hiệu lực
    for g in groups if isinstance(groups, list) else []:
        hooks = g.get("hooks") if isinstance(g, dict) else None
        if not any(isinstance(h, dict) and own.search(str(h.get("command") or "").replace("\\", "/"))
                   for h in hooks or []):
            continue
        if tool:
            if matches(str(g.get("matcher") or ""), tool):
                sys.exit(0)
        elif event and not event.endswith("ToolUse"):
            sys.exit(0)  # sự kiện không theo tool (Stop): đăng ký là đủ
sys.exit(1)
' "$proj" "$name"
    return
  fi
  for s in "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
    grep -qsF ".claude/hooks/$name.sh" "$s" && return 0
  done
  return 1
}

proj="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$proj" ] && [ -f "$proj/.claude/hooks/$name.sh" ] && registered; then
  exit 0
fi
exec bash "$hook" <<<"$input"
