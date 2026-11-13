#!/usr/bin/env bash
# Test hành vi của các hook trong .claude/hooks bằng input JSON giống như Claude Code gửi.
# Guard được test với từng cách đọc JSON: auto (jq), python, sed (KIT_JSON_TOOL).
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

# bash_input <lệnh> [cwd]: JSON PreToolUse cho tool $TOOL (mặc định Bash). Không có jq/Python thì tự escape.
bash_input() {
  local c="$1" d="${2:-$root}"
  if [ -n "$py" ]; then
    "$py" -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "cwd": sys.argv[2], "tool_name": sys.argv[3], "tool_input": {"command": sys.argv[1], "description": "test"}}))' "$c" "$d" "${TOOL:-Bash}"
  elif command -v jq >/dev/null 2>&1; then
    jq -cn --arg c "$c" --arg d "$d" --arg t "${TOOL:-Bash}" '{hook_event_name: "PreToolUse", cwd: $d, tool_name: $t, tool_input: {command: $c, description: "test"}}'
  else
    c="$(printf '%s' "$c" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"%s","tool_input":{"command":"%s","description":"test"}}' "$d" "${TOOL:-Bash}" "$c"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# cd rồi mới gọi git, không dùng git -C: Git Bash không đổi đường /tmp/... có [ ] sang đường Windows cho
# git.exe, nên git -C "$tmp/a[x]b" báo "cannot change to" và repo không được tạo.
gitc() { (cd "$1" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c core.autocrlf=false "${@:2}"); }
# new_repo <thư mục> <nhánh>
new_repo() {
  mkdir -p "$1"
  gitc "$1" init -q
  gitc "$1" checkout -q -b "$2"
  gitc "$1" commit -q --allow-empty -m init
}
# Mặc định chạy guard trong repo tạm trên nhánh feature, để kết quả không phụ thuộc nhánh của repo kit.
work="$tmp/work"
new_repo "$work" feat/x
on_main="$tmp/main repo"
new_repo "$on_main" main
# Repo ở nhánh chính có \ trong tên (x\m; Windows đọc là x/m).
new_repo "$tmp/x\\m" main
# Repo ở nhánh chính, đường dẫn có hai dấu cách.
sp2="$tmp/sp ace plain/x"
new_repo "$sp2" main
# Repo ở nhánh chính, đường dẫn có chữ git và push.
odd="$tmp/my git/github/pushy-main"
new_repo "$odd" main
# Repo ở nhánh chính có tên kết thúc bằng \ (giả lập C:\vnstock\ của PowerShell trên Linux).
bsm="$tmp/w\\"
new_repo "$bsm" main
# Repo ở nhánh chính có tên là mẫu glob khớp một repo ở nhánh feature (a[x]b khớp axb).
globm="$tmp/a[x]b"
new_repo "$globm" main
new_repo "$tmp/axb" feat/x
# Repo ở nhánh feature có symlink trỏ vào thư mục con của repo ở main: git -C link/.. chdir theo đường vật lý,
# tức chạy trong repo ở main. Windows (Git Bash) thường không tạo được symlink thật thì bỏ các ca này.
symf="$tmp/sym feat"
new_repo "$symf" feat/x
mkdir -p "$on_main/sub"
ln -s "$on_main/sub" "$symf/link" 2>/dev/null && [ -L "$symf/link" ] || symf=""
# Chiều ngược lại: repo ở main có symlink trỏ vào thư mục con của repo ở feature. cd của shell đi theo đường
# logic, nên cd "$symm/link/.." vào repo ở main dù đường vật lý là repo ở feature.
symm="$tmp/sym main"
new_repo "$symm" main
mkdir -p "$work/sub"
ln -s "$work/sub" "$symm/link" 2>/dev/null && [ -L "$symm/link" ] || symm=""

modes="auto sed"
[ -n "$py" ] && modes="auto python sed"
mode=auto
ask_count=0
nl=$'\n'
# bash 3.2 (macOS) tới 4.2 giữ dấu nháy của chuỗi thay trong "${x//a/"b"}" (ra "b" kèm nháy). BASH_COMPAT=42
# bắt bash 4.3+ làm y như vậy, để máy Linux/Windows cũng bắt được lỗi chỉ lộ ra trên macOS.
bash42=""
# shellcheck disable=SC2016  # biểu thức được bash con mở rộng
[ "$(BASH_COMPAT=42 bash -c 'x=a; printf %s "${x/a/"b"}"' 2>/dev/null)" = '"b"' ] && bash42=42
# RUN=<hàm>: chạy guard qua hàm đó (nofile, nofile50: xem khối "không tạo được file tạm").
expect_guard() {
  local want="$1" cmd="$2" dir="${3:-$work}" inp
  inp="$(bash_input "$cmd" "$dir")"
  [ "$want" = ask ] && [ "$mode" = auto ] && ask_count=$((ask_count + 1))
  check_guard "$want" "$cmd" "$inp" ""
  # Lệnh có dấu nối dòng: guard nối dòng bằng ${x//a/b}, chạy thêm như bash 3.2-4.2.
  case "$mode:$bash42:$cmd" in auto:42:*"\\$nl"* | auto:42:*"\`$nl"*) check_guard "$want" "$cmd" "$inp" 42 ;; esac
}
# check_guard <ask|allow> <lệnh> <input JSON> <BASH_COMPAT cho guard, rỗng là mặc định>
check_guard() {
  local out tag=" [$mode${RUN:+ $RUN}${4:+, BASH_COMPAT=$4}]"
  out="$(printf '%s\n' "$3" | BASH_COMPAT="$4" KIT_JSON_TOOL="$mode" ${RUN:+"$RUN"} "$hooks/guard-irreversible.sh")"
  if [ "$1" = ask ]; then
    case "$out" in *'"permissionDecision":"ask"'*) ok ;; *) bad "guard phải hỏi$tag: $2 → [$out], input: $3" ;; esac
  else
    assert "guard không được chặn$tag: $2 → $out" [ -z "$out" ]
  fi
}

for mode in $modes; do
  while IFS= read -r c; do [ -n "$c" ] && expect_guard ask "$c"; done <<'EOF'
git push --force origin feat/x
git push origin :feat/x
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
if [ -d x ]; then rm -rf ~; fi
time rm -rf ~
wsl rm -rf ~
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

  # Đang ở nhánh chính: mọi `git push` đều phải hỏi, kể cả có redirect, option hay đường dẫn có dấu cách.
  while IFS= read -r c; do [ -n "$c" ] && expect_guard ask "$c" "$on_main"; done <<'EOF'
git push
git push -u origin HEAD
git push origin 2>&1
git push -u origin 2>&1 | tail -3
git push origin > /dev/null
git push -o ci.skip origin
git commit -m "Đổi tên" && git push origin
EOF
  expect_guard ask "git -C \"$on_main\" push origin"
  expect_guard ask "cd \"$on_main\" && git push"
  # Từ khoá và tiền tố trước cd mà CDA chưa nhận, option -e/-@ của cd (4.10).
  expect_guard ask "time cd \"$on_main\" && git push"
  expect_guard ask "! cd \"$on_main\" || git push"
  expect_guard ask "while cd \"$on_main\"; do git push; break; done"
  expect_guard ask "until cd \"$on_main\"; do sleep 1; done; git push"
  expect_guard ask "eval cd \"'$on_main'\" && git push"
  expect_guard ask "x=1 cd \"$on_main\" && git push"
  expect_guard ask "A=1 B=2 cd \"$on_main\" && git push"
  expect_guard ask "if true; then :; elif cd \"$on_main\"; then git push; fi"
  expect_guard ask "cd -e \"$on_main\" && git push"
  expect_guard ask "cd -@ \"$on_main\" && git push"
  expect_guard allow "x=1 cd \"$work\" && git push"
  # Phép gán có nháy và dấu cách trước cd; `;&|` trong nháy không ngắt luật force-push (4.10).
  expect_guard ask "x=\"a b\" cd \"$on_main\" && git push"
  expect_guard ask "A='1 2' B=3 cd \"$on_main\" && git push"
  expect_guard ask "git push origin \"x;y\" --force"
  expect_guard ask "git push -o 'ci.skip|x' origin feat --force"
  expect_guard ask "git push origin 'a&b' +feat"
  expect_guard allow "git push origin \"x;y\""
  # Thân lệnh trong nháy (có dấu cách) giữ `;&|` thật: không được nối hai lệnh để luật khớp xuyên qua (reviewer PR #53).
  expect_guard allow "timeout 60 bash -c \"git push -u origin feat && gh pr create --draft --base main\""
  expect_guard allow "bash -c 'git push -u origin feat && gh pr create -d --title x'"
  expect_guard allow "ssh host 'git push origin feat; git branch -d old'"
  expect_guard allow "git commit -m \"docs: git push; never -f\""
  # cd giả trong chuỗi (chỉ khớp nhờ tiền tố mới) không được đổi chỗ đứng của cd thật phía sau (reviewer 4.10).
  expect_guard ask "git commit -m \"doc; x=1 cd work\"; cd \"main repo\" && git push" "$tmp"
  expect_guard ask "echo \"doc: run time cd work\"; cd \"main repo\" && git push" "$tmp"
  expect_guard ask "echo \"x ! cd work\"; cd \"main repo\" && git push" "$tmp"
  # cd tới thư mục không có thì lỗi, shell ở lại chỗ cũ: cd tương đối sau đó tính từ chỗ cũ (4.3).
  expect_guard ask "cd \"$tmp/nope\"; cd \"main repo\"; git push" "$tmp"
  expect_guard allow "git push"
  expect_guard allow "git push -u origin HEAD 2>&1"

  # PowerShell tool (Windows): cùng tool_input.command, nhưng lệnh xoá và đổi thư mục viết khác.
  while IFS= read -r c; do [ -n "$c" ] && expect_guard ask "$c"; done <<'EOF'
Remove-Item -Recurse -Force C:\
Remove-Item C:\ -Recurse -Force
Remove-Item -Path "C:\" -Recurse
Remove-Item -Recurse -Force C:\*
Remove-Item -Recurse -Force $env:USERPROFILE
Remove-Item -Recurse -Force .\*
Remove-Item -Recurse -Force ..\
rm -r -fo $HOME
ri -r ~\
rd /s /q C:\
rmdir /s /q .
del /s /q *
cd C:\x; Remove-Item -Recurse -Force *
git push --force origin feat/x 2>&1 | Out-String
Remove-Item -Recurse -Force 'C:\'
Remove-Item -Recurse -Force -LiteralPath 'C:\'
Remove-Item -Recurse -Force '.'
Remove-Item -Recurse -Force '*'
Remove-Item -Recurse -Force ..\*
Remove-Item -Recurse -Force $HOME\*
Remove-Item -Recurse -Force "$HOME\*"
Remove-Item -Recurse -Force $HOME/*
Remove-Item -Recurse -Force $env:USERPROFILE\*
Remove-Item -Recurse -Force $env:SystemDrive\*
Remove-Item -Recurse -Force \
Remove-Item -Recurse -Force /
Remove-Item -Recurse:$true -Force C:\
cmd /c rd /s /q C:\
cmd.exe /c rd /s /q C:\
cmd /c del /s /q *
del /s /q C:\*.*
del /S /Q *.*
Remove-Item -Recurse -Force \*
Remove-Item -Recurse -Force /*
Remove-Item \* -Recurse
ri -r -fo /*
del /s /q \*
Remove-Item -Recurse -Force '\*'
cmd /c del /s /q \*
cmd /d /c rd /s /q C:\
Remove-Item -Recurse -Force ${env:USERPROFILE}\*
rmdir /s /q %USERPROFILE%
rd /s /q %USERPROFILE%\*
EOF
  while IFS= read -r c; do [ -n "$c" ] && expect_guard allow "$c"; done <<'EOF'
Remove-Item -Recurse -Force .\dist
Remove-Item -Recurse node_modules
Remove-Item .\build\out.txt
Remove-Item C:\temp\x.txt
Get-ChildItem -Recurse
Remove-Item -Recurse -Force "$env:TEMP\x"
rd /s /q build
del /s /q *.pyc
cmd /c rd /s /q build
EOF
  expect_guard ask "Set-Location \"$on_main\"; git push"
  expect_guard ask "Set-Location -Path \"$on_main\"; git push origin"
  expect_guard ask "Set-Location -PATH \"$on_main\"; git push"
  expect_guard ask "Push-Location \"$on_main\"; git push"
  # popd quay về thư mục cũ, hoặc đường dẫn không resolve được: xét cả thư mục của phiên.
  expect_guard ask "Push-Location \"$work\"; Pop-Location; git push" "$on_main"
  expect_guard ask "pushd \"$work\"; popd; git push" "$on_main"
  # shellcheck disable=SC2016  # $env:REPO là chữ của lệnh PowerShell
  expect_guard ask 'Set-Location $env:REPO; git push' "$on_main"
  # Phiên đang ở nhánh chính: mọi git push đều hỏi, kể cả cd/-C sang repo khác.
  expect_guard ask "cd \"$work\" && git push" "$on_main"
  # Lệnh xuống dòng bằng \ (bash) hoặc ` (PowerShell): nối dòng trước khi so mẫu.
  expect_guard allow $'rm -rf build \\\n  dist'
  expect_guard allow $'rm -rf /tmp/a \\\n  /tmp/b'
  TOOL=PowerShell expect_guard ask $'Remove-Item -Recurse -Force `\n  C:\\'
  expect_guard ask $'rm -rf \\\n  ~'
  # \ cuối dòng trong PowerShell/cmd là đường dẫn, ` cuối dòng trong bash là đóng `...`:
  # lệnh ở dòng sau vẫn phải được xét như một lệnh mới.
  TOOL=PowerShell expect_guard ask $'Set-Location C:\\\nRemove-Item -Recurse -Force *'
  TOOL=PowerShell expect_guard ask $'Set-Location $env:TEMP\\build\\\nRemove-Item -Recurse -Force .\\*'
  TOOL=PowerShell expect_guard ask $'cd /d C:\\\nrd /s /q .'
  TOOL=PowerShell expect_guard ask $'dir C:\\\ndel /s /q *'
  TOOL=PowerShell expect_guard ask $'cd C:\\\r\nRemove-Item -Recurse -Force *'
  expect_guard ask $'cd `mktemp -d`\nrm -rf *'
  expect_guard ask $'x=`pwd`\nrm -rf ~'
  TOOL=PowerShell expect_guard ask $'Write-Host done `\nRemove-Item -Recurse -Force C:\\'
  TOOL=PowerShell expect_guard ask $'Get-ChildItem C:\\\ndropdb prod'
  TOOL=PowerShell expect_guard ask $'Get-ChildItem C:\\\nnpm run deploy'
  TOOL=PowerShell expect_guard ask $'Remove-Item -Recurse -Force \\\nWrite-Host done'
  TOOL=PowerShell expect_guard ask $'rd /s /q \\\necho done'
  expect_guard ask $'echo hi\nrm -rf /'
  TOOL=PowerShell expect_guard ask "$(printf 'Get-ChildItem C:\\\nSet-Location "%s"\ngit push' "$on_main")"
  # cd đứng SAU git push không được đổi thư mục mà push được xét, kể cả khi lệnh có dấu nối dòng.
  expect_guard ask "$(printf 'git push\ncd "%s" && ls \\\n  -la' "$work")" "$on_main"
  expect_guard ask "$(printf 'git push origin \\\n  HEAD\ncd "%s"' "$work")" "$on_main"
  TOOL=PowerShell expect_guard ask "$(printf 'git push\nSet-Location "%s"\nGet-ChildItem `\n  -Force' "$work")" "$on_main"
  TOOL=Unknown expect_guard ask "$(printf 'git push\ncd "%s" && ls \\\n  -la' "$work")" "$on_main"
  # Dấu nối nằm giữa cd/git -C và đường dẫn: vẫn phải tìm ra thư mục.
  expect_guard ask "$(printf 'cd \\\n  "%s" && git push' "$on_main")"
  expect_guard ask "$(printf 'git -C \\\n  "%s" push' "$on_main")"
  expect_guard ask "$(printf 'pushd \\\n "%s"; git push' "$on_main")"
  TOOL=PowerShell expect_guard ask "$(printf 'git -C `\n "%s" push' "$on_main")"
  TOOL=PowerShell expect_guard ask "$(printf 'Set-Location `\n "%s"\ngit push' "$on_main")"
  # -C của lệnh git KHÁC không đổi thư mục của git push.
  expect_guard ask "git -C \"$work\" fetch && git push" "$on_main"
  expect_guard ask "$(printf 'git -C "%s" status\ngit push' "$work")" "$on_main"
  expect_guard ask "git push && git -C \"$work\" log -1" "$on_main"
  expect_guard ask "git -C \"$work\" push" "$on_main"
  # Đường dẫn chứa chữ git/push, nhiều lệnh push, git log --grep=push: không được đánh lừa.
  expect_guard ask "git -C \"$odd\" push"
  expect_guard ask "git -C \"$on_main\" push && git -C \"$work\" push"
  expect_guard ask "git -C \"$on_main\" push; git push"
  expect_guard ask "git -C \"$on_main\" push && git log --grep=push"
  expect_guard ask "git push && cd \"$work\" && git push" "$on_main"
  expect_guard ask "cd \"$odd\" && git push"
  # Đường dẫn không được bị glob thành thư mục khác.
  expect_guard ask "cd \"$globm\" && git push"
  expect_guard ask "git -C \"$globm\" push"
  if [ -n "$symf" ]; then
    expect_guard ask "git -C link/.. push" "$symf"
    expect_guard ask "git --git-dir=link/../.git push" "$symf"
    expect_guard ask "GIT_DIR=link/../.git git push" "$symf"
  fi
  if [ -n "$symm" ]; then
    expect_guard ask "cd \"$symm/link/..\" && git push"
    expect_guard ask "pushd \"$symm/link/..\"; git push"
    # `..` có nháy hay `\` giữa từ: bash bỏ nháy rồi vẫn đi đường logic về repo ở main (mục 4.10 cũ của docs/viec-can-lam.md).
    expect_guard ask "cd \"$symm/link/\"'..' && git push"
    expect_guard ask "cd \"$symm/link\"/'..' && git push"
    expect_guard ask "cd \"$symm/link/\".. && git push"
    expect_guard ask "cd \"$symm/link/\"\\.\\. && git push"
    expect_guard ask "pushd '$symm/link'/..; git push"
    expect_guard ask "sh -c 'cd '\\''$symm/link'\\''/.. && git push'"
  fi
  # Thân của bash -c / sh -c: shell con đọc lại chuỗi sau khi shell ngoài bỏ một lớp nháy, nên '\'' trong thân là một
  # dấu nháy của lệnh con (mục 4.10 cũ của docs/viec-can-lam.md).
  expect_guard ask "bash -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c 'cd \"$tmp/sp ace plain/\"'\\''x'\\'' && git push'"
  expect_guard ask "bash -c \"cd \\\"$on_main\\\" && git push\""
  expect_guard ask "bash -lc 'git -C '\\''$on_main'\\'' push'"
  expect_guard ask "sh -c 'git --git-dir='\\''$sp2/.git'\\'' push'"
  expect_guard ask "/bin/bash -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -o pipefail -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --norc -c -- 'cd '\\''$on_main'\\'' && git push'"
  # Chữ lệnh bị nháy hay \ xé đôi: bash bỏ nháy giữa từ rồi chạy y như bản không nháy (4.10 của docs/viec-can-lam.md).
  expect_guard ask "git pu'sh' --force origin feat/x"
  expect_guard ask "git \"push\" --for\"ce\" origin feat/x"
  expect_guard ask "git pu\\sh -f"
  expect_guard ask "r'm' -rf /"
  expect_guard ask "\"rm\" -rf ~"
  expect_guard ask "git reset --ha''rd"
  expect_guard ask "git cl\"ea\"n -fd"
  expect_guard ask "npm run dep'loy'"
  expect_guard ask "git pu'sh'" "$on_main"
  expect_guard ask "git -C '$on_main' pu\"sh\""
  expect_guard ask "c'd' '$on_main' && git push"
  # Lệnh con có nháy sau giá trị option có `\"` và dấu cách (reviewer PR #75): dạng dq ghép `"\"` thành `\`, giá trị bị tách
  # đôi, nên `"push"` không còn đứng ngay sau option.
  expect_guard ask 'git -c user.name="\"a b\"" "push" -f origin feat/x'
  expect_guard ask 'git -c user.name="\"a b\"" p"u"sh --force origin feat/x'
  expect_guard ask 'git -c user.name="\"a b\"" "push" origin main'
  expect_guard ask 'git -c user.name="\"a b\"" "reset" --hard'
  expect_guard ask 'git -c core.sshCommand="ssh -o \"User x\"" "push" -f origin feat/x'
  expect_guard allow 'git -c user.name="\"a b\"" "push" origin HEAD'
  # `\\` trong nháy kép là một `\` đã thoát (reviewer PR #78): `"\"a b\\"` là `"a b\`, nháy cuối đóng chuỗi. Thay `\"` mà
  # không biết `\\` thì `\\"` thành `\` + \002, nháy đóng bị nuốt.
  expect_guard ask 'git -c user.name="\"a b\\" "push" -f origin feat/x'
  expect_guard ask 'git -c "main\\" -c u="\"a b\"" "push" -f origin feat/x'
  expect_guard ask 'git -c u="\"a b\\\"" "push" -f origin feat/x'
  expect_guard allow 'git -c user.name="\"a b\\" "push" origin HEAD'
  # Như trên nhưng chữ lệnh con xé bằng mở rộng rỗng (verifier PR #87): chỉ dạng dz ghép lại được `pu``sh`, mà dz xoá hết
  # nháy nên `"\"a b\""` thành `a b`, `b` thành lệnh con.
  expect_guard ask 'git -c user.name="\"a b\"" pu``sh -f origin feat/x'
  expect_guard ask 'git -c user.name="\"a b\"" "pu$()sh" -f origin feat/x'
  expect_guard ask 'git -c user.name="\"a b\"" pu${X}sh --force origin feat/x'
  expect_guard ask 'git -c user.name="\"a b\"" re``set --hard'
  expect_guard ask 'git -c user.name="\"a b\"" pu`true`sh -f origin feat/x'
  expect_guard ask 'git -c user.name="\"a b\\" pu``sh -f origin feat/x'
  expect_guard allow 'git -c user.name="\"a b\"" pu``sh origin HEAD'
  # Không riêng `\"` (reviewer PR #88): dz xoá mọi nháy, nên mọi giá trị có dấu cách trong nháy hay sau `\` bị tách đôi.
  expect_guard ask 'git -C "x y" pu``sh -f origin feat/x'
  expect_guard ask "git -C 'x y' pu\$()sh -f origin feat/x"
  expect_guard ask "git -c user.name='a b' pu\`\`sh -f origin feat/x"
  expect_guard ask 'git -c "user.name=a b" pu``sh -f origin feat/x'
  expect_guard ask "git -c 'user.name=\"a b\"' pu\`\`sh -f origin feat/x"
  expect_guard ask 'git -c user.name=a\ b pu``sh -f origin feat/x'
  expect_guard ask "npm --otp 'a b' pub\`\`lish"
  expect_guard ask "git -c user.name='a b' pu\`\`sh origin HEAD" "$on_main"
  # Backtick lẻ trong nháy đơn: dz2 bỏ cả `…` có nội dung nên ghép nó với backtick của `re``set` và nuốt mất lệnh; dz chỉ
  # bỏ cặp rỗng nên còn đọc được (reset, không phải push: cổng push đã hỏi vì backtick).
  expect_guard ask "echo '\`'; git -c user.name='a b' re\`\`set --hard"
  expect_guard allow "git -c user.name='a b' commit -m 'x \`y\` z'"
  # Mỗi `-C` tốn một lần last_arg + expand_dir mà GC_MAX chỉ đếm lần ghép: `git -C q status; `×5000 rồi push (ngay dưới
  # GC_MAX) mất 7,3 giây với bash 3.2 ở UTF-8 mà không hỏi, Git Bash chậm gấp đôi thì quá timeout (4.3, reviewer PR #75).
  # Nay quá GCX_MAX lần -C thì hỏi. Lệnh dưới ~32 KB: bash_input truyền lệnh qua đối số của python, mà Windows giới hạn dòng
  # lệnh 32767 ký tự (2000 `git -C q status; ` là 34 KB: "Argument list too long", input rỗng, guard cho qua; CI PR #82).
  expect_guard ask "$(printf 'git -C q; %.0s' $(seq 2000))git push origin HEAD"
  # Gộp nhiều trần (reviewer PR #83): 45 cd × 60 đoạn nháy, 249 `cd .`, 2 `git -C "a×600"` rồi push, dưới UQW_MAX, CD_MAX,
  # GC_MAX và BYTE_MAX, mà mất 6,5 giây với bash 3.2 (runner macOS chậm hơn thì sát timeout): công ghép đường (nb_add)
  # chưa tính vào ngân sách. Nay mỗi byte ghép cộng 2 vào uqw, quá UQW_MAX thì hỏi.
  sg="$(printf '"a"'"'b'"'%.0s' $(seq 30))"
  expect_guard ask "$(printf "cd $sg; %.0s" $(seq 45))$(printf 'cd .; %.0s' $(seq 249))$(printf 'git -C "%s" status; ' "$(printf 'a%.0s' $(seq 600))" "$(printf 'a%.0s' $(seq 600))")git push origin HEAD"
  # Đường có dấu (reviewer PR #84): BYTE_MAX đếm cận 4 byte mỗi ký tự ngoài ASCII, nhưng công ghép tính theo ký tự. Nhân 4
  # vào ngân sách thì monorepo ở thư mục tiếng Việt (15 cd, 15 `git -C` có nháy) bị hỏi thừa, main cho qua.
  vnr="$tmp/vn/Người dùng Nguyễn Văn Ấn/Tài liệu dự án/Ứng dụng tài chính"
  [ -d "$vnr/gói-số-15/src" ] || { new_repo "$vnr" feat/x && for i in $(seq 15); do mkdir -p "$vnr/gói-số-$i/src"; done; }
  vc="cd \"gói-số-1\" && npm test; "
  for i in $(seq 2 15); do vc="${vc}cd \"../gói-số-$i\" && npm test; "; done
  for i in $(seq 15); do vc="${vc}git -C \"../gói-số-$i/src\" add -A; "; done
  expect_guard allow "${vc}git push origin HEAD" "$vnr"
  # Lý do khi vượt ngân sách đếm thành phần trên các đường đã bỏ trùng, như bước kiểm PART_MAX sau vòng lặp (reviewer
  # PR #84): monorepo 62 cd rồi 62 `git -C` tới cùng các đường tuyệt đối ~100 ký tự không có đường nối dồn nào, mà
  # đếm cả bản trùng (dl, cl, RD) thì lý do thành "hơn 60000 thành phần". Đường đệm tới ~100 ký tự để ngân sách
  # chạm như nhau dù $tmp dài ngắn.
  if [ "$mode" = auto ]; then
    mpad=""; while [ $((${#tmp} + ${#mpad})) -lt 70 ]; do mpad="${mpad}p"; done
    mor="$tmp/mo${mpad}/services/backend/platform-core/modules"
    [ -d "$mor/pkg-62/src" ] || { new_repo "$tmp/mo$mpad" feat/x && for i in $(seq -w 62); do mkdir -p "$mor/pkg-$i/src"; done; }
    mc=""
    for i in $(seq -w 62); do mc="${mc}cd $mor/pkg-$i/src && npm test; "; done
    for i in $(seq -w 62); do mc="${mc}git -C $mor/pkg-$i/src add -A; "; done
    out="$(bash_input "${mc}git push origin HEAD" "$tmp/mo$mpad" | KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh")"
    case "$out" in
      *'thành phần'*) bad "guard không được báo PART_MAX khi các đường đã bỏ trùng dưới trần: 62 cd + 62 git -C tuyệt đối → [$out]" ;;
      *) ok ;;
    esac
  fi
  # Dưới trần thì vẫn đọc như trước (GCX_MAX đếm mỗi -C ở mỗi cách đọc: hỏi từ ~1501 -C không nháy, ~751 có nháy).
  expect_guard allow "$(printf "git -C 'q' status; %.0s" $(seq 300))git push origin HEAD"
  # `\\` trong nháy đơn là hai ký tự thường (reviewer PR #79): thay mọi `\\` bằng \003 thì `"` sau nó không còn bị che,
  # ghép với nháy kép phía sau và tách đôi giá trị. Dạng dq2 cũ vẫn bắt được, nên dạng mới phải thêm, không thay.
  expect_guard ask "git -c u='x\\\\\"'\"y z\" \"push\" -f origin feat/x"
  expect_guard ask "git -c u='\\\\\"'\"\\\"a b\\\"\" \"push\" -f origin feat/x"
  expect_guard ask "git -c u='x\\\\\"'\"\\\"y z\\\"\" \"push\" -f origin feat/x"
  expect_guard ask "bash -c 'git -C '\\''$on_main'\\'' pu'\\''sh'\\'''"
  # Reviewer của PR sửa nháy xé chữ: biến đổi bù nhau làm danh sách từ khoá như cũ, option của cd bị xé, $'…', \ trước
  # ký tự không phải chữ cái.
  expect_guard ask "cd;c'd' '$on_main' && git push"
  expect_guard ask "echo -C;c'd' '$on_main' && git push"
  expect_guard ask "cd -'P' '$on_main' && git push"
  expect_guard ask "cd '--' '$on_main' && git push"
  expect_guard ask "git \$'p'ush --force origin feat/x"
  expect_guard ask "git push -\\-force origin feat/x"
  # 4.10 còn lại (reviewer, bash thật): tên shell xé, \ nối dòng giữa chữ, ANSI-C, mở rộng rỗng, ngoặc nhọn, "$@",
  # backtick của PowerShell.
  expect_guard ask "ba'sh' -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "\"bash\" -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -'c' 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "git pu\\${nl}sh --force origin feat/x"
  expect_guard ask "r\\${nl}m -rf /"
  # Nối dòng thường (` \` cuối dòng) rồi dòng sau có chữ xé (reviewer PR #88): dz, dz2 chỉ nối khi `\` dính chữ, dạng
  # nối của join_lines thì không bỏ mở rộng rỗng, nên không dạng nào thấy `git push -f`.
  expect_guard ask "git \\${nl}pu\`\`sh -f origin feat/x"
  expect_guard ask "r\`\`m -rf \\${nl}~"
  expect_guard ask "git \\${nl}re\`\`set --hard"
  expect_guard ask "npm \\${nl}pub\`\`lish"
  expect_guard ask "git \\${nl}-c x=1 \\${nl}pu\$()sh -f origin feat/x"
  expect_guard ask "git -c user.name='a b' \\${nl}pu\`\`sh -f origin feat/x"
  expect_guard ask "git \\${nl}pu\`\`sh origin HEAD" "$on_main"
  expect_guard allow "git \\${nl}pu\`\`sh origin HEAD"
  expect_guard allow "echo a \\${nl}\`date\` b"
  expect_guard ask "git \\${nl}\\${nl}pu\`\`sh -f origin feat/x"
  # Gộp chuỗi nối thay cho dòng cũ thì mất dòng mà main vẫn đọc (reviewer PR #89): `rm` không còn ở đầu dòng sau
  # `timeout 60`, dòng gộp quá 4096 ký tự thì không mở ngoặc nhọn, quá 16384 thì không giải $'…'.
  expect_guard ask "timeout 60 \\${nl}r\`\`m -rf ~"
  expect_guard ask "sudo -n \\${nl}r\`\`m -rf /"
  expect_guard ask "echo \\${nl}$(printf 'a%.0s' $(seq 4100)) \\${nl}; git {,pu\`\`sh} -f origin feat/x"
  expect_guard ask "echo $(printf 'a%.0s' $(seq 16400)) \\${nl}; git \$'\\x70'ush -f origin feat/x"
  expect_guard ask "git \$'\\x70'ush --force origin feat/x"
  expect_guard ask "git \$'pu\\163h' --force origin feat/x"
  # Octal một hai chữ số như bash (reviewer PR #60).
  expect_guard ask "git push \$'\\55\\55'force origin feat/x"
  expect_guard ask "rm -rf \$'\\57'"
  expect_guard ask "git \$'p'ush --force origin feat/x"
  # Bộ tách nhận nhầm '$' thường là mở $'…': \0 không được cắt phần còn lại, ký tự giải ra không được là dấu ngắt lệnh
  # (reviewer PR #60, bash thật chạy push --force và rm).
  expect_guard ask "echo '\$' \\0; r\$()m -rf /; echo ''"
  expect_guard ask "echo '\$' \\400; git pu\$()sh --force origin feat/x; echo ''"
  expect_guard ask "echo \"\$'\\0\" ; git pu\$()sh --force origin feat/x; echo \"'\""
  expect_guard ask "echo '\$'; git pu\$()sh \\73 --force origin feat/x; echo ''"
  expect_guard ask "echo '\$'; git pu\$()sh \\12 --force origin feat/x; echo ''"
  # Nhưng $'…' thật thì bash cắt ở \0, và ; xuống dòng & | giải ra ngắt lệnh trong bash -c, eval: giữ cả cách đọc đó.
  expect_guard ask "r\$'m\\0x' -rf /"
  expect_guard ask "git push \$'--force\\0x' origin feat/x"
  expect_guard ask "bash -c \$'echo\\x3brm -rf /'"
  expect_guard ask "eval \$'echo\\73rm -rf /'"
  expect_guard ask "bash -c \$'echo\\12rm -rf /'"
  expect_guard ask "bash -c \$'true\\x26\\x26rm -rf /'"
  expect_guard ask "bash -c \$'true\\174rm -rf /'"
  expect_guard ask "git pu\$()sh --force origin feat/x"
  expect_guard ask "git pu\`\`sh --force origin feat/x"
  expect_guard ask "git pu\${X}sh --force origin feat/x"
  expect_guard ask "git {push,} --force origin feat/x"
  expect_guard ask "r{m,} -rf ~"
  # 4.10 Luật: nhánh đầu rỗng hay ngoặc lồng, lệnh con hay biến có nội dung, dòng chỉ có \ trong chữ lệnh.
  expect_guard ask "git {,push} --force origin feat/x"
  expect_guard ask "git {{push,},} --force origin feat/x"
  expect_guard ask "git {{,push},} --force origin feat/x"
  expect_guard ask "rm -rf {,~}"
  expect_guard ask "git pu\`true\`sh --force origin feat/x"
  expect_guard ask "git pu\$(echo \$(true))sh --force origin feat/x"
  expect_guard ask "git pu\${X:-\${Y}}sh --force origin feat/x"
  expect_guard ask "git pu\$@sh --force origin feat/x"
  expect_guard ask "git pu\$9sh --force origin feat/x"
  expect_guard ask "git pu\$!sh --force origin feat/x"
  expect_guard ask "git pu\$X''sh --force origin feat/x"
  expect_guard ask "git pu\\${nl}\\${nl}sh --force origin feat/x"
  # Reviewer PR #64: dz2 chỉ bỏ biến dính sau chữ (`pu$X''sh`), không bỏ biến đầu đường dẫn (main không hỏi).
  expect_guard allow "rm -rf \"\$dir\"/*"
  expect_guard allow "rm -rf \$OUT/*"
  expect_guard allow "rm -rf \"\$TMP_DIR\"/*"
  expect_guard allow "rm -rf \"\$WORKDIR/\$name\""
  expect_guard ask "git pu\$X\$(true)sh --force origin feat/x"
  expect_guard ask "git pu\$X\`true\`sh --force origin feat/x"
  expect_guard ask "{cd,} '$on_main' && git push"
  expect_guard ask "bash -c 'cd '\\''$on_main'\\'' && git \"\$@\"' _ push"
  # 4.10, reviewer PR #60 (bash thật): cổng push với cd hay -C bị xé bằng \ nối dòng, mở rộng rỗng, ANSI-C; ngoặc nhọn ở
  # đối số của cd; thân -c dùng $0.
  expect_guard ask "c\\${nl}d '$on_main' && git push"
  expect_guard ask "c\$()d '$on_main' && git push"
  expect_guard ask "c\`\`d '$on_main' && git push"
  expect_guard ask "\$'\\x63'd '$on_main' && git push"
  expect_guard ask "git -\$'\\x43' '$on_main' push"
  expect_guard ask "git -\\${nl}C '$on_main' push"
  expect_guard ask "cd {'$on_main',} && git push"
  expect_guard ask "git -C {'$on_main',} push"
  expect_guard ask "bash -c 'cd '\\''$on_main'\\'' && git \"\$0\"' push"
  # Reviewer PR #62 (bash thật): cùng cơ chế nhưng lệnh lồng hay biến có nội dung (token bị cắt trước khi bỏ phần mở rộng),
  # tham số vị trí, dòng chỉ có \, $'…' không có \ hay có \u \U, ngoặc nhọn dạng dãy, eval bị xé.
  expect_guard ask "c\$(:)d '$on_main' && git push"
  expect_guard ask "c\$( )d '$on_main' && git push"
  expect_guard ask "c\`:\`d '$on_main' && git push"
  expect_guard ask "c\${X:-}d '$on_main' && git push"
  expect_guard ask "c\$@d '$on_main' && git push"
  expect_guard ask "c\\${nl}\\${nl}d '$on_main' && git push"
  expect_guard ask "git -\\${nl}\\${nl}C '$on_main' push"
  expect_guard ask "\$'c'd '$on_main' && git push"
  expect_guard ask "\$'\\U00000063'd '$on_main' && git push"
  expect_guard ask "git -\$'\\u0043' '$on_main' push"
  expect_guard ask "git -\$'C' '$on_main' push"
  expect_guard ask "c{d..d} '$on_main' && git push"
  expect_guard ask "git -{C..C} '$on_main' push"
  expect_guard ask "ev'a'l cd '$on_main' && git push"
  expect_guard ask "ev\$()al cd '$on_main' && git push"
  # Reviewer PR #62 lần 2: dấu mở trong nháy hay đã thoát ghép với dấu thật phía sau (thay trước khi tách token thì nuốt
  # token xé ở giữa), lệnh lồng, biến dính nháy hay \, dãy ngoặc nhọn có bước.
  expect_guard ask "echo '\`'; c\`\`d '$on_main' && git push"
  expect_guard ask "echo \\\`; c\`\`d '$on_main' && git push"
  expect_guard ask "echo '\`' && git -\`\`C '$on_main' push"
  expect_guard ask "echo '\${'; c\$'\\x64' '$on_main' && git push; echo '}'"
  expect_guard ask "echo '\$('; c\\${nl}d '$on_main' && git push; echo ')'"
  expect_guard ask "c\$(\$(true))d '$on_main' && git push"
  expect_guard ask "c\${X:-\${Y}}d '$on_main' && git push"
  expect_guard ask "git -\$(\$(:))C '$on_main' push"
  expect_guard ask "ev\$(\$(:))al cd '$on_main' && git push"
  expect_guard ask "c\`echo \\\`:\\\`\`d '$on_main' && git push"
  expect_guard ask "c\$X'd' '$on_main' && git push"
  expect_guard ask "c\$X\"d\" '$on_main' && git push"
  expect_guard ask "c\$X\\d '$on_main' && git push"
  expect_guard ask "git -\$X'C' '$on_main' push"
  expect_guard ask "c{d..d..1} '$on_main' && git push"
  expect_guard ask "git -{C..C..1} '$on_main' push"
  # Reviewer PR #62 lần 3: backtick trong nháy đơn ghép với backtick thật (cd`:` là cd), dấu xé mới sau dấu mở trong nháy,
  # $! (rỗng khi chưa có job nền), bước có dấu +, nháy đơn trong nháy kép hay trong comment không mở nháy.
  expect_guard ask "echo '\`'; cd\`:\` '$on_main' && git push"
  expect_guard ask "echo '\`'; cd\` \` '$on_main' && git push"
  expect_guard ask "echo '\`' && git -C\`:\` '$on_main' push"
  expect_guard ask "echo '\`' && git \`:\`-C '$on_main' push; echo '\`'"
  expect_guard ask "# don't use \`\`${nl}echo '\`'; cd\`:\` '$on_main' && git push"
  expect_guard ask "echo '\$('; c\$X'd' '$on_main' && git push; echo ')'"
  expect_guard ask "echo '\${'; c\$1d '$on_main' && git push; echo '}'"
  expect_guard ask "echo '\`'; git -\$X'C' '$on_main' push; echo '\`'"
  expect_guard ask "echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo '\`'; ev\`:\`al cd '$on_main' && git push"
  expect_guard ask "echo \"don't\"; c\`\`d '$on_main' && git push"
  expect_guard ask "c\$!d '$on_main' && git push"
  expect_guard ask "c{d..d..+1} '$on_main' && git push"
  # Reviewer PR #62 lần 4: lex đọc sai trạng thái sau <<<, <<, $'..' giả, nháy lồng trong $(..), # sau ), dấu phân cách
  # dài: phần sau bị bỏ, dạng xé mà bản không lex vẫn bắt thì lọt.
  expect_guard ask "cat <<< hi${nl}c\$(: x)d '$on_main' && git push"
  expect_guard ask "read -r a <<< \"\$HOME\"${nl}c\$(: x)d '$on_main' && git push"
  expect_guard ask "echo \$((1<<2))${nl}c\$(: x)d '$on_main' && git push"
  expect_guard ask "(( x = 1<<2 ))${nl}c\$(: x)d '$on_main' && git push"
  expect_guard ask "echo \\\$'\\'' x'; c\$(: x)d '$on_main' && git push"
  expect_guard ask "echo \$\$'\\'' x'; c\$(: x)d '$on_main' && git push"
  expect_guard ask "echo \\\$'\\'' x'; git \`:\`-C '$on_main' push"
  expect_guard ask "echo \"\$(echo \"it's\")\"${nl}c\$(: x)d '$on_main' && git push"
  expect_guard ask "echo \`echo '\`; c\$(: x)d '$on_main' && git push"
  expect_guard ask "(true)#it's${nl}c\$(: x)d '$on_main' && git push"
  expect_guard ask "echo \${x:- #}; c\$(: x)d '$on_main' && git push"
  expect_guard ask "git commit -m \"\$(cat <<'EOF'${nl}Fix 5\" display${nl}don't${nl}EOF${nl})\"${nl}c\$(: x)d '$on_main' && git push"
  long_delim=EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
  long_delim=$long_delim$long_delim$long_delim
  expect_guard ask "cat <<$long_delim${nl}x${nl}$long_delim${nl}c\$(: x)d '$on_main' && git push"
  # Reviewer PR #62 lần 5: bỏ backtick cuối không được xoá dấu xé của cd`/-C` (tên do lệnh con sinh ra); # sau ) của $(…)
  # không mở comment; (( của lệnh con lồng không giữ cờ số học qua dòng.
  expect_guard ask "\`echo cd\` '$on_main' && git push"
  expect_guard ask "\`printf cd\` '$on_main'${nl}git push"
  expect_guard ask "git \`echo -C\` '$on_main' push"
  expect_guard ask "echo \$[1<<2]${nl}echo '\`'; cd\` \` '$on_main' && git push"
  expect_guard ask "echo \$[1<<2]${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \"\$(case x in x) echo '\"' ;; esac)\"${nl}echo '\`'; cd\` \` '$on_main' && git push"
  expect_guard ask "echo \$(date)#x; echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \$(date)#x; echo '\`'; cd\`:\` '$on_main' && git push"
  expect_guard ask "((true); true)${nl}cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  # Reviewer PR #62 lần 6: cờ số học theo độ sâu ngoặc (không theo dòng), $[ tắt ở ]; cờ shell do lệnh con sinh ra.
  expect_guard ask "((1${nl}<<2))${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "x=\$((1${nl}<<2))${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \$[1]; cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask ": \$[1${nl}<<2]${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "((true); true); cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "bash \`echo -c\` 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "sh \`printf -- -c\` 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \`echo -c\` \$'\\x63d '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  # Reviewer PR #62 lần 7: (( trong ${…} không bật cờ số học; $[ theo độ sâu [ ]; cờ của shell trước lệnh con, nháy, nối dòng.
  expect_guard ask "echo \${x//((/y}${nl}cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \${x:-((}${nl}cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \$[a[1]<<2]${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask ": \$[a[0]<<1]${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "bash -e \`echo -c\` 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -o errexit \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \"\$(echo -c)\" 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \\${nl}\`echo -c\` 'cd '\\''$on_main'\\'' && git push'"
  # Reviewer PR #62 lần 8: $ thứ hai của $$ không mở ${ hay $[; [ và ${ trong $(…) không tính vào $[ hay ${ bên ngoài.
  expect_guard ask "echo \$\$[; [[ -n a ]]${nl}cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \$[ \$(: [; echo 1) ]${nl}cat <<EOF${nl}don't${nl}EOF${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \$\${; ((x=1<<2))${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "echo \$\${x; ((x=1<<2))${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  # Reviewer PR #63: cờ có nháy hay \ trước lệnh con chỉ khớp ở dạng bỏ nháy (dq); tên shell rồi $( chỉ thấy trong thân -c.
  expect_guard ask "bash '-e' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \"-e\" \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -e\"\" \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \\-e \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \$'-e' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -o 'errexit' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash '-o' errexit \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -o \"errexit\" \`echo -c\` 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -O 'extglob' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \\${nl}'-e' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c \"bash \\\$(echo -c) 'cd '\\\\''$on_main'\\\\'' && git push'\""
  # Reviewer PR #63 lần 2: cờ bị xé bởi $(…), ${…}, backtick, \ nối dòng, $'…', {a,} trước lệnh con lồng: main đọc dz nên hỏi.
  expect_guard ask "bash -e\$(true) \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -\\${nl}e \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -e\`\` \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -e\${X} \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \$'\\x2de' \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash {-e,} \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -e\$(:) \$( (echo -c) ) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -e\"\$(:)\" \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -o err\$()exit \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -O ext\${X}glob \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "gh pr create --title \"fix zsh\" --body \"\$(cat <<'EOF'${nl}body${nl}EOF${nl})\" && git push origin feat/x"
  # Reviewer PR #63 lần 3: cờ xé bởi cả nháy lẫn $(…), ${…}, \ nối dòng, $'…', {a,}: luật đọc dzq đã bỏ nháy như dq.
  expect_guard ask "bash -\"e\"\$() \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash '-o'\$() errexit \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -o \"err\"\$()exit \$( (echo -c) ) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \"-e\$()\" \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -\"e\"\${X:-} \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash \$'\\x2d'\"e\" \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -\\${nl}\"e\" \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash {\"-e\",} \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "sh -\"e\"\$() \$(echo \$(echo -c)) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c \"bash -\\\"e\\\"\\\$() \\\$(echo \\\$(echo -c)) 'cd '\\\\''$on_main'\\\\'' && git push'\""
  # Reviewer PR #63 lần 4: đường dẫn shell có khoảng trắng trong nháy, đối số --rcfile có nháy lẻ hay khoảng trắng: main đọc dx nên hỏi.
  expect_guard ask "\"/c/Program Files/Git/usr/bin/bash\" \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "\"C:/Program Files/Git/bin/bash.exe\" \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "'/opt/sp dir/bash' -e \`echo -c\` 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --rcfile '-x -y' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --init-file '- -' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --rcfile \\' \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --rcfile \"'\" \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --rcfile \\  \$(echo -c) 'cd '\\''$on_main'\\'' && git push'"
  # Reviewer PR #63 lần 5: ) trong ${…} trong $(…) làm bộ đọc đóng $( sớm hay muộn; bản đọc như main vẫn chạy (hợp hai đường).
  expect_guard ask "echo \$(echo \${x:-) #}; echo '\`'; c\`:\`d '$on_main' && git push)"
  expect_guard ask "echo \$[ \$(echo \${x:+(}1) << 2 ]${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  expect_guard ask "y=\$[ \$(echo \${x:+(}1) << 2 ]${nl}echo '\`'; c\`:\`d '$on_main' && git push"
  # Tên shell nằm trong chuỗi có nháy (tiêu đề PR, commit message) rồi tới cờ "$(…)": hỏi thừa có chủ ý, vì luật tên shell
  # đọc dx/dz (bỏ hết nháy) để không lọt các ca ở trên (docs/viec-can-lam.md 4.10).
  expect_guard ask "git push -u origin feat/x && gh pr create --title \"fix(guard): support zsh\" --body \"\$(cat <<'EOF'${nl}## Summary${nl}- x${nl}EOF${nl})\""
  expect_guard ask "git commit -m \"fix: support fish\" -m \"\$(cat <<'EOF'${nl}body${nl}EOF${nl})\" && git push origin feat/x"
  expect_guard ask "echo \"using zsh\" \"\$(git rev-parse HEAD)\" && git push origin feat/x"
  # Code inline trong commit message / thân PR kết thúc bằng cờ: không hỏi.
  expect_guard allow "git commit -m \"\$(cat <<'EOF'${nl}use \`mkdir -p\` here, \`ls -l\` too${nl}EOF${nl})\" && git push origin feat/x"
  expect_guard allow "git commit -F - <<'EOF'${nl}see \`bash -c\` and \`python -c\`${nl}EOF${nl}git push origin feat/x"
  expect_guard allow "gh pr create --draft --body \"\$(cat <<'EOF'${nl}Run \`exec bash\`, \`npm test --\`, \`run.sh -l\`.${nl}EOF${nl})\""
  expect_guard allow "git commit -m 'docs: mention \`bash\`' && git push origin feat/x"
  expect_guard allow "gh pr create --draft --body \"\$(cat <<'EOF'${nl}Run \`bash\` scripts, \`cd\` first.${nl}EOF${nl})\""
  expect_guard allow "echo \$HOME \"\$PWD\" && git push origin feat/x"
  expect_guard allow "git commit -m \"\$(cat <<'EOF'${nl}cd: fix${nl}EOF${nl})\" && git push origin feat/x"
  expect_guard allow "echo \"use \`command -v git\`\" && git push origin feat/x"
  TOOL=PowerShell expect_guard ask "git pu\`sh --force origin feat/x"
  TOOL=PowerShell expect_guard ask "r\`m -r -fo C:\\"
  expect_guard ask "git push origin \\+feat/x"
  expect_guard ask "git push origin \\:feat/x"
  expect_guard ask "rm -rf \\/*"
  # Reviewer vòng hai: `$` trước nháy làm mất một từ khoá ở dạng bỏ nháy (bù cho c'd'); nháy đã thoát làm sed ghép nhầm cặp.
  expect_guard ask "echo cd\$'x'; c'd' '$on_main' && git push"
  expect_guard ask "echo -C\$'y'; git -'C' '$on_main' push"
  expect_guard ask "printf %s cd\$\"x\"; c\\d '$on_main' && git push"
  expect_guard ask "echo \\';c'd' '$on_main' && git push"
  expect_guard ask "echo \\\";c\"d\" '$on_main' && git push"
  expect_guard ask "echo \\';n'pm' run deploy"
  expect_guard ask "echo \\';r'm' -rf /"
  expect_guard ask "echo \"it's\";r'm' -rf ~"
  # Reviewer vòng ba: token dừng ở `=` nên chỉ còn một nháy lẻ, và builtin/command bị xé.
  expect_guard ask "git --git-dir'='\"$on_main/.git\" push"
  expect_guard ask "git '--git-dir='\"$on_main/.git\" push"
  expect_guard ask "export GIT_DIR'='\"$on_main/.git\"; git push"
  expect_guard ask "export \"GIT_DIR=$on_main/.git\"; git push"
  expect_guard ask "env 'GIT_DIR=$on_main/.git' git push"
  expect_guard ask "buil'ti'n cd '$on_main' && git push"
  expect_guard ask "comm\\and cd '$on_main' && git push"
  # PowerShell tách token ở mọi khoảng trắng Unicode (nhóm Zs), coi nháy cong là nháy và en dash là dấu -: luật chạy grep ở
  # locale C (reviewer vòng bốn). Byte dựng bằng printf: bash 3.2 không có $'\u…'.
  em="$(printf '\342\200\203')" ideo="$(printf '\343\200\200')" lq="$(printf '\342\200\230')" rq="$(printf '\342\200\231')"
  ndash="$(printf '\342\200\223')"
  TOOL=PowerShell expect_guard ask "git push${em}--force origin feat/x"
  TOOL=PowerShell expect_guard ask "git push origin${ideo}+feat/x"
  TOOL=PowerShell expect_guard ask "git reset${em}--hard"
  TOOL=PowerShell expect_guard ask "npm${ideo}publish"
  TOOL=PowerShell expect_guard ask "git pu${lq}sh${rq} --force origin feat/x"
  TOOL=PowerShell expect_guard ask "Remove-Item ${ndash}Recurse C:\\"
  # Cổng push cũng đọc dạng đã đổi (reviewer vòng năm): thư mục sau khoảng trắng Unicode, trong nháy cong, sau en dash.
  nbsp="$(printf '\302\240')"
  TOOL=PowerShell expect_guard ask "git -C ${lq}$on_main${rq} push"
  TOOL=PowerShell expect_guard ask "Push-Location${ideo}'$on_main'; git push"
  TOOL=PowerShell expect_guard ask "Set-Location ${ndash}Path '$on_main'; git push"
  TOOL=PowerShell expect_guard ask "cd${nbsp}'$on_main'; git push"
  # Thân -c sau khoảng trắng mà glibc không xếp vào [[:space:]] (NBSP, U+202F, U+2007, U+0085; reviewer PR #86): grep SHC
  # trên dạng gốc không thấy `bash -c`, dạng đã đổi (un) dựng sau khi giải thân nên thân không được đọc, push lên main
  # được cho qua. PowerShell tách token ở các ký tự này.
  # U+3000 thì grep ở locale UTF-8 thấy, nhưng mode sed không giải \u3000 nên cũng lọt.
  for sp in "$nbsp" "$(printf '\342\200\257')" "$(printf '\342\200\207')" "$(printf '\302\205')" "$ideo"; do
    TOOL=PowerShell expect_guard ask "bash${sp}-c${sp}'git -C '\\''$on_main'\\'' pu'\\''sh'\\'''"
  done
  # Thư mục tên có en dash: dạng đổi sang ASCII trỏ tới `proj-x` (không có), nên dạng gốc phải khớp cd sau khoảng trắng
  # Unicode, ſ hay ı, kể cả khi grep của vòng cd chạy ở locale C cho nhanh (reviewer PR #74).
  # Chỉ grep ở locale UTF-8 mới coi U+3000 là [[:space:]] (main cũng chỉ hỏi khi đó): chạy ở locale UTF-8 đầu tiên mà
  # grep của máy khớp như vậy, không có thì bỏ qua. Bộ đọc sed không giải \uXXXX (input dựng bằng json.dumps) nên tên
  # thư mục còn nguyên chữ –: main cũng không đọc được, bỏ mode sed.
  pdx="$tmp/proj${ndash}x"
  [ -d "$pdx" ] || new_repo "$pdx" main
  ul=""
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 UTF-8; do
    n="$(printf '%s' "$ideo" | LC_ALL="$l" grep -c '[[:space:]]' 2>/dev/null)"
    [ "$n" = 1 ] && ul="$l" && break
  done
  if [ -n "$ul" ] && [ "$mode" != sed ]; then
    LC_ALL="$ul" TOOL=PowerShell expect_guard ask "Set-Location${ideo}'$pdx'; git push"
    LC_ALL="$ul" TOOL=PowerShell expect_guard ask "Push-Location${ideo}-Path${ideo}'$pdx'; git push"
    # Dạng dài hơn SHU_MAX có byte ≥ 0x80 thì grep SHC ở locale C (cho nhanh), U+3000 không còn là [[:space:]]: thân -c sau
    # khoảng trắng Unicode không đọc được, nên phải coi là chưa biết (push hỏi), không bỏ trong im lặng. Một `é` cộng đệm
    # ASCII: lệnh đi qua argv (bash_input), Windows báo "Argument list too long" với 17000 `é` (CI PR #86).
    LC_ALL="$ul" TOOL=PowerShell expect_guard ask "echo é $(printf 'a%.0s' $(seq 17000)); bash${ideo}-c${ideo}'git -C '\\''$on_main'\\'' pu'\\''sh'\\'''"
    # ſ, ı: chỉ khi grep -i của máy gập chúng thành s, i (GNU grep; main cũng chỉ hỏi khi đó).
    n="$(printf '\305\277\n\304\261\n' | LC_ALL="$ul" grep -ci '^[si]$' 2>/dev/null)"
    if [ "$n" = 2 ]; then
      LC_ALL="$ul" TOOL=PowerShell expect_guard ask "$(printf '\305\277')l '$pdx'; git push"
      LC_ALL="$ul" TOOL=PowerShell expect_guard ask "Set-Locat$(printf '\304\261')on '$pdx'; git push"
    fi
    LC_ALL="$ul" TOOL=Other expect_guard ask "Set-Location${ideo}'$pdx'; git push"
  fi
  # GNU grep ở locale UTF-8 gập ſ thành s: main hỏi, luật ở locale C thì không.
  expect_guard ask "git pu$(printf '\305\277')h -f"
  # Thân bash -c vô hại có đủ chữ p, u, s, h chiếm hết chỗ của các dạng: thân thật phía sau không được bỏ trong im lặng.
  c=""; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do c="${c}bash -c 'npm run build && ls dist/*.sh'; "; done
  expect_guard ask "${c}bash -c 'cd '\\''$on_main'\\'' && git push'"
  # PowerShell: \ là ký tự thường, "…\x\"m là …\x\m (reviewer của PR giải thân bash -c).
  TOOL=PowerShell expect_guard ask "Set-Location \"$tmp/x\\\"m; git push"
  TOOL=PowerShell expect_guard ask "git -C \"$tmp/x\\\"m push"
  # Giá trị trong nháy có từ hai dấu cách, hay từ ghép nhiều đoạn nháy (`"a b"/'x'`, `"a b/"x`): bash ghép thành một
  # đường; regex option của git và đối số của cd/-C/--git-dir phải vượt qua cả từ (mục 4.10 cũ của docs/viec-can-lam.md).
  expect_guard ask "git --git-dir=\"$sp2/.git\" push"
  expect_guard ask "git -c x.y=1 --git-dir=\"$sp2/.git\" push"
  expect_guard ask "git --git-dir \"$sp2\"/'.git' push"
  expect_guard ask "GIT_DIR=\"$sp2/.g\"it git push"
  expect_guard ask "git -C \"$sp2\"/ push"
  expect_guard ask "cd \"$tmp/sp ace plain/\"x && git push"
  expect_guard ask "cd -- '$tmp/sp ace plain/'x; git push"
  expect_guard ask "git --git-dir=\"$on_main/\".git push"
  expect_guard ask "cd \"$on_main\"/ && git push"
  # Nháy đóng của một chuỗi đứng trước cd/-C thật: cách đọc từ ghép không được nuốt cd/-C đó (reviewer của PR sửa
  # nháy giữa từ; cách đọc cũ vẫn chạy riêng).
  expect_guard ask "echo \"cd x\"; cd \"$on_main\" && git push; echo \"ok\""
  expect_guard ask "echo 'cd x'; cd \"$on_main\" && git push; echo 'ok'"
  expect_guard ask "printf 'cd sub\\n'; cd \"$on_main\" && git push origin HEAD; printf 'ok\\n'"
  expect_guard ask "echo \"git -C x\"; git -C \"$on_main\" push; echo \"y\""
  # Trong nháy kép, bash chỉ coi \ trước \ $ ` " là escape: đường Windows trong nháy kép đọc được, không hỏi thừa.
  expect_guard allow 'cd "C:\Users\me\proj" && git push origin feat/x'
  expect_guard allow 'git -C "C:\Users\me\proj" push origin feat/x'
  TOOL=PowerShell expect_guard allow 'cd "D:\a b"; git push origin feat/x'
  expect_guard allow "cd \"$work\" && git push origin HEAD"
  expect_guard allow "git -C \"$work\" push -u origin feat/x"
  # Trần CD_MAX (300) cd mỗi cách đọc (4.3): dưới trần vẫn đọc đúng thư mục, quá trần thì hỏi.
  cds="$(printf 'cd "a b"; %.0s' $(seq 299))"
  expect_guard allow "${cds}cd \"$work\" && git push origin HEAD"
  expect_guard ask "${cds}cd \"$on_main\" && git push origin HEAD"
  expect_guard ask "${cds}cd x; cd \"$work\" && git push origin HEAD"
  # Trần GC_MAX (git -C × thư mục cd) và SUB_MAX (subshell đọc nhánh): lệnh thường ngày dưới trần vẫn đọc đúng.
  gcs="$(printf 'git -C x status; %.0s' $(seq 100))"
  expect_guard allow "cd \"$work\"; ${gcs}git push origin HEAD"
  expect_guard ask "cd \"$work\"; ${gcs}git -C \"$on_main\" push origin HEAD"
  ups="$(printf 'cd ..; %.0s' $(seq 20))"
  expect_guard allow "${ups}cd \"$work\" && git push origin HEAD"
  expect_guard ask "${ups}cd \"$on_main\" && git push origin HEAD"
  # Nhiều cách viết cùng về một thư mục thật (299 `cd ..` qua gốc): guard chạy git một lần cho mỗi thư mục thật, không phải
  # cho mỗi cách viết. Trước đây mỗi đường có `..` tốn hai subshell chạy git, tới SUB_MAX (64) mới thôi: ~10 giây trên Git
  # Bash, ca long-manydotdot của test-install đỏ chập chờn trên Windows. git giả ghi lại mỗi lần đọc nhánh.
  if [ ! -x "$tmp/gitlog/git" ]; then
    mkdir -p "$tmp/gitlog"
    printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$tmp/gitlog.txt" "$(command -v git)" > "$tmp/gitlog/git"
    chmod +x "$tmp/gitlog/git"
  fi
  : > "$tmp/gitlog.txt"
  dd="$(printf 'cd ..; %.0s' $(seq 299))"
  out="$(bash_input "${dd}cd \"$on_main\" && git push origin HEAD" "$work" |
    PATH="$tmp/gitlog:$PATH" KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh")"
  nrev="$(grep -c 'rev-parse --abbrev-ref' "$tmp/gitlog.txt")"
  depth="$(cd "$work" && pwd -P | awk -F/ '{ print NF }')"
  assert "guard chỉ được đọc nhánh mỗi thư mục thật một lần [$mode]: 299 cd .. rồi cd nhánh chính → $nrev lần (sâu $depth)" \
    [ "$nrev" -ge 1 ] && [ "$nrev" -le $((depth + 2)) ]
  case "$out" in
    *'nhánh main'*) ok ;;
    *) bad "guard phải hỏi vì nhánh main [$mode], không vì trần số thư mục: 299 cd .. rồi cd nhánh chính → $out" ;;
  esac
  # Monorepo (reviewer PR #55): cd packages/p1 rồi cd ../p2 … ../p40, mỗi đường có `..` khác chữ nhau nhưng là 40 thư mục
  # thật: dưới SUB_MAX nên đọc đủ, không hỏi thừa; cuối cùng cd vào repo ở nhánh chính thì phải hỏi.
  mono="$tmp/mono"
  [ -d "$mono/packages/p40" ] || { new_repo "$mono" feat/x && for i in $(seq 40); do mkdir -p "$mono/packages/p$i"; done; }
  mc="cd packages/p1 && make"
  for i in $(seq 2 40); do mc="$mc && cd ../p$i && make"; done
  expect_guard allow "$mc && git push origin HEAD" "$mono"
  expect_guard ask "$mc && cd \"$on_main\" && git push origin HEAD" "$mono"
  # Quá nhiều thư mục cần đọc (DIR_MAX) thì hỏi, không cd từng cái: 600 `git -C xN/..` sau một cd.
  gx="$(for i in $(seq 600); do printf 'git -C x%s/.. status; ' "$i"; done)"
  expect_guard ask "cd \"$work\"; ${gx}git push origin HEAD"
  case "$(bash_input "cd \"$work\"; ${gx}git push origin HEAD" "$work" | KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh")" in
    *'hơn 512 đường'*) ok ;;
    *) bad "guard phải hỏi vì trần DIR_MAX [$mode]: 600 git -C xN/.." ;;
  esac
  # Đường thật có xuống dòng (qua symlink, reviewer PR #68): pwd -P in ra hai dòng, vòng đọc theo dòng cắt đôi đường và
  # repo ở nhánh chính không được đọc. Hệ không tạo được tên có xuống dòng (Windows) thì bỏ qua.
  if [ ! -e "$tmp/nl" ] && mkdir -p "$tmp/a$nl/b" 2>/dev/null && ln -s "$tmp/a$nl/b" "$tmp/nl" 2>/dev/null; then
    new_repo "$tmp/a$nl/b" main
  fi
  if [ -L "$tmp/nl" ] && [ -d "$tmp/a$nl/b/.git" ]; then
    expect_guard ask "cd \"$tmp/nl\" && git push origin HEAD"
  fi
  # cwd dạng C:/… (Python của Windows nhận đường POSIX đã được Git Bash đổi): cd vào thư mục chưa có vẫn phải bỏ qua, không
  # tốn subshell (299 cd từng chạm SUB_MAX và hỏi thừa trên Windows). Hệ không tạo được thư mục tên `C:` thì bỏ qua ca này.
  # Trên Git Bash, `C:/w` là ổ C dù tạo được thư mục tên `C:`: chỉ chạy khi `C:/w` tính từ $tmp đúng là repo vừa tạo.
  mkdir -p "$tmp/C:" 2>/dev/null && { [ -d "$tmp/C:/w" ] || new_repo "$tmp/C:/w" feat/x; }
  if (cd "$tmp" 2>/dev/null && [ -d C:/w/.git ] && [ "$(git -C C:/w rev-parse --abbrev-ref HEAD 2>/dev/null)" = feat/x ]); then
    out="$(cd "$tmp" && bash_input "${cds}cd \"C:/w\" && git push origin HEAD" "C:/w" | KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh")"
    case "$out" in
      *'"ask"'*) bad "guard không được hỏi [$mode]: 299 cd với cwd dạng C:/ → $out" ;;
      *) ok ;;
    esac
    # Chiều ngược (reviewer PR #55): C:/m có thật và ở nhánh chính thì vẫn phải hỏi.
    [ -d "$tmp/C:/m" ] || new_repo "$tmp/C:/m" main
    out="$(cd "$tmp" && bash_input "${cds}cd \"C:/m\" && git push origin HEAD" "C:/w" | KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh")"
    case "$out" in
      *'"ask"'*) ok ;;
      *) bad "guard phải hỏi [$mode]: 299 cd rồi cd C:/m (nhánh chính) với cwd dạng C:/ → $out" ;;
    esac
  fi
  # cd ở đầu lệnh kiểu khác, cd có option, --git-dir/--work-tree/GIT_DIR, đích chưa xác định.
  expect_guard ask "bash -c 'cd \"$on_main\" && git push'"
  expect_guard ask "{ cd \"$on_main\" && git push; }"
  expect_guard ask "if cd \"$on_main\"; then git push; fi"
  expect_guard ask "cd -- \"$on_main\" && git push"
  expect_guard ask "cd -P \"$on_main\" && git push"
  expect_guard ask "$(printf 'cd %s && git push' "${on_main// /\\ }")"
  expect_guard ask "git --git-dir=\"$on_main/.git\" --work-tree=\"$on_main\" push"
  expect_guard ask "git --git-dir \"$on_main/.git\" push"
  expect_guard ask "GIT_DIR=\"$on_main/.git\" git push"
  expect_guard ask "env --chdir=\"$on_main\" git push"
  expect_guard ask "$(printf 'git -C %s push' "${on_main// /\\ }")"
  expect_guard ask "$(printf 'git -C %s push --force origin x' "${work// /\\ }")"
  # shellcheck disable=SC2016  # $X, `...` là chữ của lệnh được xét
  expect_guard ask 'X=/somewhere; cd $X && git push'
  # shellcheck disable=SC2016
  expect_guard ask 'cd `cat /tmp/dir` && git push'
  # shellcheck disable=SC2016
  expect_guard ask 'git -C "$REPO" push'
  TOOL=PowerShell expect_guard ask "Set-Location -Path:\"$on_main\"; git push"
  TOOL=PowerShell expect_guard ask "Set-Location -PassThru \"$on_main\"; git push"
  # PowerShell không escape bằng \: C:\x\; và C:\x\ push là đường dẫn rồi tới lệnh khác.
  TOOL=PowerShell expect_guard ask "Set-Location $bsm; git push"
  TOOL=PowerShell expect_guard ask "cd $bsm ; git push"
  TOOL=PowerShell expect_guard ask "cd $bsm&& git push"
  TOOL=PowerShell expect_guard ask "git -C $bsm push"
  TOOL=PowerShell expect_guard ask "git -C $bsm push origin HEAD"
  TOOL=Unknown expect_guard ask "Set-Location $bsm; git push"
  TOOL=PowerShell expect_guard ask 'git -C \ push -f'
  expect_guard allow "cd -- \"$work\" && git push"
  expect_guard allow "bash -c 'cd \"$work\" && git push'"
  # Biến quen thuộc thì biết thư mục: $PWD là thư mục của phiên, $CLAUDE_PROJECT_DIR có trong môi trường hook.
  # shellcheck disable=SC2016
  expect_guard allow 'git -C "$PWD" push'
  # shellcheck disable=SC2016
  CLAUDE_PROJECT_DIR="$work" expect_guard allow 'cd "$CLAUDE_PROJECT_DIR" && git push'
  # shellcheck disable=SC2016
  CLAUDE_PROJECT_DIR="$on_main" expect_guard ask 'cd "$CLAUDE_PROJECT_DIR" && git push'
  # \\ cuối dòng là dấu \ thật, không phải dấu nối; PowerShell lồng trong Bash vẫn nối bằng `.
  expect_guard ask $'echo \\\\\nrm -rf \\\n  ~'
  expect_guard ask $'echo \\\\\nnpm \\\n run deploy'
  expect_guard ask $'pwsh -c \'Remove-Item -Recurse -Force `\n C:\\\''
  # Không rõ tool: so trên mọi dạng, thà hỏi thừa.
  TOOL=Unknown expect_guard ask $'Remove-Item -Recurse -Force \\\nWrite-Host done'
  TOOL=Unknown expect_guard ask $'Set-Location C:\\\nRemove-Item -Recurse -Force *'
  TOOL=Unknown expect_guard ask $'Remove-Item -Recurse -Force `\n  C:\\'
  # Thân -c nhiều dòng (grep đọc từng dòng nên không giải được) và shell là biến (mục 4.11 cũ của docs/viec-can-lam.md).
  expect_guard ask "bash -c 'true$nl cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c 'echo a'\\''b$nl cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "sh -c \"true$nl git -C '$on_main' push\""
  # shellcheck disable=SC2016
  expect_guard ask '$SHELL -c '"'cd '\\''$on_main'\\'' && git push'"
  # shellcheck disable=SC2016
  expect_guard ask '"$SHELL" -c '"\"cd '$on_main' && git push\""
  # shellcheck disable=SC2016
  expect_guard ask '${SHELL} -lc '"'git -C '\\''$on_main'\\'' push'"
  # shellcheck disable=SC2016
  expect_guard ask '${SHELL:-bash} -c '"'cd '\\''$on_main'\\'' && git push'"
  # Thân -c lấy từ biến hay lệnh lồng: guard không biết thân, lệnh có chữ push thì thư mục của push là chưa biết (4.11).
  expect_guard ask "X='cd \"$on_main\" && git push'; bash -c \"\$X\""
  expect_guard ask "X='cd \"$on_main\" && git push'; bash -c \$X"
  expect_guard ask "X='cd \"$on_main\" && git push'; sh -c \"\${X}\""
  expect_guard ask "bash -c \"\$(printf 'cd %s && git push' \"$on_main\")\""
  expect_guard ask "bash -c \"\`printf 'cd %s && git push' \"$on_main\"\`\""
  # shellcheck disable=SC2016
  expect_guard allow 'X=ls; bash -c "$X"'
  # Shell có option kèm đối số, option sau -c, tên ngoài danh sách cũ, tên từ lệnh lồng, thân ANSI-C (4.11).
  expect_guard ask "bash -O extglob -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash +O extglob -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash --rcfile /dev/null -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c -x 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c -o pipefail 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash.exe -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "sh.exe -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "ash -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "mksh -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash5 -c 'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "fish -c 'cd '\\''$on_main'\\'' && git push'"
  # shellcheck disable=SC2016
  expect_guard ask '$(command -v bash) -c '"'cd '\\''$on_main'\\'' && git push'"
  # shellcheck disable=SC2016
  expect_guard ask '`which bash` -c '"'cd '\\''$on_main'\\'' && git push'"
  expect_guard ask "bash -c \$'true\\ncd \\'$on_main\\' && git push'"
  # Thân là lệnh lồng chưa trong nháy: shell ngoài chạy $(…) trước, nên shell con bên trong phải được giải (reviewer PR #47).
  expect_guard ask "bash -c -x \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "bash -c -o pipefail \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "sh -c -e \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "fish -c \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "bash.exe -c \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "bash -O extglob -c \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "bash -c \$(bash -c 'cd '\\''$on_main'\\'' && git pu''sh')"
  expect_guard ask "bash -c -x \`bash -c 'git -C '\\''$on_main'\\'' push'\`"
  expect_guard allow "bash.exe -c 'echo hi'"
  expect_guard allow "bash -O extglob -c -x 'echo hi'"
  # Thân đóng trên cùng dòng thì vẫn đọc như cũ; shell là biến mà lệnh không có chữ push thì không hỏi.
  expect_guard allow "bash -c 'echo hi'$nl git push origin feat/x"
  # shellcheck disable=SC2016
  expect_guard allow '$SHELL -c "echo hi"'
done
# Lệnh dài hơn pipe buffer (64 KiB), phần nguy hiểm ở dòng đầu: grep -q thoát ở dòng khớp đầu
# tiên, printf còn ghi dở thì chết vì SIGPIPE, pipefail từng biến "khớp" thành "không khớp".
# Lệnh ~180 KiB, hơn hai lần pipe buffer: grep đọc một lần (tối đa 64 KiB) rồi thoát, printf chỉ
# kịp ghi thêm 64 KiB nữa, nên chắc chắn còn ghi dở. Dưới 128 KiB thì bỏ sót chỉ là may rủi.
# JSON dựng thẳng bằng printf vào file: lệnh dài quá giới hạn đối số (Windows ~32K ký tự).
# long_input <dòng đầu> <cwd> [cuối mỗi dòng, viết dạng JSON] [số dòng, mặc định 12000]: dòng đầu, rồi các dòng `echo line-N`.
long_input() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s' "$2" "$1"
  # shellcheck disable=SC2059  # phần cuối dòng ghép vào định dạng
  printf "${3:-}"'\\necho line-%s' $(seq "${4:-12000}")
  printf '","description":"test"}}\n'
}
long_input 'npm run deploy' "$work" > "$tmp/long-deploy.json"
long_input 'git push' "$on_main" > "$tmp/long-push.json"
# Mọi dòng kết thúc bằng \ nối dòng: guard nối dòng trên cả lệnh (bash 3.2 từng mất ~50 giây với lệnh 15 KB).
long_input 'npm run deploy' "$work" ' \\\\' > "$tmp/long-cont.json"
# Từ ghép nháy rất dài ngay sau cd (hay sau "cd nằm trong một chuỗi): cách đọc từ ghép đọc trọn cả từ ~188 KB và
# từng chép nó nhiều lần, 11 giây ở locale UTF-8 trong khi trước đó 0,4 giây (reviewer của PR sửa nháy giữa từ).
long_qinput() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s' "$2" "$1"
  printf 'a b %.0s' {1..47000}
  printf '\\" ; git push","description":"test"}}\n'
}
long_qinput 'cd x\"' "$on_main" > "$tmp/long-qcd.json"
# Rất nhiều cd (4.3 của docs/viec-can-lam.md), thư mục của phiên ở nhánh khác nên không có đường tắt: 1500 `cd "a b"` rồi
# cd tới repo ở main. Mỗi cd tương đối thành một thư mục khác chữ (không tồn tại), mỗi thư mục từng tốn một subshell (17 giây).
many_cd() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq "${2:-1500}"); do printf '%s' "$1"; done
  printf 'cd \\"%s\\" && git push","description":"test"}}\n' "$on_main"
}
many_cd 'cd \"a b\"; ' > "$tmp/long-manycd.json"
many_cd 'cd . && ls && ' > "$tmp/long-manydot.json"
# Thời gian mỗi cd là phần thông dịch bash (không fork), Git Bash chậm gấp đôi Linux: 1500 cd mất ~7 giây trên runner
# Windows, sát timeout khi máy bận (ca A của test-install đỏ chập chờn). 6000 cd có nháy, và cd xen kẽ hai thư mục.
many_cd 'cd \"a b\"; ' 6000 > "$tmp/long-manycd6k.json"
many_cd 'cd \"a b\"; cd \"/tmp/c d\"'"'x'"' && ' 2000 > "$tmp/long-manycdalt.json"
# Reviewer PR #55: mỗi `git -C` xét với mọi thư mục cd đã gom (299 × 250 × 4 cách đọc từng mất 16–19 giây trên Linux), và
# mỗi thư mục có `..` tốn subshell (299 `cd ..` 4,5 giây trên Linux, fork trên Git Bash đắt hơn nhiều).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq 299); do printf '%s' 'cd .; '; done
  printf 'cd \\"%s\\"; ' "$on_main"
  for _ in $(seq 250); do printf '%s' 'git -C x status; '; done
  printf 'git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-manygitc.json"
many_cd 'cd ..; ' 299 > "$tmp/long-manydotdot.json"
# Reviewer PR #75: `git -C '"q"'` (EO có nháy) đọc thêm EN cho mỗi lần ghép -C × thư mục; bash 3.2 nối mảng bậc hai, ~8200
# lần như vậy từng mất 11–12,7 giây (main 8–9 giây); chỉ bash 3.2 (CI macOS) đỏ: mỗi lần đọc thêm cũng tính vào GC_MAX.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq 8200); do printf '%s' "git -C '\\\"q\\\"' status; "; done
  printf 'cd \\"%s\\" && git push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-gitcq.json"
# Ngay dưới GC_MAX cũ: 5000 `git -C q status; ` (mỗi -C một lần ghép), rồi push lên main.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq 5000); do printf '%s' 'git -C q status; '; done
  printf 'cd \\"%s\\" && git push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-gitcexp.json"
# Công mỗi -C hay cd theo số đoạn nháy (reviewer PR #82): GCX_MAX và CD_MAX đếm số lần, mà unquote_word trên từ 60 đoạn
# tốn ~10 ms mỗi lượt với bash 3.2 ở UTF-8. 740 `git -C "a"'b'…(60 đoạn) status; ` rồi push lên main (145 KB) mất ~25 giây,
# 299 `cd "a"'b'…; ` rồi push ~10 giây, quá timeout nên lệnh chạy không hỏi. Ngân sách công UQW_MAX: quá thì hỏi.
seg60="$(for _ in $(seq 30); do printf '%s' '\"a\"'"'b'"; done)"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq 740); do printf 'git -C %s status; ' "$seg60"; done
  printf 'git -C \\"%s\\" push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-gitcuq.json"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq 299); do printf 'cd %s; ' "$seg60"; done
  printf 'git -C \\"%s\\" push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-cduq.json"
# Từ hơn 64 đoạn: unquote_word trả 1 ở đoạn thứ 65, expand_dir trả 1 và vòng `continue` mà không kiểm ngân sách (reviewer
# PR #83): 740 `git -C ("a"'b')×33 status; ` rồi push mất 6,9 giây với bash 5, 10,9 với bash 3.2, uqw gấp 4 lần UQW_MAX.
# Đã unknown thì chắc hỏi: thôi đọc. Kiểm riêng với trần 5 giây (bản sửa ~1,4 giây).
seg66="$(for _ in $(seq 33); do printf '%s' '\"a\"'"'b'"; done)"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  for _ in $(seq 740); do printf 'git -C %s status; ' "$seg66"; done
  printf 'git -C \\"%s\\" push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-gitcuq66.json"
# Reviewer PR #68: đọc lại theo thư mục thật cd tới mọi đường, mỗi thành phần một lần stat (-P và -L); một cd dài `a/..`
# (100 cặp: ~100000 thành phần mà tổng độ dài dưới BYTE_MAX) rồi 289 `cd ..` nối dồn (strace: gấp ~10 lần bản cũ, Git Bash stat đắt). Trần
# PART_MAX: hỏi trước khi cd. Chỉ một cd 300 cặp: phần gom thư mục (có từ trước) bậc hai theo độ dài, 3 cd 1000 cặp mất
# ~13,5 giây với bash 3.2 ở UTF-8 cả trên bản cũ (4.3 của docs/viec-can-lam.md).
mkdir -p "$tmp/dz/a"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$tmp/dz"
  printf 'cd %s; ' "$(printf 'a/..%.0s' $(seq 100))"
  for _ in $(seq 289); do printf '%s' 'cd ..; '; done
  printf 'cd \\"%s\\" && git push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-dotparts.json"
# Một cd có từ dài với nhiều `\ ` (4000 `a\ b/..`, 28 KB): expand_dir thay `\ ` bằng ${d//\\ / }, bash 3.2 ở UTF-8 mất
# ~22 giây (reviewer PR #69), quá timeout. Từ dài thì thay bằng awk.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd ' "$work"
  for _ in $(seq 4000); do printf '%s' 'a\\ b/..'; done
  printf '; cd \\"%s\\" && git push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-bscd.json"
# Một cd có từ trong nháy dài ~180 KB (26000 `a b/../` rồi `main repo`): ${d#\"} … bỏ nháy trên từ dài chậm bậc hai,
# 9,4 giây với bash 5 và 12,4 giây với bash 3.2 ở UTF-8 (reviewer PR #70), quá timeout. cd thật tới repo ở nhánh chính
# (có thư mục `a b`), nên phải hỏi kịp.
mkdir -p "$tmp/a b"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd \\"' "$tmp"
  for _ in $(seq 26000); do printf '%s' 'a b/../'; done
  printf 'main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-qword.json"
# Lệnh push dài ~490 KB (70000 `a b/../` trong nháy rồi `main repo`): mọi bước đã tuyến tính nhưng tổng vẫn ~14 giây với
# bash 3.2 ở UTF-8 (reviewer PR #71), quá timeout. Trần PUSH_CMD_MAX: lệnh có push dài hơn thì hỏi ngay. Nay trên RAW_MAX
# nên trần đó hỏi trước; đường PUSH_CMD_MAX đã có long-colon (ASCII) và long-qwordu (wc) phủ, dưới RAW_MAX.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd \\"' "$tmp"
  for _ in $(seq 70000); do printf '%s' 'a b/../'; done
  printf 'main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-qword490.json"
# Lệnh ~4 MB (`echo hello world; `×230000) rồi `git -C <repo ở main> push`: PUSH_CMD_MAX chỉ chặn phần sau cổng push,
# tiền xử lý (đọc JSON, các dạng nối dòng, rule grep) vẫn chạy trên cả lệnh: 2 MB mất 14,8 giây với bash 3.2 ở UTF-8,
# 4 MB 4,3–6 giây với bash 5, quá timeout thì push lên main chạy không hỏi (4.3). Trần RAW_MAX trên input thô, trước mọi
# bước đọc. Kiểm riêng với trần 3 giây (Git Bash đọc 4 MB chậm hơn). Sinh bằng awk: vòng printf của bash chậm trên Git Bash.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$tmp"
  awk 'BEGIN { for (i = 0; i < 230000; i++) printf "echo hello world; " }'
  printf 'git -C \\"%s\\" push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-raw4m.json"
# Lệnh ~300 KB không có hành động nguy (`echo hello world; `×17000): trên trần RAW_MAX thì hỏi luôn (hỏi thừa có chủ ý:
# không đọc kịp thì không biết lệnh có gì).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  awk 'BEGIN { for (i = 0; i < 17000; i++) printf "echo hello world; " }'
  printf 'true","description":"test"}}\n'
} > "$tmp/long-raw300k.json"
# Nhánh đếm byte của RAW_MAX (reviewer PR #85): 100000 `ệ` (3 byte) là ~100 K ký tự nhưng ~300 KB, ${#input} dưới trần
# mà số byte trên trần: phải hỏi qua wc.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo ' "$work"
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "\341\273\207" }'
  printf '","description":"test"}}\n'
} > "$tmp/long-raw300ku.json"
# `bash -o ` lặp 23000 lần (~184 KB) rồi cd vào repo ở main: mẫu thân -c (SHC) khớp chuỗi option `-o <chữ>` nối nhau rồi
# hỏng ở cuối, grep ở locale UTF-8 thử lại từ mọi vị trí (bậc hai, quá 40 giây; reviewer PR #62 lần 8). Locale C dùng DFA.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$tmp"
  for _ in $(seq 23000); do printf '%s' 'bash -o '; done
  printf '&& cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-basho.json"
# Như long-basho nhưng có một ký tự ngoài ASCII (`é ` ở đầu): dạng có byte ≥ 0x80 vẫn chạy grep SHC ở locale UTF-8 (để
# khớp khoảng trắng Unicode của PowerShell), bậc hai: 96 KB mất 17 giây với bash 5, quá timeout thì push lên main chạy
# không hỏi (reviewer PR #85).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"\303\251 ' "$tmp"
  for _ in $(seq 23000); do printf '%s' 'bash -o '; done
  printf '&& cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-bashou.json"
# Force-push sau `-c user.name="\"a b\""` chỉ dạng dq2 bắt được, và dq2 chỉ dựng khi $src không quá 65536 ký tự. Lệnh
# ~55 KB có en dash (dạng un khác lệnh gốc) và một thân bash -c ~7 KB: lần giải thân thứ hai trên un nối lại bản chép
# của thân vào $src, đẩy $src qua trần nên dq2 bị bỏ và lệnh được cho qua, trong khi main vẫn hỏi (reviewer PR #87).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"' "$work"
  awk 'BEGIN { for (i = 0; i < 48000; i++) printf "a" }'
  printf '\\"; echo x\342\200\223y; bash -c '"'"'echo '
  awk 'BEGIN { for (i = 0; i < 7000; i++) printf "x" }'
  printf ' push'"'"'; git -c user.name=\\"\\\\\\"a b\\\\\\"\\" \\"push\\" -f origin feat/x","description":"test"}}\n'
} > "$tmp/long-dq2un.json"
# Chuỗi nối dòng thường dài (5 đoạn × 165 dòng `x×90 \` và một dòng `$(true) \`) rồi `git -C "x y" pu``sh -f` ở dòng
# riêng (~77 KB): dz, dz2 chỉ có 5 dòng `$(true)` nên dzq dựng và hỏi; chép chuỗi gộp vào cùng $dzp thì $dzp quá trần
# 65536, dzq bị bỏ, push được cho qua (reviewer PR #89).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\\\\\n' "$work"
  awk 'BEGIN { x = sprintf("%90s", ""); gsub(/ /, "x", x)
    for (k = 0; k < 5; k++) { for (i = 0; i < 165; i++) printf "%s \\\\\\n", x; printf "$(true) \\\\\\n" } }'
  printf 'x\\ngit -C \\"x y\\" pu``sh -f origin feat/x","description":"test"}}\n'
} > "$tmp/long-dzcap.json"
# Cùng lớp với long-basho cho mẫu cd: tiền tố gán biến của CDA (`x= ` lặp 66000 lần, ~198 KB) khớp tới cuối rồi hỏng ở
# mọi vị trí; một cặp nháy làm lượt từ ghép chạy thêm, ~19 giây ở UTF-8.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$tmp"
  for _ in $(seq 66000); do printf '%s' 'x= '; done
  printf '&& cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-xassign.json"
# Nháy kép không đóng trên dòng của nó (`true \`⏎`cd "` + `a`×190000 + ⏎`"`) rồi cd vào repo ở main: mẫu cd ở locale UTF-8
# thử lại từ mọi `a` (bậc hai, ~27 giây với bash 5 trên main), quá timeout. Locale C: ~3 giây.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"true \\\\\\ncd \\"' "$tmp"
  for _ in $(seq 19000); do printf '%s' 'aaaaaaaaaa'; done
  printf '\\n\\" ; cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-uquote.json"
# Reviewer PR #76: một `\"` trong nháy kép làm vòng cd đọc thêm dạng che (lex_awk, dm = 1); hai ca trên kèm `echo "\""`
# từng quá 10 giây với bash 3.2 (main ~7 giây).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"\\\\\\"\\"; true \\\\\\ncd \\"' "$tmp"
  for _ in $(seq 18900); do printf '%s' 'aaaaaaaaaa'; done
  printf '\\n\\" ; cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-uquoteq.json"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"\\\\\\"\\"; true \\\\\\n' "$tmp"
  for _ in $(seq 65000); do printf '%s' 'x= '; done
  printf '&& cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-xassignq.json"
# Reviewer PR #76 lần 3: DQM_MAX đếm ký tự thì `ệ`×56000 (168 KB, 56000 ký tự) vẫn đi dạng che, grep ở locale UTF-8 bậc
# hai: ~10,7 giây với bash 3.2 (main ~7,8). Nay đếm cận byte (4 byte mỗi ký tự khi có ký tự ngoài ASCII).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"\\\\\\"\\"; true \\\\\\ncd \\"' "$tmp"
  for _ in $(seq 5600); do printf '\341\273\207\341\273\207\341\273\207\341\273\207\341\273\207\341\273\207\341\273\207\341\273\207\341\273\207\341\273\207'; done
  printf '\\n\\" ; cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-uquoteqe.json"
# Reviewer PR #76 lần 5: chi phí lượt che theo số cd chứ không theo byte: 230 `cd /nx" "…` (60 đoạn) sau `echo "\""`, chỉ
# 43 KB, từng quá 10 giây với bash 3.2 (main ~7,8). Lượt che có trần số cd riêng (DQM_CD), quá thì hỏi.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"\\\\\\"\\"; ' "$tmp"
  for _ in $(seq 230); do
    printf 'cd /nx'
    for _ in $(seq 60); do printf '\\" \\"'; done
    printf '; '
  done
  printf 'cd \\"main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-cddq.json"
# Phần gom thư mục nối mỗi cd vào đường trước (cur), tổng độ dài bậc hai theo số cd: 3 cd `a/..`×1000 rồi 289 `cd ..`
# là ~3,5 MB mỗi cách đọc, ~13,5 giây với bash 3.2 và 5 ở UTF-8 (verifier PR #68), quá timeout. Trần BYTE_MAX.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$tmp/dz"
  ap="$(printf 'a/..%.0s' $(seq 1000))"
  for _ in 1 2 3; do printf 'cd %s; ' "$ap"; done
  for _ in $(seq 289); do printf '%s' 'cd ..; '; done
  printf 'cd \\"%s\\" && git push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-dotchain.json"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd ' "$work"
  w4="$(for _ in $(seq 100); do printf '\341\273\207'; done)"
  for _ in 1 2 3 4; do printf '%s/../' "$w4"; done
  printf '; '
  for _ in $(seq 289); do printf '%s' 'cd ..; '; done
  printf 'cd \\"%s\\" && git push origin HEAD","description":"test"}}\n' "$on_main"
} > "$tmp/long-dotchain4.json"
# Thư mục tên có nháy kép (`"main repo"`) ở nhánh chính, không có `main repo` cạnh nó: resolve_dir bỏ nháy lần nữa trên
# đường đã đọc theo bash (unquote_word) nên đọc thành `main repo` (không có) và cho qua (verifier PR #71). Ba cách viết.
# NTFS không cho `"` trong tên: không tạo được thư mục thì bỏ ca (trên Windows lỗ này cũng không có).
qd="$tmp/qd"
if mkdir -p "$qd/\"main repo\"" 2>/dev/null && [ -d "$qd/\"main repo\"" ]; then
  new_repo "$qd/\"main repo\"" main
  # Cả `git -C <từ> push` (reviewer PR #73): regex push không hiểu `\"` trong nháy kép của giá trị option, và vòng -C bỏ
  # cách đọc theo bash khi nó trùng chữ cách đọc cũ (cách cũ còn bị bỏ nháy lần nữa trong resolve_dir).
  for t in 'cd %s && git push origin HEAD' 'git -C %s push origin HEAD' 'git -C %s \\"push\\" origin HEAD'; do
    for w in '\"\\\"main repo\\\"\"' "'\\\"main repo\\\"'" '\\\"main\\ repo\\\"'; do
      # shellcheck disable=SC2059  # t là mẫu lệnh có %s
      c="$(printf "$t" "$w")"
      printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s","description":"test"}}\n' "$qd" "$c" > "$tmp/qdname.json"
      for mode in $modes; do
        case "$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/qdname.json")" in
          *'"permissionDecision":"ask"'*) ok ;;
          *) bad "guard phải hỏi push tới thư mục tên có nháy kép ở nhánh main [$mode]: $c" ;;
        esac
      done
    done
  done
fi
# Nháy kép trong nháy đơn có \" (`echo 'cd "x\"'`) không được nuốt cd thật phía sau: đọc `\"` là escape chỉ ở lượt
# riêng (ARG_BSQE), lượt từ ghép cũ (ARG_BSQ đóng nháy ở `\"`) vẫn bắt `cd "<tmp>/a b"/../main\ repo` (reviewer PR #73).
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo '"'"'cd \\"x\\\\\\"'"'"'; cd \\"%s/a b\\"/../main\\\\ repo && git push origin HEAD","description":"test"}}\n' "$tmp" "$tmp" > "$tmp/qdswallow.json"
for mode in $modes; do
  case "$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/qdswallow.json")" in
    *'"permissionDecision":"ask"'*) ok ;;
    *) bad "guard phải hỏi: nháy kép có \\\" trong nháy đơn không được nuốt cd tới repo ở main [$mode]" ;;
  esac
done
# Bản đối xứng nháy kép (4.3): trong nháy kép `\"` không đóng nháy, nên `cd q` trong chuỗi `"x\" cd q"` không là lệnh; các
# lượt đọc (ARG_BSQ đóng nháy ở `\"`, ARG_BSQE ghép nhầm `"` thứ hai) đều nuốt cd thật phía sau vào từ `q"; cd "<tmp>/a`.
for t in 'main\\ repo' '\"main repo\"'; do
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"x\\\\\\" cd q\\"; cd \\"%s/a b\\"/../%s && git push origin HEAD","description":"test"}}\n' "$tmp" "$tmp" "$t" > "$tmp/qdswallow2.json"
  for mode in $modes; do
    case "$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/qdswallow2.json")" in
      *'"permissionDecision":"ask"'*) ok ;;
      *) bad "guard phải hỏi: chuỗi nháy kép có \\\" không được nuốt cd tới repo ở main [$mode]: $(cat "$tmp/qdswallow2.json")" ;;
    esac
  done
done
# Reviewer PR #76 lần 4: dạng che (awk với dm = 1) chạy cả khi đã chắc hỏi (thư mục của phiên ở main, quá PUSH_CMD_MAX),
# lệnh ~440 KB có `\"` ngoài nháy kép từng quá 10 giây với bash 3.2 (main ~7,7). awk bọc ghi lại lần chạy dạng che.
mkdir -p "$tmp/dmawk"
realawk="$(command -v awk)"
printf '#!/bin/sh\ncase "$*" in *"dm = 1"*) echo x >> "%s/dmawk.log" ;; esac\nexec "%s" "$@"\n' "$tmp" "$realawk" > "$tmp/dmawk/awk"
chmod +x "$tmp/dmawk/awk"
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\\\\\"x\\\\\\"; git push origin HEAD","description":"test"}}\n' "$on_main" > "$tmp/dmskip.json"
# Chỉ hỏi vì DQM_MAX khi dạng che thật sự che `\"` trong nháy kép: lex_awk còn đổi `$` trong nháy đơn, bỏ comment, nên
# `\"` ngoài nháy kép kèm `'$y'` trong lệnh dài trên nhánh feature từng bị hỏi thừa.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \\\\\\"x\\\\\\" '"'"'$y'"'"' ' "$work"
  for _ in $(seq 3500); do printf '%s' 'a a a a a a a a a a '; done
  printf '; git push origin feat/x # note","description":"test"}}\n'
} > "$tmp/dmnoask.json"
for mode in $modes; do
  rm -f "$tmp/dmawk.log"
  out="$(PATH="$tmp/dmawk:$PATH" KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/dmskip.json" 2>/dev/null)"
  case "$out" in
    *'"ask"'*) if [ -s "$tmp/dmawk.log" ]; then bad "guard không được chạy dạng che khi đã chắc hỏi [$mode]"; else ok; fi ;;
    *) bad "guard phải hỏi push ở repo nhánh main [$mode] → [$out]" ;;
  esac
  case "$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/dmnoask.json")" in
    *'"ask"'*) bad "guard hỏi thừa: \\\" ngoài nháy kép trong lệnh dài trên nhánh feature [$mode]" ;;
    *) ok ;;
  esac
done
# Từ cd dài hơn 4096 byte có nháy: lượt từ ghép và unquote_word bỏ vì "quá PATH_MAX, không cd được", nhưng cd -L rút
# `..` theo chữ trước khi chdir nên bash vẫn tới `main repo` (4.3 (2), reviewer PR #70). 700 `"a b"/../` (6,3 KB).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd ' "$tmp"
  for _ in $(seq 700); do printf '%s' '\"a b\"/../'; done
  printf 'main\\\\ repo && git push origin HEAD","description":"test"}}\n'
} > "$tmp/longword.json"
for mode in $modes; do
  case "$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/longword.json")" in
    *'"permissionDecision":"ask"'*) ok ;;
    *) bad "guard phải hỏi push sau cd qua từ có nháy dài hơn 4096 byte (cd -L vẫn tới nhánh main) [$mode]" ;;
  esac
done
# PUSH_CMD_MAX đếm byte, không đếm ký tự (reviewer PR #72): 9000 `ệệệệệệ ệ/../` là 108000 ký tự nhưng 234000 byte, việc
# phân tích tốn theo byte nên lệnh dạng này dài hơn (~550 KB) vượt timeout với bash 3.2 mà ${#raw} vẫn dưới trần.
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd \\"' "$tmp"
  e7="$(for _ in $(seq 6); do printf '\341\273\207'; done) $(printf '\341\273\207')/../"
  for _ in $(seq 9000); do printf '%s' "$e7"; done
  printf 'main repo\\" && git push origin HEAD","description":"test"}}\n'
} > "$tmp/long-qwordu.json"
# wc in số kèm ký tự lạ (wc.exe Windows in CRLF): `$((rawb))` lỗi cú pháp số học thì bash bỏ cả khối cổng push,
# guard không in gì và push lên main chạy không hỏi (reviewer PR #72). Lệnh 60000 ký tự có `ệ`, cwd trên main.
mkdir -p "$tmp/crwc"
printf '#!/bin/sh\nprintf '"'"'60032\\r\\n'"'"'\n' > "$tmp/crwc/wc"
chmod +x "$tmp/crwc/wc"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo \341\273\207' "$on_main"
  for _ in $(seq 600); do printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done
  printf ' && git push origin HEAD","description":"test"}}\n'
} > "$tmp/crwc.json"
for mode in $modes; do
  out="$(PATH="$tmp/crwc:$PATH" LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/crwc.json" 2>/dev/null)"
  case "$out" in
    *'"ask"'*) ok ;;
    *) bad "guard phải hỏi khi wc in số kèm \\r (push lên main) [$mode] → [$out]" ;;
  esac
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/long-qwordu.json")"
  case "$out" in
    *'push trong lệnh quá dài'*) ok ;;
    *) bad "guard phải đếm PUSH_CMD_MAX theo byte [$mode]: lệnh 108000 ký tự 3 byte → [$out]" ;;
  esac
  out="$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/long-dotparts.json" 2>&1)"
  case "$out" in
    *'hơn 60000 thành phần'*) ok ;;
    *) bad "guard phải hỏi vì trần PART_MAX trước khi cd tới hàng trăm nghìn thành phần [$mode] (cwd $tmp/dz) → [$out]" ;;
  esac
  # Lý do không được phụ thuộc chỗ nào làm ngân sách công vượt trước (CI macOS PR #84: cwd /var/folders/… thì bước kiểm
  # sau expand_dir vượt trước nb_add, lý do mất "thành phần"). Chạy lại với cwd dài thêm 1..40 ký tự (chỉ lượt auto).
  if [ "$mode" = auto ]; then
    pad=""
    dpok=1
    for _ in $(seq 40); do
      pad="${pad}d"
      mkdir -p "$tmp/dp/$pad/dz/a"
      out="$(sed "s|\"cwd\":\"[^\"]*\"|\"cwd\":\"$tmp/dp/$pad/dz\"|" "$tmp/long-dotparts.json" | "$hooks/guard-irreversible.sh" 2>&1)"
      case "$out" in
        *'hơn 60000 thành phần'*) ;;
        *) bad "guard phải hỏi vì trần PART_MAX với mọi độ dài cwd (cwd $tmp/dp/$pad/dz) → [$out]"; dpok=""; break ;;
      esac
    done
    [ -n "$dpok" ] && ok
  fi
  # BYTE_MAX đếm cận trên byte (reviewer PR #69): tên toàn ký tự 3 byte (ệ, U+1EC7): đếm ký tự thì dưới trần (đọc tới
  # nhánh main), đếm byte thì quá trần. Không dùng ký tự ngoài BMP (U+1D538): trên Git Bash guard
  # vẫn đọc tới nhánh main dù bash ở đó khớp mẫu ngoài ASCII (CI Windows PR #70), nguyên nhân chưa rõ (4.3).
  # LC_ALL=C.UTF-8: ở locale C bản đếm ký tự cũng đếm byte, ca này mất tác dụng (reviewer PR #70).
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/long-dotchain4.json")"
  # Lý do đúng của BYTE_MAX, không chỉ "nối dồn quá dài": từ PR #84 ngân sách UQW_MAX cũng ra chữ đó, bỏ phép nhân 4
  # trong nb_add vẫn hỏi qua ngân sách mà ca này không còn bắt được (reviewer PR #84).
  case "$out" in
    *'hơn 2000000 byte'*) ok ;;
    *) bad "guard phải đếm BYTE_MAX theo byte [$mode]: chuỗi cd nối dồn tên ký tự 3 byte → [$out]" ;;
  esac
  case "$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/long-dotchain.json")" in
    *'nối dồn quá dài'*) ok ;;
    *) bad "guard phải hỏi vì trần BYTE_MAX trước khi gom hết chuỗi cd nối dồn [$mode]" ;;
  esac
done
# Phép gán ~190 KB trước cd: last_arg chạy regex bậc hai theo độ dài từ không có dấu cách (reviewer 4.10).
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"x=' "$work"
  for _ in $(seq 1900); do printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done
  printf ' cd \\"%s\\" && git push","description":"test"}}\n' "$on_main"
} > "$tmp/long-assign.json"
# Mỗi dòng một $'…' gần 16 KB (dưới ngưỡng bỏ qua của từng dòng), 17 dòng: phép giải $'…' của dạng xé chữ đọc từng ký tự
# bằng length/substr, bậc hai theo độ dài, 278 KB mất 18 giây với bash 3.2 và awk BWK (main 1,3 giây; reviewer PR #60).
# Nay 15 và 12 dòng (~246 KB): dưới RAW_MAX, để ca vẫn đi qua phép giải thay vì bị trần hỏi trước (reviewer PR #85).
long_input 'npm run deploy' "$work" " \$'$(printf 'A%.0s' $(seq 16370))'" 15 > "$tmp/long-ansi.json"
long_input 'npm run deploy' "$work" " \$'$(printf '\\\\\\\\x41%.0s' $(seq 4090))'" 12 > "$tmp/long-ansiesc.json"
# Glob ba chữ *{*,*}* của case chạy bậc ba trên bash 3.2: 4000 `{,` (8 KB) mất 22 giây, here-doc CSV 190 KB sau
# awk '{…}' mất 6 giây (main 1 giây; reviewer PR #60). long-brace là ca canh glob dưới timeout 10 giây (bản bậc ba 18
# giây); long-csv chỉ canh thêm đường here-doc dài (bản bậc ba ~8–10 giây, dưới timeout; reviewer PR #85).
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo %s; git push --force origin x","description":"test"}}\n' \
  "$work" "$(printf '{,%.0s' $(seq 4000))" > "$tmp/long-brace.json"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"awk -F, '"'"'{print $1}'"'"' <<EOF' "$work"
  printf '\\na,b,c,d,%s' $(seq 17000) # dưới RAW_MAX (reviewer PR #85)
  printf '\\nEOF\\ngit push --force origin x","description":"test"}}\n'
} > "$tmp/long-csv.json"
# Reviewer PR #64: dòng mở ngoặc nhọn của dz2 phình theo tích (`{a,…×3000}{b,…×3000}` thành 9 triệu từ), và tìm biên từ
# bằng substr từng ký tự là bậc hai trên awk BWK (dòng JSON 60 KB có `{…,…}`, 2000 `{a,b}` liền nhau).
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo {%s}{%s}; git push --force origin x","description":"test"}}\n' \
  "$work" "$(printf 'a,%.0s' $(seq 3000))a" "$(printf 'b,%.0s' $(seq 3000))b" > "$tmp/long-braceprod.json"
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo %s; git push --force origin x","description":"test"}}\n' \
  "$work" "$(printf '{a,b}%.0s' $(seq 2000))" > "$tmp/long-bracewords.json"
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"curl -d '"'"'{\\"m\\":{\\"w\\":1,\\"h\\":2},\\"i\\":\\"%s\\"}'"'"' https://example.com; git push --force origin x","description":"test"}}\n' \
  "$work" "$(printf 'QUJD%.0s' $(seq 15000))" > "$tmp/long-bracejson.json"
# Reviewer PR #64 lần 2: trần từng dòng không đủ, 950 dòng ngắn mỗi dòng mở ra ~9 KB làm $cmd thành 7,5 MB, bash 3.2 quét
# lại ba lần quá 10 giây (main 1,8 giây). Đuôi force-push, và đuôi cd vào repo ở main rồi push.
bl="echo $(printf 'p%.0s' $(seq 30)){$(printf 'a,%.0s' $(seq 31))a}$(printf '{b,b,b,b,b,b,b,b}%.0s' $(seq 8))"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  printf "$bl"'\\n%.0s' $(seq 950)
  printf 'git push --force origin x","description":"test"}}\n'
} > "$tmp/long-bracelines.json"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  printf "$bl"'\\n%.0s' $(seq 843)
  printf 'cd \\"%s\\" \\u0026\\u0026 git push","description":"test"}}\n' "$on_main"
} > "$tmp/long-bracelinesm.json"
# Reviewer PR #64 lần 3: match(h, /[^[:space:]]*$/) bậc hai trên awk BWK và mawk (không neo được regex kết bằng $). 17 dòng
# `echo A×4059 {,}×8` (mỗi dòng 4096 ký tự) rồi `rm -rf ~`: 69 KB mà quá 10 giây (main 0,3 giây với mawk).
bq="echo $(printf 'A%.0s' $(seq 4059))$(printf ' {,}%.0s' $(seq 8))"
{
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"' "$work"
  printf "$bq"'\\n%.0s' $(seq 17)
  printf 'rm -rf ~","description":"test"}}\n'
} > "$tmp/long-bracepre.json"
# Như long-qcd và long-push nhưng thư mục của phiên ở nhánh khác: guard không hỏi ngay được, phải duyệt mọi cd tới repo ở main.
long_qinput "cd \\\"$on_main\\\"; cd x\\\"" "$work" > "$tmp/long-qcdw.json"
long_input "cd \\\"$on_main\\\" && git push" "$work" > "$tmp/long-pushw.json"
# Dòng nối rất dài có nháy và `:` sau git push: luật refspec `:` chậm bậc hai với grep -Ei ở locale UTF-8, và dạng bỏ nháy
# làm cmd dài gấp ba (reviewer của PR sửa nháy xé chữ: 253 KB mất 13,5 giây).
long_colon() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"cd \\"%s\\" && git push origin feat/x \\\\' "$work" "$on_main"
  printf "\\\\n'a'\\\\\"b\\\\\" line-%s \\\\\\\\" {1..11000}
  printf '\\nx:y","description":"test"}}\n'
}
long_colon > "$tmp/long-colon.json"
# Mỗi dòng có é, U+2003 và nháy cong, nối dòng bằng \: guard so thêm dạng đã đổi Unicode sang ASCII và hai dạng bỏ nháy.
u_e="$(printf '\303\251')" u_em="$(printf '\342\200\203')" u_lq="$(printf '\342\200\230')" u_rq="$(printf '\342\200\231')"
# Phần cuối dòng là định dạng của printf rồi thành chuỗi JSON: \\" là nháy kép, \\\\ là một dấu \ nối dòng.
long_input 'npm run deploy' "$work" " echo '$u_e' "'\\"x\\"'" a${u_em}b ${u_lq}c${u_rq} "'\\\\' 4000 > "$tmp/long-uni.json"
# Mọi dòng chỉ khớp luật cuối (gh pr merge): xét thứ tự luật trên cả các dòng khớp từng chậm gấp đôi main (reviewer vòng sáu).
long_input 'true' "$work" " echo '$u_e' a${u_em}b gh pr merge I "'\\\\' 4000 > "$tmp/long-ghm.json"
# Thân bash -c có pu…s… dài nhưng không có h: glob *[Pp]*[Uu]*[Ss]*[Hh]* chạy bậc bốn trên bash 3.2 (775 byte mất 17,7 giây
# trên /bin/bash của macOS; Linux không thấy). Chạy guard bằng /bin/bash ở job portable của macOS.
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"bash -c '"'"'echo %s%s'"'"'; git push --force origin x","description":"test"}}\n' \
  "$work" "$(printf 'pu%.0s' {1..180})" "$(printf 's%.0s' {1..180})" > "$tmp/long-pushc.json"
# Thân 40 KB toàn chữ p: regex không neo [Pp].*[Uu].*[Ss].*[Hh] của glibc thử lại từ mọi chữ p, bậc hai (11 giây; reviewer
# vòng bảy).
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"bash -c %s; git push --force origin x","description":"test"}}\n' \
  "$work" "$(printf 'p%.0s' $(seq 40000))" > "$tmp/long-pppp.json"
# Thân quá ngân sách (hỏi vì thư mục chưa biết), rồi `g\it -x` ×6000: dạng bỏ nháy thành `git -x git -x …`, grep cổng push ở
# locale UTF-8 chậm bậc hai trên dòng đó (11 giây; main 0,2 giây; reviewer vòng tám).
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"bash -c '"'"'echo push %s'"'"'; %s-xpush","description":"test"}}\n' \
  "$work" "$(printf 'a%.0s' $(seq 9000))" "$(printf 'g\\\\it -x %.0s' $(seq 6000))" > "$tmp/long-gitx.json"
long_qinput 'echo \"cd x' "$on_main" > "$tmp/long-qecho.json"
# 250 dòng `bash -c '<259 đoạn>' \` sau `npm run deploy \`: mỗi thân giải riêng thì dưới giới hạn, nhưng cộng lại (và
# lặp ở ba dạng nối dòng) từng mất 23 giây (reviewer của PR giải thân bash -c). Guard phải hỏi deploy kịp, cả khi
# thân có chữ push (thân được giải tới hết ngân sách).
long_shc() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"npm run deploy \\\\\\n' "$work"
  for _ in {1..250}; do
    printf "bash -c 'c"
    printf "'\\\\\\\\''c%.0s" {1..130}
    printf '%s' "$1"
    printf "' \\\\\\\\\\\\n"
  done
  printf 'true","description":"test"}}\n'
}
long_shc '' > "$tmp/long-shc.json"
long_shc ' push' > "$tmp/long-shcp.json"
# Claude Code dừng hook chạy quá timeout trong settings.json rồi cho lệnh chạy mà KHÔNG hỏi, nên guard
# chạy với đúng giới hạn đó (cần perl; không có thì không giới hạn). macOS từng mất hàng phút ở đây.
guard_timeout="$(awk '/guard-irreversible\.sh/ { f = 1 } f && match($0, /"timeout"[ \t]*:[ \t]*[0-9]+/) {
  t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); print t; exit }' "$root/.claude/settings.json" 2>/dev/null)"
guard_timeout="${guard_timeout:-10}"
# Dừng cả nhóm tiến trình: grep hay sed con còn chạy sẽ giữ stdout, $(...) phải đợi nó.
hook_limit() {
  command -v perl >/dev/null 2>&1 || { "$@"; return; }
  perl -e '$t = shift; $p = fork; defined $p or die "fork: $!";
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 142 };
    alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$guard_timeout" "$@"
}
# Fixture canh thời gian phải nằm dưới RAW_MAX, không thì trần hỏi trước và ca không còn đi qua đường code nó canh
# (reviewer PR #85: long-ansi, long-ansiesc, long-csv từng vượt). long-qword490 cố ý trên trần.
raw_max="$(awk -F= '/^RAW_MAX=/ { print $2; exit }' "$hooks/guard-irreversible.sh")"
for f in long-deploy long-push long-cont long-qcd long-qecho long-shc long-shcp long-qcdw long-pushw long-colon long-uni long-ghm long-pushc long-pppp long-gitx long-manycd long-manydot long-manycd6k long-manycdalt long-manygitc long-gitcq long-gitcexp long-gitcuq long-cduq long-manydotdot long-dotparts long-dotchain long-bscd long-qword long-basho long-bashou long-xassign long-uquote long-uquoteq long-xassignq long-uquoteqe long-cddq long-qwordu long-assign long-ansi long-ansiesc long-brace long-csv long-braceprod long-bracewords long-bracejson long-bracelines long-bracelinesm long-bracepre long-gitcuq66 long-dq2un long-dzcap; do
  sz="$(wc -c < "$tmp/$f.json" | tr -d ' \t\r')"
  assert "fixture $f ($sz byte) phải dưới RAW_MAX ($raw_max)" [ "$sz" -le "$raw_max" ]
done
for mode in $modes; do
  for f in long-deploy long-push long-cont long-qcd long-qecho long-shc long-shcp long-qcdw long-pushw long-colon long-uni long-ghm long-pushc long-pppp long-gitx long-manycd long-manydot long-manycd6k long-manycdalt long-manygitc long-gitcq long-gitcexp long-gitcuq long-cduq long-manydotdot long-dotparts long-dotchain long-bscd long-qword long-qword490 long-basho long-bashou long-xassign long-uquote long-uquoteq long-xassignq long-uquoteqe long-cddq long-qwordu long-assign long-ansi long-ansiesc long-brace long-csv long-braceprod long-bracewords long-bracejson long-bracelines long-bracelinesm long-bracepre; do
    # Locale UTF-8 (mặc định trên macOS và đa số Linux): phép cắt chuỗi của bash chậm hơn ở locale C nhiều lần.
    out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" hook_limit "$hooks/guard-irreversible.sh" < "$tmp/$f.json" 2>/dev/null)"
    case "$out" in
      *'"permissionDecision":"ask"'*) ok ;;
      *) bad "guard phải hỏi trong ${guard_timeout} giây [$mode]: lệnh dài hơn pipe buffer ($(wc -c < "$tmp/$f.json") byte, input: $(head -c 160 "$tmp/$f.json")...) → [$out]" ;;
    esac
  done
done
for mode in $modes; do
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" guard_timeout=5 hook_limit "$hooks/guard-irreversible.sh" < "$tmp/long-gitcuq66.json" 2>/dev/null)"
  case "$out" in
    *'"permissionDecision":"ask"'*) ok ;;
    *) bad "guard phải hỏi trong 5 giây [$mode]: 740 git -C có 66 đoạn nháy (từ quá 64 đoạn không được bỏ qua ngân sách) → [$out]" ;;
  esac
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" hook_limit "$hooks/guard-irreversible.sh" < "$tmp/long-dzcap.json" 2>/dev/null)"
  case "$out" in
    *'"permissionDecision":"ask"'*) ok ;;
    *) bad "guard phải hỏi [$mode]: chuỗi nối dòng ~77 KB rồi git -C có dấu cách và push xé bằng backtick (dzq không được bỏ vì chuỗi gộp) → [$out]" ;;
  esac
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" hook_limit "$hooks/guard-irreversible.sh" < "$tmp/long-dq2un.json" 2>/dev/null)"
  case "$out" in
    *'"permissionDecision":"ask"'*) ok ;;
    *) bad "guard phải hỏi [$mode]: lệnh ~55 KB có en dash và thân bash -c ~7 KB rồi force-push sau user.name có nháy thoát (dq2 không được bỏ vì thân giải lần hai) → [$out]" ;;
  esac
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" guard_timeout=3 hook_limit "$hooks/guard-irreversible.sh" < "$tmp/long-raw4m.json" 2>/dev/null)"
  case "$out" in
    *'lệnh quá dài để kiểm kịp'*) ok ;;
    *) bad "guard phải hỏi trong 3 giây vì RAW_MAX [$mode]: lệnh ~4 MB rồi git -C <repo ở main> push → [$out]" ;;
  esac
  out="$(KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/long-raw300k.json" 2>/dev/null)"
  case "$out" in
    *'lệnh quá dài để kiểm kịp'*) ok ;;
    *) bad "guard phải hỏi vì RAW_MAX [$mode]: lệnh ~300 KB → [$out]" ;;
  esac
  out="$(LC_ALL=C.UTF-8 KIT_JSON_TOOL="$mode" "$hooks/guard-irreversible.sh" < "$tmp/long-raw300ku.json" 2>/dev/null)"
  case "$out" in
    *'lệnh quá dài để kiểm kịp'*) ok ;;
    *) bad "guard phải đếm RAW_MAX theo byte [$mode]: 100000 ký tự 3 byte → [$out]" ;;
  esac
done
# Tiến trình cha bỏ qua SIGPIPE (trap '' PIPE, kế thừa sang con): printf không chết mà báo lỗi ghi
# ra stderr. Kết quả đã theo mã của grep, nên vẫn phải hỏi và stderr phải sạch.
for mode in $modes; do
  out="$( (trap '' PIPE; KIT_JSON_TOOL="$mode" hook_limit "$hooks/guard-irreversible.sh" < "$tmp/long-deploy.json") 2>"$tmp/sigpipe.err")"
  case "$out" in
    *'"permissionDecision":"ask"'*) ok ;;
    *) bad "guard phải hỏi [$mode] khi SIGPIPE bị bỏ qua: lệnh dài hơn pipe buffer → [$out]" ;;
  esac
  assert "guard không được in ra stderr [$mode] khi SIGPIPE bị bỏ qua → $(cat "$tmp/sigpipe.err")" [ ! -s "$tmp/sigpipe.err" ]
done
# Bash không tạo được file tạm (đĩa đầy, TMPDIR không ghi được): here-doc báo "cannot create temp
# file", vòng đọc nó không chạy lần nào, git push trên nhánh chính từng lọt qua im lặng. Bash < 5.1
# luôn ghi here-doc ra file tạm, bash ≥ 5.1 khi here-doc lớn hơn pipe buffer (64 KiB trên Linux)
# hoặc BASH_COMPAT=50 (nofile50).
# Giả lập bằng ulimit -f 0, bỏ qua SIGXFSZ để write báo EFBIG thay vì giết tiến trình. Không có
# ulimit -f (Git Bash) thì guard chạy như thường, ca vẫn phải đúng.
nofile() { (trap '' XFSZ; ulimit -f 0 2>/dev/null; "$@"); }
nofile50() { nofile env BASH_COMPAT=50 "$@"; }
# 30 lần cd vào thư mục con tên 200 ký tự: mỗi cd nối dài đường dẫn, danh sách thư mục ~94 KB.
long_cd="$(printf "cd $(printf '%0200d' 0) ; %.0s" {1..30})"
for mode in $modes; do
  RUN=nofile50 expect_guard ask "git push" "$on_main"
  RUN=nofile50 expect_guard ask "cd \"$on_main\" && git push"
  RUN=nofile50 expect_guard ask "git -C \"$on_main\" push"
  RUN=nofile expect_guard ask "${long_cd}git push" "$on_main"
  RUN=nofile50 expect_guard allow "cd \"$work\" && git push origin HEAD"
done
if [ -n "$py" ]; then
  # Windows: Python đọc stdin theo cp1252, chữ "Đ" từng làm hỏng việc đọc lệnh.
  out="$(bash_input 'git commit -m "Đổi tên" && git push origin' "$on_main" \
    | PYTHONIOENCODING=cp1252 KIT_JSON_TOOL=python "$hooks/guard-irreversible.sh")"
  case "$out" in *'"permissionDecision":"ask"'*) ok ;; *) bad "guard phải hỏi khi Python đọc stdin bằng cp1252" ;; esac
fi
mode=auto
# Thư mục của chính tiến trình hook (ở đây: repo đang ở main) không được xen vào việc xét push.
out="$(cd "$on_main" && bash_input "git push" "$work" | "$hooks/guard-irreversible.sh")"
assert "guard không được xét thư mục của tiến trình hook → $out" [ -z "$out" ]

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
  [ "$code" -eq 2 ] || { [ "$code" -eq 0 ] && text_grep "$out" -q '"decision": *"block"'; }
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
case "$out" in *"1/2)"*) ok ;; *) bad "stop-gate: lý do chặn phải ghi số lần chặn → $out" ;; esac
out="$(run_stop)"; code=$?
assert "stop-gate: lần chặn thứ 2 vẫn phải chặn (exit $code)" blocked
out="$(run_stop)"; code=$?
if [ "$code" -eq 0 ] && text_grep "$out" -q systemMessage; then ok; else bad "stop-gate: quá giới hạn thì nhả kèm systemMessage (exit $code)"; fi

# Bộ đếm phải về 0 khi không còn thay đổi: chặn 1 lần, bỏ thay đổi, rồi đỏ lại → bắt đầu từ 1.
run_stop >/dev/null
rm "$repo/app.js"
run_stop >/dev/null
echo "x" > "$repo/app.js"
out="$(run_stop)"; code=$?
case "$out" in *"1/2)"*) ok ;; *) bad "stop-gate: hết thay đổi thì bộ đếm phải về 0 → $out" ;; esac

touch "$repo/GREEN"
out="$(run_stop)"; code=$?
assert "stop-gate: check xanh thì cho dừng (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: check xanh thì không in gì" [ -z "$out" ]
rm "$repo/GREEN"

out="$(stop_input "$repo" | AGENT_STOP_GATE=off "$hooks/stop-gate.sh")"; code=$?
assert "stop-gate: AGENT_STOP_GATE=off phải cho dừng" [ "$code" -eq 0 ]

# cwd không tồn tại: dừng ngay, không đoán sang thư mục hiện tại (từng gây đệ quy vào check của repo kit).
out="$(stop_input "$tmp/khong-ton-tai" | AGENT_STOP_GATE_MAX=2 "$hooks/stop-gate.sh" 2>&1)"; code=$?
assert "stop-gate: cwd không tồn tại thì cho dừng (exit $code)" [ "$code" -eq 0 ]
assert "stop-gate: cwd không tồn tại thì không chạy check → $out" [ -z "$out" ]

# check.sh gọi lại stop gate trên chính repo đó: lần lồng phải bỏ qua, không đệ quy.
rec="$tmp/rec repo"
make_repo "$rec"
cat > "$rec/scripts/check.sh" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$rec/.count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$rec/.count"
if [ "\$n" -lt 5 ]; then
  printf '{"session_id":"rec-inner","cwd":"%s"}' "$rec" | "$hooks/stop-gate.sh" >/dev/null 2>&1
fi
exit 1
EOF
out="$(printf '{"session_id":"rec-%s","cwd":"%s"}' "$$" "$rec" | AGENT_STOP_GATE_MAX=9 "$hooks/stop-gate.sh" 2>/dev/null)"; code=$?
assert "stop-gate: check.sh gọi lại stop gate thì chỉ chạy check 1 lần → $(cat "$rec/.count")" [ "$(cat "$rec/.count")" = 1 ]
assert "stop-gate: lần ngoài vẫn phải chặn (exit $code)" blocked
# Biến chạy một phần của check.sh (KIT_CHECK_ONLY / KIT_CHECK_SKIP, chỉ cho job CI tách đôi) có trong môi trường của
# Claude Code (Claude chạy trong GitHub Action có CI=true) không được tới check.sh của Stop gate: gate luôn chạy đủ.
envr="$tmp/env repo"
make_repo "$envr"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ -z "${KIT_CHECK_ONLY:-}${KIT_CHECK_SKIP:-}" ]\n' > "$envr/scripts/check.sh"
out="$(stop_input "$envr" | CI=1 KIT_CHECK_SKIP=hooks KIT_CHECK_ONLY=kit AGENT_STOP_GATE_MAX=9 "$hooks/stop-gate.sh" 2>/dev/null)"
code=$?
assert "stop-gate: KIT_CHECK_ONLY/SKIP từ môi trường không được tới check.sh (exit $code) → $out" [ "$code" -eq 0 ]
assert "stop-gate: KIT_CHECK_ONLY/SKIP từ môi trường không được tới check.sh → $out" [ -z "$out" ]

session="test-$$-$RANDOM"
out="$(stop_input "$repo" | KIT_JSON_TOOL=sed AGENT_STOP_GATE_MAX=9 "$hooks/stop-gate.sh" 2>/dev/null)"; code=$?
assert "stop-gate: không có jq/Python thì chặn bằng exit 2 (exit $code)" [ "$code" -eq 2 ]

if [ -n "$py" ]; then
  # Máy không có jq (Windows): JSON chặn do Python in, phải parse được và giữ đủ lý do.
  session="test-$$-$RANDOM"
  out="$(stop_input "$repo" | KIT_JSON_TOOL=python AGENT_STOP_GATE_MAX=9 "$hooks/stop-gate.sh" 2>/dev/null)"; code=$?
  reason="$(printf '%s' "$out" | "$py" -c 'import json, sys; d = json.loads(sys.stdin.read()); sys.stdout.buffer.write((d["decision"] + "|" + d["reason"]).encode("utf-8"))' 2>/dev/null)"
  case "$reason" in "block|"*"lần chặn 1/9"*) ok ;; *) bad "stop-gate qua Python: JSON chặn phải parse được, có lý do → $out" ;; esac
fi

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

# Sàn số ca "phải hỏi": được thêm, không được bớt. Bớt ca để guard dễ dãi hơn phải là quyết định
# của người, sửa scripts/guard-ask-floor trong cùng thay đổi để người review thấy.
floor_file="$root/scripts/guard-ask-floor"
if [ -f "$floor_file" ]; then
  floor="$(tr -dc '0-9' < "$floor_file")"
  if [ "$ask_count" -lt "${floor:-0}" ]; then
    bad "số ca 'phải hỏi' giảm còn $ask_count, dưới sàn ${floor} trong scripts/guard-ask-floor"
  else
    ok
    [ "$ask_count" -gt "${floor:-0}" ] && printf '• guard: %s ca phải hỏi, có thể nâng scripts/guard-ask-floor lên %s\n' "$ask_count" "$ask_count"
  fi
fi

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
