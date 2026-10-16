#!/usr/bin/env bash
# Plugin (cài một lần cho mọi dự án) gọi hook của kit qua đây: run-hook.sh <tên hook>.
# Dự án đã cài kit thì nhường cho bản của dự án (chạy cả hai thì Stop gate chạy check hai lần),
# nhưng CHỈ khi lần đăng ký đó có hiệu lực cho đúng lần gọi này: settings đọc được, có hook
# .claude/hooks/<tên>.sh ở đúng sự kiện, matcher khớp tool. Không chắc thì chạy (thà hỏi thừa).
set -uo pipefail
name="${1:-}"
here="$(dirname "$0")"
hook="$here/../.claude/hooks/$name.sh"
if [ -z "$name" ] || [ ! -f "$hook" ]; then
  echo "agent-team: không có hook '$name' trong plugin" >&2
  exit 1
fi
# shellcheck source=SCRIPTDIR/../.claude/hooks/lib.sh
. "$here/../.claude/hooks/lib.sh"
input="$(cat)"

proj="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$proj" ] && [ -f "$proj/.claude/hooks/$name.sh" ] && py="$(hook_python)"; then
  if printf '%s' "$input" | "$py" -c '
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
            d = json.load(fh)
        groups = d["hooks"][event]
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
' "$proj" "$name"; then
    exit 0
  fi
fi
exec bash "$hook" <<<"$input"
