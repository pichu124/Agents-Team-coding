#!/usr/bin/env bash
# Chẩn đoán TẠM (xoá trước khi merge): thời gian từng phần của đường đọc JSON không có jq/Python
# (KIT_JSON_TOOL=sed) và của guard trên lệnh dài có dấu nối dòng, mỗi phép đo tối đa 15 giây.
set -u
cd "$(dirname "$0")/.." || exit 1
T="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
TIMEFORMAT='%R'
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }
secs() { { time "$@" >/dev/null 2>&1; } 2>&1 | tail -n 1; }

cat > "$T/json_awk.sh" <<'EOF'
json_awk() {
  printf '%s' "$1" | awk -v k="\"$2\"" '
    { s = s $0 " " }
    END {
      str = ""; raw = ""; hs = 0
      while ((i = index(s, k)) > 0) {
        s = substr(s, i + length(k))
        if (match(s, /^[ \t\r]*:[ \t\r]*"([^"\\]|\\.)*"/)) {
          v = substr(s, 1, RLENGTH - 1); sub(/^[ \t\r]*:[ \t\r]*"/, "", v); str = v; hs = 1
        } else if (match(s, /^[ \t\r]*:[ \t\r]*[^", \t\r}]+/)) {
          v = substr(s, 1, RLENGTH); sub(/^[ \t\r]*:[ \t\r]*/, "", v); raw = v
        }
      }
      if (!hs) { if (raw != "") print raw; exit }
      gsub(/\\\\/, "\001", str); gsub(/\\n/, "\n", str); gsub(/\\t/, "\t", str)
      gsub(/\\r/, "", str); gsub(/\\"/, "\"", str); gsub(/\\\//, "/", str)
      n = split(str, p, "\001"); out = p[1]
      for (j = 2; j <= n; j++) out = out "\\" p[j]
      print out
    }'
}
EOF
export T

awk --version 2>&1 | head -n 1 || awk -W version 2>&1 | head -n 1
# Bash của Git for Windows có bỏ \r trong $(...) không?
x="$(printf 'a\r\nb\r\n')"
echo "\$(...) của 'a\\r\\nb\\r\\n' dài ${#x} byte (bash thường: 5, bỏ \\r: 3)"
# awk có bỏ \r khi đọc, có thêm \r khi ghi không? (ca M của test-install đỏ trên Windows)
printf 'a\r\nb\r\n' > "$T/crlf.txt"
echo "awk đọc file CRLF, length(\$0): $(awk '{ printf "%d ", length($0) }' "$T/crlf.txt")(giữ \\r: 2 2)"
echo "awk đọc pipe CRLF, length(\$0): $(printf 'a\r\nb\r\n' | awk '{ printf "%d ", length($0) }')(giữ \\r: 2 2)"
echo "awk print \$0 của file CRLF: $(awk '{ print }' "$T/crlf.txt" | od -c | head -n 1)"
echo "awk printf \\r\\n: $(awk 'BEGIN { printf "x\r\n" }' | od -c | head -n 1)"
echo "cat file CRLF qua pipe: $(cat "$T/crlf.txt" | od -c | head -n 1)"
for n in 1000 4000 20000; do
  f="$T/d-$n.json"
  {
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"npm run deploy' "$PWD"
    printf '\\necho line-%s' $(seq "$n")
    printf '"}}\n'
  } > "$f"
  re_str='"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"'
  printf '%s' "$(cat "$f")" | sed -nE "s/.*\"command\":\"([^\"]*)\".*/\\1/p" > "$T/raw-$n.txt"
  echo "== n=$n ($(wc -c < "$f") byte)"
  echo "  1 sed s/.*RE.*/\\1/: $(secs cap 15 sed -nE "s/.*${re_str}.*/\\1/p" "$f")s"
  # shellcheck disable=SC2016
  echo "  2 bash \${x//\\\\n/xuống dòng}: $(secs cap 15 bash -c 'x=$(cat "$1"); bs="\\"; x="${x//"${bs}n"/$'"'"'\n'"'"'}"' _ "$T/raw-$n.txt")s"
  # shellcheck disable=SC2016
  echo "  3 awk: $(secs cap 15 bash -c '. "$T/json_awk.sh"; json_awk "$(cat "$1")" command' _ "$f")s"
  # shellcheck disable=SC2016
  echo "  3 awk đúng: $(bash -c '. "$T/json_awk.sh"; json_awk "$(cat "$1")" command' _ "$f" | wc -l | tr -d ' ') dòng"
  # Lệnh dài có \ nối dòng ở mọi dòng: guard thay chuỗi trên cả lệnh.
  g="$T/c-$n.json"
  {
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"npm run deploy' "$PWD"
    printf ' \\\\\\necho line-%s' $(seq "$n")
    printf '"}}\n'
  } > "$g"
  for mode in auto python; do
    s=$(date +%s)
    out="$(KIT_JSON_TOOL=$mode cap 15 .claude/hooks/guard-irreversible.sh < "$g")"
    case "$out" in *'"ask"'*) a=hỏi ;; *) a=KHÔNG-hỏi ;; esac
    echo "  4 guard nối dòng [$mode]: $(($(date +%s) - s))s $a"
  done
done
