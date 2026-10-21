# CLAUDE.md

Quy ước của đội agent nằm ở `.claude/rules/agent-team.md`. `install-kit.sh` cập nhật file đó mỗi lần cài lại. Quy ước riêng của dự án viết dưới dòng `<!-- agent-team:kit-end ... -->` của file đó, hoặc trong CLAUDE.md này.

## Dự án

<!-- TODO: một câu mô tả dự án (sản phẩm, stack chính). -->

## Lệnh

- `./scripts/check.sh` là THE check: kiểm tra bộ kit cộng với check của dự án (`scripts/check.local.sh`). Chạy trước khi báo xong.
<!-- TODO: lệnh chạy app local, lệnh chạy một test đơn lẻ. -->

## Quirk môi trường

<!-- TODO: điều agent dễ làm sai ở repo này (hệ điều hành, dịch vụ phải bật trước, biến môi trường bắt buộc). -->
