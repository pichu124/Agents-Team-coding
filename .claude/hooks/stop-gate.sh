#!/usr/bin/env bash
# Stop hook: agent chưa được kết thúc lượt khi ./scripts/check.sh còn đỏ.
# Chỉ chạy khi có thay đổi (chưa commit, hoặc commit chưa push) ở file không phải tài liệu.
#   AGENT_STOP_GATE=off       tắt gate cho phiên này
#   AGENT_STOP_GATE_MAX=<n>   số lần chặn liên tiếp tối đa trước khi nhả cho người xem (mặc định 3)
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

[ "${AGENT_STOP_GATE:-on}" = "off" ] && exit 0
input="$(cat)"

dir="$(json_get "$input" cwd)"
[ -n "$dir" ] && [ -d "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$dir" 2>/dev/null || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0
[ -x scripts/check.sh ] || exit 0

changed="$(
  {
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
    if git rev-parse --verify -q '@{upstream}' >/dev/null; then
      git diff --name-only '@{upstream}...HEAD'
    fi
  } 2>/dev/null | grep -Ev '\.(md|mdx|txt|rst)$' | sort -u
)"
[ -n "$changed" ] || exit 0

session="$(json_get "$input" session_id)"
state_dir="${TMPDIR:-/tmp}/agent-stop-gate"
mkdir -p "$state_dir" 2>/dev/null
state="$state_dir/${session:-unknown}.count"

out="$(./scripts/check.sh 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then
  rm -f "$state"
  exit 0
fi

count=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
max="${AGENT_STOP_GATE_MAX:-3}"
if [ "$count" -gt "$max" ]; then
  rm -f "$state"
  printf '{"systemMessage":"Stop gate: ./scripts/check.sh vẫn đỏ sau %s lần chặn liên tiếp. Agent được dừng để bạn xem xét."}\n' "$max"
  exit 0
fi
echo "$count" > "$state"

reason="$(
  echo "./scripts/check.sh đang đỏ (exit $status), chưa được kết thúc lượt (lần chặn $count/$max)."
  echo "Sửa nguyên nhân gốc rồi chạy lại ./scripts/check.sh. Không tắt check, không skip test, không nuốt lỗi."
  echo "Nếu lỗi nằm ngoài phạm vi task (đã đỏ sẵn trên nhánh gốc, thiếu môi trường) hoặc mâu thuẫn với yêu cầu của người dùng, nói rõ điều đó trong câu trả lời cuối."
  echo "--- 40 dòng cuối của output ---"
  printf '%s\n' "$out" | tail -n 40
)"

# Ưu tiên JSON {"decision":"block"} (hiển thị gọn hơn); không có jq/python3 thì dùng exit 2 + stderr.
if command -v jq >/dev/null 2>&1; then
  jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
  exit 0
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json, sys; print(json.dumps({"decision": "block", "reason": sys.argv[1]}, ensure_ascii=False))' "$reason"
  exit 0
fi
printf '%s\n' "$reason" >&2
exit 2
