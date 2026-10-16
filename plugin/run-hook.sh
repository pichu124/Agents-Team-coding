#!/usr/bin/env bash
# Plugin (cài một lần cho mọi dự án) gọi hook của kit qua đây: run-hook.sh <tên hook>.
# Dự án đã cài kit và đăng ký đúng hook đó trong .claude/settings*.json thì nhường cho bản của
# dự án: chạy cả hai thì guard hỏi hai lần và Stop gate chạy check hai lần.
set -uo pipefail
name="${1:-}"
here="$(dirname "$0")"
hook="$here/../.claude/hooks/$name.sh"
if [ -z "$name" ] || [ ! -f "$hook" ]; then
  echo "agent-team: không có hook '$name' trong plugin" >&2
  exit 1
fi
proj="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$proj" ] && [ -f "$proj/.claude/hooks/$name.sh" ]; then
  for s in "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
    if grep -qsF ".claude/hooks/$name.sh" "$s"; then
      cat >/dev/null
      exit 0
    fi
  done
fi
exec bash "$hook"
