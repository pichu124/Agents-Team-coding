#!/usr/bin/env bash
# Helper của skill verify-kit: dựng sandbox đã cài kit, dựng input lớn cho guard, chạy guard và
# test-hooks dưới tải, rồi dọn. Mọi lệnh con nhận đường dẫn sandbox, vì shell của agent không giữ biến.
#   sandbox.sh launch                                   tạo sandbox, in đường dẫn ở dòng cuối stdout
#   sandbox.sh doctor <sbx>                             kiểm chỉ-đọc: của mình, bản cài khớp kit, validate-kit xanh
#   sandbox.sh big-input <file ra> <dòng đầu> <cwd> [số dòng]   JSON PreToolUse, lệnh không đi qua argv
#   sandbox.sh guard-loop <sbx> <input.json> [số lần]   chạy guard đã cài, mỗi KIT_JSON_TOOL auto|python|sed
#   sandbox.sh load <sbx> <thư mục log> [số vòng] [số bản]   test-hooks.sh song song trong repo đã cài
#   sandbox.sh cleanup <sbx>                            xoá sandbox (chỉ sandbox có dấu của launch)
# guard-loop: IGNORE_SIGPIPE=1 chạy guard trong (trap '' PIPE; ...), con kế thừa việc bỏ qua SIGPIPE;
# VIA_PLUGIN=1 gọi qua plugin/run-hook.sh của repo kit (entry point của bản plugin) thay vì hook đã cài.
set -uo pipefail

kit="$(cd "$(dirname "$0")/../../../.." && pwd)"
mark=.verify-kit-sandbox

die() {
  printf '✘ %s\n' "$*" >&2
  exit 1
}
gitc() { git -C "$1" -c user.email=verify@kit -c user.name=verify-kit -c commit.gpgsign=false -c core.autocrlf=false "${@:2}"; }
new_repo() {
  mkdir -p "$1" && gitc "$1" init -q && gitc "$1" checkout -q -b "$2" && gitc "$1" commit -q --allow-empty -m init
}
# own <sbx>: sandbox do launch của đúng repo kit này tạo. Không thì dừng, không đụng thư mục lạ.
own() {
  [ -n "${1:-}" ] && [ -d "$1" ] || die "không có sandbox: ${1:-<trống>}"
  [ -f "$1/$mark" ] || die "$1 không có dấu $mark: không phải sandbox của verify-kit"
  [ "$(cat "$1/$mark")" = "$kit" ] || die "$1 thuộc repo kit khác: $(cat "$1/$mark")"
}

cmd_launch() {
  local sbx
  sbx="$(mktemp -d "${TMPDIR:-/tmp}/verify-kit.XXXXXX")" || die "không tạo được thư mục tạm"
  printf '%s\n' "$kit" > "$sbx/$mark"
  new_repo "$sbx/app" feat/verify || die "không tạo được repo $sbx/app"
  new_repo "$sbx/on-main" main || die "không tạo được repo $sbx/on-main"
  if ! "$kit/scripts/install-kit.sh" "$sbx/app" > "$sbx/install.log" 2>&1; then
    cat "$sbx/install.log" >&2
    die "install-kit.sh đỏ, sandbox giữ ở $sbx để xem"
  fi
  # Commit bản cài: repo sạch thì check.sh không chạy lại test của kit, Stop gate không thấy thay đổi.
  gitc "$sbx/app" add -A && gitc "$sbx/app" commit -q -m "chore: cài bộ agent team" || die "không commit được bản cài"
  if ! (cd "$sbx/app" && ./scripts/validate-kit.sh) > "$sbx/ready.log" 2>&1; then
    cat "$sbx/ready.log" >&2
    die "validate-kit.sh đỏ trong repo vừa cài"
  fi
  printf '✔ sẵn sàng: kit cài ở %s/app (nhánh feat/verify), repo ở main: %s/on-main\n' "$sbx" "$sbx" >&2
  printf '%s\n' "$sbx"
}

cmd_doctor() {
  own "$1"
  local sbx="$1" f bad=0 b
  printf 'kit: %s @ %s%s\n' "$kit" "$(git -C "$kit" rev-parse --short HEAD)" \
    "$([ -n "$(git -C "$kit" status --porcelain -- .claude/hooks scripts)" ] && echo ' (có thay đổi chưa commit ở hooks/scripts)')"
  for f in .claude/hooks/lib.sh .claude/hooks/guard-irreversible.sh .claude/hooks/stop-gate.sh \
    .claude/hooks/post-edit-format.sh scripts/check.sh scripts/validate-kit.sh scripts/test-hooks.sh scripts/guard-ask-floor; do
    if ! cmp -s "$kit/$f" "$sbx/app/$f"; then
      printf '✘ %s: bản cài khác bản của kit (kit đổi sau launch: cleanup rồi launch lại)\n' "$f"
      bad=1
    fi
  done
  b="$(git -C "$sbx/app" rev-parse --abbrev-ref HEAD)"
  [ "$b" = feat/verify ] || { printf '✘ app ở nhánh %s, cần feat/verify\n' "$b"; bad=1; }
  b="$(git -C "$sbx/on-main" rev-parse --abbrev-ref HEAD)"
  [ "$b" = main ] || { printf '✘ on-main ở nhánh %s, cần main\n' "$b"; bad=1; }
  (cd "$sbx/app" && ./scripts/validate-kit.sh) >/dev/null 2>&1 || { printf '✘ validate-kit.sh đỏ trong app\n'; bad=1; }
  printf 'công cụ: bash %s; jq %s; python3 %s\n' "${BASH_VERSION}" \
    "$(command -v jq >/dev/null 2>&1 && jq --version || echo 'KHÔNG CÓ (auto sẽ dùng python hoặc sed)')" \
    "$(python3 -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || echo 'KHÔNG CÓ (mode python sẽ rơi về sed)')"
  [ "$bad" = 0 ] && printf '✔ doctor: sandbox %s của mình, bản cài khớp kit\n' "$sbx"
  return "$bad"
}

cmd_big_input() {
  local out="${1:-}" first="${2:-}" cwd="${3:-}" n="${4:-20000}" py
  [ -n "$out" ] && [ -n "$first" ] && [ -n "$cwd" ] || die "cách dùng: big-input <file ra> <dòng đầu> <cwd> [số dòng]"
  # Lệnh ghi vào file rồi mới đưa vào JSON: lệnh ~300 KiB đi qua argv thì vượt giới hạn đối số (Windows ~32K).
  { printf '%s\n' "$first"; seq -f 'echo line-%g' "$n"; } > "$out.cmd" || die "không ghi được $out.cmd"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --rawfile c "$out.cmd" --arg d "$cwd" \
      '{hook_event_name: "PreToolUse", session_id: "verify-kit", cwd: $d, tool_name: "Bash", tool_input: {command: $c, description: "verify-kit"}}' > "$out"
  elif py="$(command -v python3 || command -v python)"; then
    "$py" -c 'import json, sys
c = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"hook_event_name": "PreToolUse", "session_id": "verify-kit", "cwd": sys.argv[2], "tool_name": "Bash", "tool_input": {"command": c, "description": "verify-kit"}}))' "$out.cmd" "$cwd" > "$out"
  else
    die "cần jq hoặc Python để dựng JSON"
  fi || die "không dựng được $out"
  rm -f "$out.cmd"
  printf '✔ %s: %s byte, dòng đầu "%s" + %s dòng vô hại, cwd %s\n' "$out" "$(wc -c < "$out" | tr -d ' ')" "$first" "$n" "$cwd"
}

cmd_guard_loop() {
  own "$1"
  local sbx="$1" input="${2:-}" times="${3:-10}" m i n out reason fail=0 err
  [ -f "$input" ] || die "không có input: $input"
  local run=("$sbx/app/.claude/hooks/guard-irreversible.sh")
  [ "${VIA_PLUGIN:-0}" = 1 ] && run=(bash "$kit/plugin/run-hook.sh" guard-irreversible)
  printf 'entry point: %s%s\n' "${run[*]}" "$([ "${IGNORE_SIGPIPE:-0}" = 1 ] && echo " (trap '' PIPE)")"
  err="$sbx/guard.err"
  for m in auto python sed; do
    n=0
    reason=""
    : > "$err"
    for ((i = 0; i < times; i++)); do
      if [ "${IGNORE_SIGPIPE:-0}" = 1 ]; then
        out="$( (trap '' PIPE; KIT_JSON_TOOL="$m" CLAUDE_PROJECT_DIR="$sbx/app" "${run[@]}" < "$input") 2>>"$err")"
      else
        out="$(KIT_JSON_TOOL="$m" CLAUDE_PROJECT_DIR="$sbx/app" "${run[@]}" < "$input" 2>>"$err")"
      fi
      case "$out" in
        *'"permissionDecision":"ask"'*)
          n=$((n + 1))
          reason="${out#*'Hành động không đảo ngược được ('}"
          reason="${reason%%'). Cần người'*}"
          ;;
      esac
    done
    printf '%s: %s/%s "permissionDecision":"ask" (lý do: %s), stderr %s byte\n' "$m" "$n" "$times" "${reason:-không có}" "$(wc -c < "$err" | tr -d ' ')"
    [ -s "$err" ] && head -n 2 "$err" | cut -c 1-240 | sed 's/^/  stderr: /'
    [ "$n" = "$times" ] && [ ! -s "$err" ] || fail=1
  done
  rm -f "$err"
  return "$fail"
}

cmd_load() {
  own "$1"
  local sbx="$1" logs="${2:-}" rounds="${3:-4}" copies="${4:-6}" r k rc red pids
  [ -n "$logs" ] || die "cách dùng: load <sbx> <thư mục log> [số vòng] [số bản]"
  mkdir -p "$logs" || die "không tạo được $logs"
  for ((r = 1; r <= rounds; r++)); do
    pids=()
    for ((k = 1; k <= copies; k++)); do
      (cd "$sbx/app" && ./scripts/test-hooks.sh) > "$logs/r$r-$k.log" 2>&1 &
      pids+=("$!")
    done
    for ((k = 1; k <= copies; k++)); do
      wait "${pids[$((k - 1))]}"
      rc=$?
      printf 'vòng %s bản %s: exit %s, %s\n' "$r" "$k" "$rc" "$(tail -n 1 "$logs/r$r-$k.log")"
    done
  done | tee "$logs/summary.txt"
  red="$(awk '/: exit [1-9]/ { n++ } END { print n + 0 }' "$logs/summary.txt")"
  printf 'TỔNG: %s/%s lần chạy đỏ (%s vòng × %s bản song song, %s CPU)\n' "$red" "$((rounds * copies))" "$rounds" "$copies" \
    "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')" | tee -a "$logs/summary.txt"
  [ "$red" = 0 ]
}

cmd_cleanup() {
  own "$1"
  rm -rf -- "$1" && printf '✔ đã xoá sandbox %s\n' "$1"
}

sub="${1:-}"
shift || true
case "$sub" in
  launch) cmd_launch ;;
  doctor) cmd_doctor "$@" ;;
  big-input) cmd_big_input "$@" ;;
  guard-loop) cmd_guard_loop "$@" ;;
  load) cmd_load "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  *) sed -n '2,11p' "$0" >&2; exit 2 ;;
esac
