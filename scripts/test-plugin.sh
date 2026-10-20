#!/usr/bin/env bash
# Test của bản plugin (cài một lần cho mọi dự án): plugin/run-hook.sh nhường cho hook của dự án khi dự án đã cài kit, chạy hook của plugin khi chưa.
# Manifest khớp với file của kit thì scripts/validate-kit.sh kiểm.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
root="$PWD"
# shellcheck source=SCRIPTDIR/../.claude/hooks/lib.sh
. .claude/hooks/lib.sh
py="$(KIT_JSON_TOOL=python hook_python)" || {
  printf '⚠ bỏ qua test plugin: cần Python 3\n'
  exit 0
}

fails=0
pass=0
ok() { pass=$((pass + 1)); }
bad() {
  printf '✘ %s\n' "$*" >&2
  fails=$((fails + 1))
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp" PYTHONDONTWRITEBYTECODE=1

gitc() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }
new_repo() {
  mkdir -p "$1"
  gitc "$1" init -q
  gitc "$1" checkout -q -b feat/x
  gitc "$1" commit -q --allow-empty -m init
}
# Bản plugin đã cài nằm ở thư mục có dấu cách (Windows: C:\Users\Ten Nguoi\.claude\plugins\...).
plug="$tmp/plugin cache/agent-team"
mkdir -p "$plug/.claude"
cp -R .claude/hooks "$plug/.claude/hooks"
cp -R plugin "$plug/plugin"
# Bản "gián điệp": hook chỉ ghi lại là đã chạy, để phân biệt "nhường" với "chạy mà không in gì".
spy="$tmp/spy plugin"
mkdir -p "$spy/.claude/hooks"
cp -R plugin "$spy/plugin"
cp .claude/hooks/lib.sh "$spy/.claude/hooks/lib.sh"
for h in guard-irreversible stop-gate post-edit-format; do
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "$0" >> "%s/ran"\n' "$tmp" > "$spy/.claude/hooks/$h.sh"
done

# run <tên hook> <thư mục dự án> <input JSON>: in stdout, exit code ở $rc. PLUG chọn bản plugin.
run() {
  out="$(printf '%s' "$3" | CLAUDE_PROJECT_DIR="$2" bash "${PLUG:-$plug}/plugin/run-hook.sh" "$1" 2>"$tmp/err")"
  rc=$?
}
# event_input <tên hook> [tool]: input giống Claude Code gửi cho hook đó.
event_input() {
  case "$1" in
    guard-irreversible) printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"ls"}}' "${2:-Bash}" ;;
    post-edit-format) printf '{"hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":"/khong/co"}}' "${2:-Edit}" ;;
    stop-gate) printf '{"hook_event_name":"Stop","session_id":"spy"}' ;;
  esac
}
# spied <tên hook> <thư mục dự án> [tool]: chạy bản gián điệp, $ran = 1 nếu hook của plugin đã chạy.
spied() {
  rm -f "$tmp/ran"
  PLUG="$spy" run "$1" "$2" "$(event_input "$1" "${3:-}")"
  if [ -s "$tmp/ran" ]; then ran=1; else ran=0; fi
}
expect_defer() {
  spied "$1" "$2" "${4:-}"
  if [ "$rc" -eq 0 ] && [ "$ran" = 0 ]; then ok; else bad "$3 (exit $rc, hook của plugin đã chạy: $ran)"; fi
}
expect_run() {
  spied "$1" "$2" "${4:-}"
  if [ "$rc" -eq 0 ] && [ "$ran" = 1 ]; then ok; else bad "$3 (exit $rc, hook của plugin đã chạy: $ran)"; fi
}
push_input() {
  "$py" -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "cwd": sys.argv[1], "tool_name": sys.argv[2], "tool_input": {"command": "git push --force origin feat/x"}}))' "$1" "${TOOL:-Bash}"
}
expect_ask() {
  run guard-irreversible "$1" "$(push_input "$1")"
  if [ "$rc" -eq 0 ] && text_grep "$out" -q '"ask"'; then ok; else bad "$2 (exit $rc, out=$out, err=$(cat "$tmp/err"))"; fi
}
expect_silent() {
  run guard-irreversible "$1" "$(push_input "$1")"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok; else bad "$2 (exit $rc, out=$out)"; fi
}

# 1. Dự án chưa cài kit: guard của plugin hỏi.
plain="$tmp/plain"
new_repo "$plain"
expect_ask "$plain" "dự án chưa cài kit: guard của plugin phải hỏi force-push"
expect_ask "" "không có CLAUDE_PROJECT_DIR: guard của plugin vẫn phải chạy"

# 2. Dự án đã cài kit. Guard KHÔNG bao giờ nhường: settings đúng cú pháp mà sai schema thì Claude Code bỏ
#    cả file, hook của dự án không chạy mà plugin không biết. Hai hook cùng "ask" được gộp thành một câu hỏi.
#    Stop gate và format thì nhường (chạy hai lần song song tốn kém, nhường sai thì hậu quả nhẹ).
kit="$tmp/kit proj"
new_repo "$kit"
mkdir -p "$kit/.claude"
cp -R .claude/hooks "$kit/.claude/hooks"
cp .claude/settings.json "$kit/.claude/settings.json"
expect_ask "$kit" "dự án đã cài kit: guard của plugin vẫn hỏi (không nhường)"
expect_run guard-irreversible "$kit" "dự án đã cài kit: guard của plugin vẫn chạy"
for h in stop-gate post-edit-format; do
  expect_defer "$h" "$kit" "dự án đã đăng ký $h: plugin không được chạy bản của mình"
done
expect_run guard-irreversible "$plain" "dự án chưa cài kit: plugin phải chạy guard của mình"
loc="$tmp/local"
new_repo "$loc"
mkdir -p "$loc/.claude"
cp -R .claude/hooks "$loc/.claude/hooks"
cp .claude/settings.json "$loc/.claude/settings.local.json"
expect_defer stop-gate "$loc" "stop-gate đăng ký trong settings.local.json: plugin phải nhường"
expect_defer post-edit-format "$kit" "dự án đăng ký format cho Write: plugin nhường" Write
expect_run post-edit-format "$kit" "tool không khớp matcher format của dự án: plugin phải tự chạy" NotebookEdit

# Đăng ký mà không có hiệu lực thì không nhường: không ai canh còn tệ hơn hỏi hai lần.
broken="$tmp/broken"
new_repo "$broken"
mkdir -p "$broken/.claude"
cp -R .claude/hooks "$broken/.claude/hooks"
sed 's/"permissions": {/"permissions": {,/' .claude/settings.json > "$broken/.claude/settings.json"
expect_run stop-gate "$broken" "settings.json của dự án hỏng (Claude Code bỏ qua cả file): plugin phải chạy Stop gate"
expect_ask "$broken" "settings.json của dự án hỏng: guard của plugin phải hỏi force-push"
schema="$tmp/schema"
new_repo "$schema"
mkdir -p "$schema/.claude"
cp -R .claude/hooks "$schema/.claude/hooks"
"$py" - "$schema/.claude/settings.json" <<'PYEOF'
import json, sys
d = json.load(open(".claude/settings.json", encoding="utf-8"))
d["hooks"]["PostToolUse"].append({"matcher": "Edit", "hooks": [{"type": "cmd", "command": "npm run lint"}]})
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PYEOF
expect_ask "$schema" "settings đúng cú pháp mà sai schema (Claude Code bỏ cả file): guard của plugin phải hỏi force-push"
old="$tmp/old matcher"
new_repo "$old"
mkdir -p "$old/.claude"
cp -R .claude/hooks "$old/.claude/hooks"
sed 's/"Bash|PowerShell"/"Bash"/' .claude/settings.json > "$old/.claude/settings.json"
expect_run guard-irreversible "$old" "matcher cũ chỉ có Bash: plugin phải canh lệnh PowerShell" PowerShell
TOOL=PowerShell expect_ask "$old" "matcher cũ chỉ có Bash: guard của plugin phải hỏi force-push qua PowerShell"
# Không có Python: Stop gate vẫn nhường theo cách cũ (tìm tên hook trong settings), để check không chạy
# hai lần song song trên cùng repo; guard thì vẫn chạy.
nojson() {
  rm -f "$tmp/ran"
  out="$(event_input "$1" | KIT_JSON_TOOL=sed CLAUDE_PROJECT_DIR="$2" bash "$spy/plugin/run-hook.sh" "$1" 2>"$tmp/err")"
  rc=$?
  if [ -s "$tmp/ran" ]; then ran=1; else ran=0; fi
}
nojson stop-gate "$kit"
if [ "$rc" -eq 0 ] && [ "$ran" = 0 ]; then ok; else bad "không có Python: plugin vẫn phải nhường Stop gate cho dự án đã đăng ký (ran=$ran)"; fi
nojson stop-gate "$plain"
if [ "$rc" -eq 0 ] && [ "$ran" = 1 ]; then ok; else bad "không có Python, dự án chưa cài kit: plugin phải chạy Stop gate (ran=$ran)"; fi
nojson guard-irreversible "$kit"
if [ "$rc" -eq 0 ] && [ "$ran" = 1 ]; then ok; else bad "không có Python: guard của plugin vẫn phải chạy (ran=$ran)"; fi

# 3. Có file hook mà không đăng ký (chép thiếu settings): plugin vẫn phải chạy, không ai canh thì nguy.
half="$tmp/half"
new_repo "$half"
mkdir -p "$half/.claude"
cp -R .claude/hooks "$half/.claude/hooks"
printf '{"permissions": {}}\n' > "$half/.claude/settings.json"
expect_ask "$half" "hook có file nhưng chưa đăng ký: plugin vẫn phải hỏi"
expect_run guard-irreversible "$half" "hook có file nhưng chưa đăng ký: plugin phải chạy guard của mình"
# Đăng ký hook khác tên (stop-gate) không làm plugin nhường guard.
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": ".claude/hooks/stop-gate.sh"}]}]}}\n' > "$half/.claude/settings.json"
expect_ask "$half" "dự án chỉ đăng ký stop-gate: guard của plugin vẫn phải hỏi"
expect_defer stop-gate "$half" "dự án đăng ký stop-gate: plugin nhường stop-gate"
expect_run post-edit-format "$half" "dự án chỉ đăng ký stop-gate: plugin vẫn chạy format"

# Settings đăng ký Stop gate mà thiếu file hook (chép thiếu): hook của dự án lỗi, plugin phải tự chạy.
nofile="$tmp/no hook file"
new_repo "$nofile"
mkdir -p "$nofile/.claude"
cp .claude/settings.json "$nofile/.claude/settings.json"
expect_run stop-gate "$nofile" "settings đăng ký stop-gate mà thiếu .claude/hooks/stop-gate.sh: plugin phải tự chạy"

# 4. Tên hook sai: báo lỗi, không im lặng cho qua.
run khong-co "$plain" '{}'
if [ "$rc" -ne 0 ] && grep -q "không có hook" "$tmp/err"; then ok; else bad "hook không tồn tại phải exit khác 0 kèm thông báo (exit $rc)"; fi

# 5. Stop gate qua plugin: chặn khi check của dự án đỏ, im lặng ở dự án không có scripts/check.sh.
stop_input() {
  "$py" -c 'import json, sys; print(json.dumps({"hook_event_name": "Stop", "session_id": "s-" + sys.argv[2], "cwd": sys.argv[1]}))' "$1" "$2"
}
red="$tmp/red"
new_repo "$red"
mkdir -p "$red/scripts"
printf '#!/usr/bin/env bash\necho "lint hỏng"\nexit 1\n' > "$red/scripts/check.sh"
chmod +x "$red/scripts/check.sh"
echo x > "$red/a.py"
run stop-gate "$red" "$(stop_input "$red" red)"
if [ "$rc" -eq 0 ] && text_grep "$out" -q '"block"' && text_grep "$out" -q "lint hỏng"; then ok; else bad "Stop gate của plugin phải chặn khi check đỏ (exit $rc, out=$out)"; fi
echo x > "$plain/a.py"
run stop-gate "$plain" "$(stop_input "$plain" plain)"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok; else bad "dự án không có scripts/check.sh: Stop gate của plugin phải im lặng (exit $rc, out=$out)"; fi
mkdir -p "$red/.claude"
cp -R .claude/hooks "$red/.claude/hooks"
cp .claude/settings.json "$red/.claude/settings.json"
run stop-gate "$red" "$(stop_input "$red" red2)"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok; else bad "dự án đã đăng ký stop-gate: plugin phải nhường, không chạy check lần hai (out=$out)"; fi

# 6. post-edit-format qua plugin: không bao giờ chặn.
run post-edit-format "$plain" "{\"tool_input\":{\"file_path\":\"$plain/a.py\"}}"
if [ "$rc" -eq 0 ]; then ok; else bad "post-edit-format qua plugin phải exit 0 (exit $rc)"; fi

# 7. claude CLI có sẵn (máy dev): manifest phải qua trình kiểm của Claude Code.
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$root" >"$tmp/validate" 2>&1; then ok; else bad "claude plugin validate đỏ: $(tail -n 5 "$tmp/validate")"; fi
else
  printf '• bỏ qua claude plugin validate: không có claude CLI\n'
fi

if [ "$fails" -gt 0 ]; then
  printf '✘ plugin: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ plugin: %s test xanh\n' "$pass"
