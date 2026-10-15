#!/usr/bin/env bash
# Hàm dùng chung cho các hook. File này được source, không chạy trực tiếp.

# hook_python: in tên Python thật đầu tiên chạy được. Bỏ qua bản giả "python3" của
# Microsoft Store trên Windows (có trong PATH nhưng không chạy được).
# KIT_NO_JSON_TOOLS=1 giả lập máy không có jq/Python (dùng trong test của kit).
have_jq() {
  [ "${KIT_NO_JSON_TOOLS:-0}" != 1 ] && command -v jq >/dev/null 2>&1
}

hook_python() {
  local c
  [ "${KIT_NO_JSON_TOOLS:-0}" = 1 ] && return 1
  for c in python3 python py; do
    if "$c" -c 'import json' >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# json_get <json> <khoá.lồng.nhau>: in giá trị chuỗi, số hoặc bool; in rỗng nếu không có.
# Ưu tiên jq, sau đó Python. Nếu không có cả hai, dùng sed thô (chỉ đúng với giá trị đơn giản).
json_get() {
  local json="$1" path="$2" py
  if have_jq; then
    printf '%s' "$json" | jq -r --arg p "$path" 'getpath($p | split(".")) // empty | tostring' 2>/dev/null
    return 0
  fi
  if py="$(hook_python)"; then
    printf '%s' "$json" | "$py" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
if d is not None:
    print(str(d).lower() if isinstance(d, bool) else d)
' "$path" 2>/dev/null
    return 0
  fi
  local key="${path##*.}"
  printf '%s' "$json" | tr '\n' ' ' \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\).*/\1/p" | head -n 1
}

# find_up <thư mục bắt đầu> <đường dẫn tương đối>: tìm ngược lên tới gốc dự án.
find_up() {
  local d="$1" stop="${CLAUDE_PROJECT_DIR:-/}"
  while [ -n "$d" ]; do
    if [ -e "$d/$2" ]; then
      printf '%s\n' "$d/$2"
      return 0
    fi
    if [ "$d" = "/" ] || [ "$d" = "$stop" ]; then
      return 1
    fi
    d="$(dirname "$d")"
  done
  return 1
}
