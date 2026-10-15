#!/usr/bin/env bash
# Test hành vi của các hook trong .claude/hooks bằng input JSON giống như Claude Code gửi.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
root="$PWD"
hooks="$root/.claude/hooks"

if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
  printf '⚠ bỏ qua test hook: cần python3 hoặc jq để dựng input JSON\n'
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

bash_input() {
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1], "description": "test"}}))' "$1" 2>/dev/null \
    || jq -cn --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "test"}}'
}

expect_guard() {
  local want="$1" cmd="$2" out
  out="$(bash_input "$cmd" | "$hooks/guard-irreversible.sh")"
  if [ "$want" = ask ]; then
    case "$out" in *'"permissionDecision":"ask"'*) ok ;; *) bad "guard phải hỏi: $cmd" ;; esac
  else
    assert "guard không được chặn: $cmd → $out" [ -z "$out" ]
  fi
}

while IFS= read -r c; do [ -n "$c" ] && expect_guard ask "$c"; done <<'EOF'
git push --force origin feat/x
git push -f
git push --force-with-lease origin feat/x
git push origin +feat/x
git push origin main
git push -u origin HEAD:main
git push origin --delete feat/x
git reset --hard HEAD~1
git clean -fd
rm -rf /
rm -rf ~
rm -rf .
rm -rf *
rm -r ../
cd /tmp && rm -Rf $HOME
psql -c "DROP TABLE users;"
npm publish
terraform apply -auto-approve
kubectl delete pod web-1
vercel deploy --prod
npm run deploy
gh pr merge 12 --squash
EOF

while IFS= read -r c; do [ -n "$c" ] && expect_guard allow "$c"; done <<'EOF'
git push -u origin feat/x
git push origin feature/main-thing
git push --dry-run origin feat/x
git reset --soft HEAD~1
rm -rf node_modules
rm -rf ./dist build
git commit -m "fix deploy script and drop table support"
npm test
ls -la
EOF

# Stop gate: dựng một repo tạm với check.sh giả.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gitc() { git -C "$tmp" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
gitc init -q
gitc commit -q --allow-empty -m init
mkdir -p "$tmp/scripts"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ -f "$(dirname "$0")/../GREEN" ]\n' > "$tmp/scripts/check.sh"
chmod +x "$tmp/scripts/check.sh"
gitc add scripts && gitc commit -q -m check

session="test-$$-$RANDOM"
stop_input="{\"hook_event_name\":\"Stop\",\"session_id\":\"$session\",\"cwd\":\"$tmp\",\"stop_hook_active\":false}"
run_stop() { printf '%s' "$stop_input" | AGENT_STOP_GATE_MAX=2 "$hooks/stop-gate.sh" 2>/dev/null; }
# Chặn = JSON {"decision":"block"} với exit 0, hoặc exit 2 khi không có jq/python3.
blocked() {
  [ "$code" -eq 2 ] || { [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '"decision": *"block"'; }
}

out="$(run_stop)"; code=$?
assert "stop-gate: không có thay đổi thì phải cho dừng (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: không có thay đổi thì không in gì" [ -z "$out" ]

echo "ghi chú" > "$tmp/NOTES.md"
out="$(run_stop)"; code=$?
assert "stop-gate: chỉ đổi file .md thì không chạy check (exit $code)" [ "$code" -eq 0 ]

echo "x" > "$tmp/app.js"
out="$(run_stop)"; code=$?
assert "stop-gate: check đỏ thì phải chặn (exit $code)" blocked
case "$out" in *"lần chặn 1/2"*) ok ;; *) bad "stop-gate: lý do chặn phải ghi số lần chặn" ;; esac
out="$(run_stop)"; code=$?
assert "stop-gate: lần chặn thứ 2 vẫn phải chặn (exit $code)" blocked
out="$(run_stop)"; code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q systemMessage; then ok; else bad "stop-gate: quá giới hạn thì nhả kèm systemMessage (exit $code)"; fi

touch "$tmp/GREEN"
out="$(run_stop)"; code=$?
assert "stop-gate: check xanh thì cho dừng (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: check xanh thì không in gì" [ -z "$out" ]

out="$(printf '%s' "$stop_input" | AGENT_STOP_GATE=off "$hooks/stop-gate.sh")"; code=$?
assert "stop-gate: AGENT_STOP_GATE=off phải cho dừng" [ "$code" -eq 0 ]

# Post-edit format: không bao giờ chặn, kể cả khi file không tồn tại.
for f in "$tmp/khong-ton-tai.ts" "$tmp/app.js" "$tmp/NOTES.md"; do
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$f" | "$hooks/post-edit-format.sh"
  code=$?
  assert "post-edit-format phải luôn exit 0 ($f)" [ "$code" -eq 0 ]
done

if [ "$fails" -gt 0 ]; then
  printf '✘ hooks: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ hooks: %s test xanh\n' "$pass"
