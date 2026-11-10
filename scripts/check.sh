#!/usr/bin/env bash
# "The check": MỘT lệnh duy nhất mà agent, Stop hook và CI cùng chạy.
#   1. Luôn chạy scripts/validate-kit.sh. Test hành vi của hook (scripts/test-hooks.sh, khá chậm
#      trên Windows) chỉ chạy khi file của kit thay đổi, khi CI=true, hoặc KIT_SELFTEST=1.
#   2. Có scripts/check.local.sh thì chạy nó: đây là định nghĩa check thật của dự án.
#   3. Không có thì dùng `make check` nếu Makefile có target `check`.
#   4. Không có nữa thì tự nhận diện Node / Python / Go / Rust và chạy các check tìm thấy.
# Exit khác 0 nếu có bất kỳ check nào đỏ.
# Chỉ trên CI (để tách một job dài thành các job song song): KIT_CHECK_ONLY hoặc KIT_CHECK_SKIP là danh sách tên bước
# (kit, hooks, audit, plugin, project) cách nhau bằng dấu phẩy. ONLY=x và SKIP=x cộng lại luôn đủ mọi bước. Ngoài CI,
# tên lạ hay đặt cả hai biến thì exit 2: agent và Stop gate luôn chạy đủ.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

failed=()
skipped=()
ran=0
project_checks=0

only="$(printf '%s' "${KIT_CHECK_ONLY:-}" | tr -d ' ')"
skip="$(printf '%s' "${KIT_CHECK_SKIP:-}" | tr -d ' ')"
# Chỉ áp cho lần check.sh này: bước con (test-install gọi lại check.sh trong repo tạm) không thấy hai biến.
unset KIT_CHECK_ONLY KIT_CHECK_SKIP
if [ -n "$only$skip" ]; then
  if [ -n "$only" ] && [ -n "$skip" ]; then
    printf '✘ check.sh: chỉ đặt một trong KIT_CHECK_ONLY và KIT_CHECK_SKIP\n' >&2
    exit 2
  fi
  if [ -z "${CI:-}" ]; then
    printf '✘ check.sh: KIT_CHECK_ONLY / KIT_CHECK_SKIP chỉ dùng trên CI (CI khác rỗng); ở máy thường check chạy đủ\n' >&2
    exit 2
  fi
  # Chỉ chữ thường và dấu phẩy, không trường rỗng: `,`, tab, glob (`p*`) không thành một lần chạy rỗng mà xanh.
  case "$only$skip" in
    *[!a-z,]* | ,* | *, | *,,*)
      printf '✘ check.sh: danh sách bước "%s" không hợp lệ (tên bước cách nhau bằng dấu phẩy)\n' "$only$skip" >&2
      exit 2
      ;;
  esac
  known=" kit hooks audit plugin project "
  for n in $(printf '%s' "$only$skip" | tr ',' ' '); do
    case "$known" in
      *" $n "*) ;;
      *)
        printf '✘ check.sh: bước lạ "%s" (có: kit, hooks, audit, plugin, project)\n' "$n" >&2
        exit 2
        ;;
    esac
  done
fi
selected() { # selected <bước>: bước có được chạy theo KIT_CHECK_ONLY / KIT_CHECK_SKIP không
  if [ -n "$only" ]; then
    case ",$only," in *",$1,"*) return 0 ;; esac
    return 1
  fi
  case ",$skip," in *",$1,"*) return 1 ;; esac
  return 0
}
pick() { # pick <bước>: như selected, bước bị bỏ thì in ra và ghi lại
  selected "$1" && return 0
  printf '\n• %s: bỏ qua (KIT_CHECK_ONLY / KIT_CHECK_SKIP)\n' "$1"
  skipped+=("$1")
  return 1
}

step() {
  local name="$1"
  shift
  ran=$((ran + 1))
  printf '\n▶ %s: %s\n' "$name" "$*"
  if "$@"; then
    printf '✔ %s\n' "$name"
  else
    printf '✘ %s (exit %s)\n' "$name" "$?"
    failed+=("$name")
  fi
}

project_step() {
  project_checks=$((project_checks + 1))
  step "$@"
}

missing() {
  printf '\n✘ %s\n' "$1"
  failed+=("$1")
}

tool() {
  if [ -x ".venv/bin/$1" ]; then
    printf '%s\n' ".venv/bin/$1"
  else
    command -v "$1"
  fi
}

node_checks() {
  local pm=npm
  if [ -f pnpm-lock.yaml ]; then pm=pnpm
  elif [ -f yarn.lock ]; then pm=yarn
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun
  fi
  if ! command -v "$pm" >/dev/null 2>&1; then
    missing "node: thiếu $pm"
    return
  fi
  if [ ! -d node_modules ]; then
    missing "node: chưa cài dependency (chạy '$pm install' trước)"
    return
  fi
  local s
  for s in lint typecheck type-check test; do
    if node -e 'process.exit(((require("./package.json").scripts) || {})[process.argv[1]] ? 0 : 1)' "$s" 2>/dev/null; then
      if [ "$s" = test ]; then
        project_step "node:$s" env CI=1 "$pm" run "$s"
      else
        project_step "node:$s" "$pm" run "$s"
      fi
    fi
  done
}

python_checks() {
  local t
  if t="$(tool ruff)"; then project_step "python:ruff" "$t" check .; fi
  if t="$(tool mypy)" && { [ -f mypy.ini ] || grep -qs '^\[tool\.mypy\]' pyproject.toml; }; then
    project_step "python:mypy" "$t" .
  fi
  if t="$(tool pytest)" && { [ -d tests ] || [ -d test ] || compgen -G "test_*.py" >/dev/null; }; then
    project_step "python:pytest" "$t" -q
  fi
}

go_checks() {
  if ! command -v go >/dev/null 2>&1; then
    missing "go: thiếu go"
    return
  fi
  project_step "go:vet" go vet ./...
  project_step "go:test" go test ./...
}

rust_checks() {
  if ! command -v cargo >/dev/null 2>&1; then
    missing "rust: thiếu cargo"
    return
  fi
  if cargo clippy --version >/dev/null 2>&1; then
    project_step "rust:clippy" cargo clippy --all-targets --quiet -- -D warnings
  fi
  project_step "rust:test" cargo test --quiet
}

if [ -x scripts/validate-kit.sh ] && pick kit; then
  step "kit" ./scripts/validate-kit.sh
fi
# Installer không chép bản plugin: ở repo đích, test-plugin.sh, plugin/, .claude-plugin/ là của dự án.
in_kit_repo() { [ -f .claude-plugin/plugin.json ] && [ -f plugin/run-hook.sh ]; }
kit_changed() {
  local paths=(.claude/hooks scripts/check.sh scripts/test-hooks.sh scripts/validate-kit.sh
    scripts/guard-ask-floor scripts/audit-agent.sh scripts/audit-agent.py scripts/test-audit.sh)
  in_kit_repo && paths+=(scripts/test-plugin.sh plugin/run-hook.sh plugin/hooks.json .claude-plugin)
  [ -n "$(git status --porcelain -- "${paths[@]}" 2>/dev/null)" ]
}
if [ -x scripts/test-hooks.sh ]; then
  if [ -n "${CI:-}" ] || [ "${KIT_SELFTEST:-0}" = 1 ] || kit_changed; then
    pick hooks && step "hooks" ./scripts/test-hooks.sh
    [ -x scripts/test-audit.sh ] && pick audit && step "audit" ./scripts/test-audit.sh
    in_kit_repo && [ -x scripts/test-plugin.sh ] && pick plugin && step "plugin" ./scripts/test-plugin.sh
  else
    printf '\n• hooks: bỏ qua test của kit vì hook không đổi (KIT_SELFTEST=1 để chạy)\n'
  fi
fi

if ! pick project; then
  :
elif [ -f scripts/check.local.sh ]; then
  project_step "project" bash scripts/check.local.sh
elif [ -f Makefile ] && grep -Eq '^check:' Makefile; then
  project_step "make check" make check
else
  [ -f package.json ] && node_checks
  { [ -f pyproject.toml ] || [ -f setup.cfg ] || [ -f requirements.txt ]; } && python_checks
  [ -f go.mod ] && go_checks
  [ -f Cargo.toml ] && rust_checks
fi

if [ "$project_checks" -eq 0 ] && [ "${#failed[@]}" -eq 0 ] && selected project; then
  printf '\n⚠ Chưa nhận diện được check nào của dự án. Hãy tạo scripts/check.local.sh (lint + typecheck + test nhanh).\n'
fi

part=""
[ "${#skipped[@]}" -gt 0 ] && part=" (một phần, bỏ qua: ${skipped[*]})"
# Chạy một phần mà không bước nào chạy (bước được chọn không có ở repo này, script của nó không chạy được) là đỏ.
if [ -n "$only$skip" ] && [ "$ran" -eq 0 ] && [ "${#failed[@]}" -eq 0 ]; then
  printf '\n✘ check.sh ĐỎ: chạy một phần mà không bước nào chạy%s\n' "$part"
  exit 1
fi
if [ "${#failed[@]}" -gt 0 ]; then
  printf '\n✘ check.sh ĐỎ: %s%s\n' "${failed[*]}" "$part"
  exit 1
fi
printf '\n✔ check.sh XANH%s\n' "$part"
