# CLAUDE.md

Quy ước của đội agent nằm ở `.claude/rules/agent-team.md`. `install-kit.sh` cập nhật file đó mỗi lần cài lại. Quy ước riêng của dự án viết dưới dòng `<!-- agent-team:kit-end ... -->` của file đó, hoặc trong CLAUDE.md này.

## Dự án

<!-- TODO: một câu mô tả dự án (sản phẩm, stack chính). -->

## Lệnh

- `./scripts/check.sh` là THE check: kiểm tra bộ kit cộng với check của dự án (`scripts/check.local.sh`). Chạy trước khi báo xong.
- Commit nhỏ, có thứ tự, theo Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
<!-- TODO: lệnh chạy app local, lệnh chạy một test đơn lẻ. Dự án có quy ước commit khác thì sửa dòng trên. -->

## Quirk môi trường

<!-- TODO: điều agent dễ làm sai ở repo này (hệ điều hành, dịch vụ phải bật trước, biến môi trường bắt buộc). -->

## Quyền tự chủ

Mặc định theo dòng "Cứ làm / Luôn hỏi người" trong `.claude/rules/agent-team.md`. Dự án có việc được làm luôn hoặc phải hỏi người thì ghi thêm ở đây.

## Rule ↔ Thứ thực thi

Rule của kit nằm trong `.claude/rules/agent-team.md`, installer thay phần đó khi cập nhật kit. Rule riêng của dự án (ví dụ do `/correct` hay `gardener` thêm) ghi vào bảng này.

| Rule | Thực thi bởi |
|---|---|
