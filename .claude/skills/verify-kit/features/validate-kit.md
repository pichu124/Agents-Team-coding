# validate-kit: kiểm file của kit

`./scripts/validate-kit.sh` là phần "kit" của `./scripts/check.sh`, chạy ở mọi lượt Stop gate và trong CI. Nó chỉ kiểm file **của kit**: frontmatter của agent và skill, link nội bộ, hook đã đăng ký trong `.claude/settings.json` và có quyền chạy, cú pháp bash, shellcheck (nếu có), và lint `grep -q` nhận stdin từ pipe. Lỗi in dạng `✘ <file>:<dòng>: ...` ra stderr, exit 1. Hợp lệ thì in `✔ kit hợp lệ: ...`, exit 0. File riêng của dự án (skill, script, tài liệu) không bao giờ làm nó đỏ.

## Sub-features

- `frontmatter` agent và skill của kit có `name` đúng tên thư mục, có `description`, không có `<` `>`.
- `links` link nội bộ trong file markdown của kit (và các file truyền làm đối số) không gãy.
- `hooks` 3 hook của kit được đăng ký, tồn tại, có quyền chạy; matcher của guard khớp cả Bash và PowerShell.
- `pipe-quiet-grep` lint: file shell của kit có `| grep -q` (hoặc `-Eiq`, `--quiet`, `--silent`) thì đỏ, nêu `file:dòng` và cách sửa (`text_grep` của `lib.sh`, hoặc `[ -n "$(...)" ]`).
- `kit-only` ở repo đã cài, file trùng tên với file chỉ repo kit mới có (`scripts/test-install.sh`, `scripts/install-kit.sh`, `scripts/test-plugin.sh`, `plugin/run-hook.sh`) là của dự án, nên không bị kiểm.
- `kit-repo` ở repo kit, nó kiểm thêm skill `verify-kit` (frontmatter, link) và manifest plugin chỉ phát 4 skill của kit.

## How to get to it (user POV)

- Gõ `./scripts/validate-kit.sh` ở gốc repo, hoặc `./scripts/check.sh` (bước `kit`).
- Stop gate chạy `./scripts/check.sh` khi có thay đổi. CI chạy `./scripts/check.sh`.

## Driving it with shell + helpers/sandbox.sh

Preconditions:

- Đã `launch`, `doctor` xanh. Mọi bước chạy trong `$SBX/app` (repo đã cài), không chạy trong repo kit: ở repo kit, `scripts/test-install.sh` là file của kit và **bị** kiểm.

- **Nền xanh.** `(cd "$SBX/app" && ./scripts/validate-kit.sh); echo "exit $?"`. Kỳ vọng: `✔ kit hợp lệ: 5 agents, 4 skills, 3 hooks, ...`, `exit 0`.
- **pipe-quiet-grep (hành trình tái hiện 4, phần đỏ).** Sao lưu rồi chèn một dòng vi phạm vào hook của kit:
  `cp "$SBX/app/.claude/hooks/lib.sh" "$SBX/lib.sh.orig"`,
  `printf '%s\n' 'printf x | grep -q y' >> "$SBX/app/.claude/hooks/lib.sh"`,
  `wc -l < "$SBX/app/.claude/hooks/lib.sh"` (ghi lại số dòng N).
  Chạy `(cd "$SBX/app" && ./scripts/validate-kit.sh); echo "exit $?"`. Kỳ vọng: `exit 1`, stderr có đúng một dòng `✘ .claude/hooks/lib.sh:N: grep -q nhận stdin từ pipe, ...` với N là số vừa ghi, kèm `Dùng text_grep (lib.sh) hoặc [ -n "$(...)" ]`, và dòng cuối `✘ kit: 1 lỗi`.
  Khôi phục bằng `cp "$SBX/lib.sh.orig" "$SBX/app/.claude/hooks/lib.sh"`, chạy lại validate-kit. Kỳ vọng: `exit 0`.
- **kit-only (hành trình tái hiện 4, phần xanh).** Tạo file riêng của dự án có đúng mẫu đó:
  `printf '#!/usr/bin/env bash\nset -uo pipefail\nif printf x | grep -q x; then echo ok; fi\n' > "$SBX/app/scripts/test-install.sh"`.
  Chạy validate-kit trong `$SBX/app`. Kỳ vọng: `exit 0`, không có dòng nào nhắc `scripts/test-install.sh`. Dọn bằng `rm "$SBX/app/scripts/test-install.sh"`.
- **kit-repo.** Ở gốc repo kit: `./scripts/validate-kit.sh; echo "exit $?"`. Kỳ vọng: exit 0, số skill trong dòng `✔ kit hợp lệ:` là 5 (4 skill của kit và `verify-kit`).
- **Xác nhận.** Đọc lại bằng lệnh khác: `tail -n 1 "$SBX/app/.claude/hooks/lib.sh"` sau khi chèn (phải là dòng vi phạm) và sau khi khôi phục (phải khác dòng đó). `git -C "$SBX/app" status --porcelain` sau khi dọn phải rỗng.
- **Bằng chứng.** `artifacts/verify/validate-kit/`: `doctor.txt`, `red.txt` (stdout+stderr+exit của lần đỏ, kèm N), `restored.txt`, `project-own.txt`.

## Gotchas

- Lỗi gốc của lớp này (PR pichu124/Agents-Team-coding#6): `printf | grep -q` dưới pipefail đọc SIGPIPE (141) thành "không khớp". Lint bắt mẫu đó trong file shell của kit để nó không quay lại.
- Lint bỏ qua dòng comment (`# ... | grep -q ...`), `|| grep -q`, `grep -q` không có pipe, và pipe vào grep không quiet (`| grep -c`). Muốn thử phần đỏ thì dùng đúng `printf x | grep -q y`.
- Dòng vi phạm chèn vào cuối `lib.sh` vẫn chạy mỗi khi hook source `lib.sh`. Trong sandbox thì vô hại, nhưng phải khôi phục trước khi chạy hành trình khác (doctor sẽ đỏ nếu quên).
- Trong repo kit, `scripts/test-install.sh` có sẵn và là file của kit. Đừng chạy phần `kit-only` ở đó: nó sẽ đỏ đúng như thiết kế, nhưng không chứng minh gì về repo đã cài.
- Không có shellcheck thì validate-kit bỏ qua bước đó mà không báo. Lint `grep -q` và `bash -n` vẫn chạy.
