#!/usr/bin/env bash
# Check riêng của repo Agents-Team-coding (install-kit.sh KHÔNG chép file này sang dự án khác):
# link trong tài liệu của kit + test của installer.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

status=0
docs=(README.md CLAUDE.md docs/*.md templates/*.md)
./scripts/validate-kit.sh "${docs[@]}" >/dev/null || status=1
./scripts/test-install.sh || status=1
exit "$status"
