#!/usr/bin/env bash
# Test hành vi của các hook trong .claude/hooks bằng input JSON giống như Claude Code gửi.
# Guard được test hai lần: có jq/Python và giả lập máy không có (KIT_NO_JSON_TOOLS=1).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
root="$PWD"
hooks="$root/.claude/hooks"
# shellcheck source=SCRIPTDIR/../.claude/hooks/lib.sh
. "$hooks/lib.sh"
py="$(hook_python)"

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

# bash_input <lệnh> [cwd]: JSON PreToolUse cho Bash. Không có jq/Python thì tự escape.
bash_input() {
  local c="$1" d="${2:-$root}"
  if [ -n "$py" ]; then
    "$py" -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "cwd": sys.argv[2], "tool_name": "Bash", "tool_input": {"command": sys.argv[1], "description": "test"}}))' "$c" "$d"
  elif command -v jq >/dev/null 2>&1; then
    jq -cn --arg c "$c" --arg d "$d" '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Bash", tool_input: {command: $c, description: "test"}}'
  else
    c="$(printf '%s' "$c" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s","description":"test"}}' "$d" "$c"
  fi
}

mode=0
expect_guard() {
  local want="$1" cmd="$2" dir="${3:-$root}" out tag=""
  [ "$mode" = 1 ] && tag=" [không jq/Python]"
  out="$(bash_input "$cmd" "$dir" | KIT_NO_JSON_TOOLS="$mode" "$hooks/guard-irreversible.sh")"
  if [ "$want" = ask ]; then
    case "$out" in *'"permissionDecision":"ask"'*) ok ;; *) bad "guard phải hỏi$tag: $cmd" ;; esac
  else
    assert "guard không được chặn$tag: $cmd → $out" [ -z "$out" ]
  fi
}

for mode in 0 1; do
  while IFS= read -r c; do [ -n "$c" ] && expect_guard ask "$c"; done <<'EOF'
git push --force origin feat/x
git push -f
git push --force-with-lease origin feat/x
git push origin +feat/x
git push origin main
git push -u origin HEAD:main
git push origin refs/heads/main
git push origin --delete feat/x
git -C /repo push --force origin feat/x
git -c x=y push -f origin x
git commit -m "wip" && git push --force
git reset --hard HEAD~1
git clean -fd
git clean -d -f
git clean --force -d
git clean -x -d -f
rm -rf /
rm -rf ~
rm -rf .
rm -rf *
rm -r ../
rm -rf "$HOME"
rm -rf $HOME/
cd /tmp && rm -Rf $HOME
bash -c "rm -rf /"
psql -c "DROP TABLE users;"
npm publish
terraform apply -auto-approve
terraform -chdir=infra apply -auto-approve
kubectl delete pod web-1
kubectl -n prod delete deployment web
kubectl --context prod apply -f k8s/
helm -n prod upgrade web ./chart
vercel deploy --prod
npm run deploy
gh pr merge 12 --squash
EOF

  while IFS= read -r c; do [ -n "$c" ] && expect_guard allow "$c"; done <<'EOF'
git push -u origin feat/x
git push origin feature/main-thing
git push --dry-run origin feat/x
git -C /repo push origin feat/x
git reset --soft HEAD~1
git clean -n
git rm -r --cached .
rm -rf node_modules
rm -rf ./dist build
git commit -m "fix deploy script and drop table support"
kubectl get pods -n prod
terraform plan
npm test
ls -la
EOF
done
mode=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gitc() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# Guard: `git push` không refspec đẩy nhánh hiện tại → chỉ hỏi khi đang đứng trên nhánh chính.
br="$tmp/branch"
mkdir -p "$br"
gitc "$br" init -q
gitc "$br" checkout -q -b main
gitc "$br" commit -q --allow-empty -m init
expect_guard ask "git push" "$br"
expect_guard ask "git push -u origin HEAD" "$br"
expect_guard ask "git -C $br push" "$root"
gitc "$br" checkout -q -b feat/x
expect_guard allow "git push" "$br"
expect_guard allow "git push -u origin HEAD" "$br"

# Stop gate: repo tạm có check.sh giả (xanh khi có file GREEN).
make_repo() {
  mkdir -p "$1/scripts"
  gitc "$1" init -q
  gitc "$1" commit -q --allow-empty -m init
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ -f "$(dirname "$0")/../GREEN" ]\n' > "$1/scripts/check.sh"
  chmod +x "$1/scripts/check.sh"
  gitc "$1" add scripts
  gitc "$1" commit -q -m check
}
repo="$tmp/stop"
make_repo "$repo"
session="test-$$-$RANDOM"
stop_input() { printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","stop_hook_active":false}' "$session" "$1"; }
run_stop() { stop_input "${1:-$repo}" | AGENT_STOP_GATE_MAX=2 "$hooks/stop-gate.sh" 2>/dev/null; }
# Chặn = JSON {"decision":"block"} với exit 0, hoặc exit 2 khi không có jq/Python.
blocked() {
  [ "$code" -eq 2 ] || { [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '"decision": *"block"'; }
}

out="$(run_stop)"; code=$?
assert "stop-gate: không có thay đổi thì phải cho dừng (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: không có thay đổi thì không in gì" [ -z "$out" ]

echo "ghi chú" > "$repo/NOTES.md"
echo "ghi chú" > "$repo/ghi-chú.md"
out="$(run_stop)"; code=$?
assert "stop-gate: chỉ đổi file .md (kể cả tên có dấu) thì không chạy check (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: chỉ đổi file .md thì không in gì" [ -z "$out" ]

echo "x" > "$repo/app.js"
out="$(run_stop)"; code=$?
assert "stop-gate: check đỏ thì phải chặn (exit $code)" blocked
case "$out" in *"lần chặn 1/2"*) ok ;; *) bad "stop-gate: lý do chặn phải ghi số lần chặn" ;; esac
out="$(run_stop)"; code=$?
assert "stop-gate: lần chặn thứ 2 vẫn phải chặn (exit $code)" blocked
out="$(run_stop)"; code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q systemMessage; then ok; else bad "stop-gate: quá giới hạn thì nhả kèm systemMessage (exit $code)"; fi

# Bộ đếm phải về 0 khi không còn thay đổi: chặn 1 lần, bỏ thay đổi, rồi đỏ lại → bắt đầu từ 1.
run_stop >/dev/null
rm "$repo/app.js"
run_stop >/dev/null
echo "x" > "$repo/app.js"
out="$(run_stop)"; code=$?
case "$out" in *"lần chặn 1/2"*) ok ;; *) bad "stop-gate: hết thay đổi thì bộ đếm phải về 0 → $out" ;; esac

touch "$repo/GREEN"
out="$(run_stop)"; code=$?
assert "stop-gate: check xanh thì cho dừng (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: check xanh thì không in gì" [ -z "$out" ]
rm "$repo/GREEN"

out="$(stop_input "$repo" | AGENT_STOP_GATE=off "$hooks/stop-gate.sh")"; code=$?
assert "stop-gate: AGENT_STOP_GATE=off phải cho dừng" [ "$code" -eq 0 ]

session="test-$$-$RANDOM"
out="$(stop_input "$repo" | KIT_NO_JSON_TOOLS=1 AGENT_STOP_GATE_MAX=9 "$hooks/stop-gate.sh" 2>/dev/null)"; code=$?
assert "stop-gate: không có jq/Python thì chặn bằng exit 2 (exit $code)" [ "$code" -eq 2 ]

# Commit cục bộ trên nhánh chưa có upstream vẫn là thay đổi chưa push → phải chạy check.
remote="$tmp/remote.git"
git init -q --bare "$remote"
feat="$tmp/feat"
make_repo "$feat"
gitc "$feat" remote add origin "$remote"
gitc "$feat" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
gitc "$feat" checkout -q -b feat/x
echo "x" > "$feat/app.js"
gitc "$feat" add app.js
gitc "$feat" commit -q -m "feat: app"
session="test-$$-$RANDOM"
out="$(run_stop "$feat")"; code=$?
assert "stop-gate: commit chưa push trên nhánh không có upstream phải bị chặn khi check đỏ (exit $code)" blocked
gitc "$feat" push -q -u origin feat/x >/dev/null 2>&1
session="test-$$-$RANDOM"
out="$(run_stop "$feat")"; code=$?
assert "stop-gate: đã push hết thì cho dừng (exit $code)" [ "$code" -eq 0 ]

# Post-edit format: không bao giờ chặn, kể cả khi file không tồn tại.
for f in "$tmp/khong-ton-tai.ts" "$repo/app.js" "$repo/NOTES.md"; do
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$f" | "$hooks/post-edit-format.sh"
  code=$?
  assert "post-edit-format phải luôn exit 0 ($f)" [ "$code" -eq 0 ]
done

if [ "$fails" -gt 0 ]; then
  printf '✘ hooks: %s/%s test đỏ\n' "$fails" "$((fails + pass))" >&2
  exit 1
fi
printf '✔ hooks: %s test xanh\n' "$pass"
