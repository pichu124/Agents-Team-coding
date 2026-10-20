# Feature map của kit

Mỗi file là một tính năng người dùng thấy được, theo mẫu 4 mục của [create-verify-skill](../../create-verify-skill/references/feature-template.md). Cách khởi động, doctor, thu bằng chứng và dọn dẹp nằm trong [SKILL.md](../SKILL.md).

| Tính năng | File | Bề mặt |
|---|---|---|
| Guard hỏi trước hành động không đảo ngược được | [guard-irreversible.md](guard-irreversible.md) | PreToolUse hook, JSON trên stdin |
| Stop gate: chưa được kết thúc lượt khi check đỏ | [stop-gate.md](stop-gate.md) | Stop hook, JSON trên stdin |
| validate-kit: kiểm file của kit, lint `grep -q` đọc từ pipe | [validate-kit.md](validate-kit.md) | `./scripts/validate-kit.sh` |
| Cài kit vào repo khác | [install-kit.md](install-kit.md) | `scripts/install-kit.sh <repo>` |

## Điều kiện nền

- bash 3.2+ (macOS, Git Bash trên Windows đều được), git, `seq`, `mktemp`. Có jq hoặc Python 3 để dựng JSON lớn. Có cả hai thì mới phủ đủ ba mode `auto` (jq), `python`, `sed` của guard.
- Repo kit sạch hoặc bạn biết rõ thay đổi đang thử. `doctor` in commit của kit và cảnh báo khi hooks/scripts có thay đổi chưa commit.
- Một sandbox mới cho mỗi lần kiểm chứng: `launch` → `doctor` → hành trình → `cleanup`.

## Quy ước điều khiển

- Gọi hook **đã cài** trong `$SBX/app` bằng stdin, đặt `CLAUDE_PROJECT_DIR`, giống lệnh trong `.claude/settings.json` mà Claude Code chạy. Không gọi hàm trong `lib.sh` trực tiếp.
- Lệnh dài dựng vào file (`$H big-input`), không truyền qua argv hay `--arg c "$(cat ...)"`.
- Kết quả "hỏi" là chuỗi `"permissionDecision":"ask"` trên stdout, exit 0. Kết quả "cho qua" là stdout rỗng, exit 0. Kiểm cả **lý do**: hỏi vì một mẫu khác với mẫu đang thử thì hành trình không chứng minh điều cần chứng minh.
- Hành trình xác suất (có chữ "tải" trong tên) chỉ là bằng chứng xác suất. Ghi số vòng, số bản và số CPU vào báo cáo.

## Tiêu chuẩn bằng chứng

- `artifacts/verify/<slug>/` có `doctor.txt` và output của từng bước, kèm exit code.
- Mỗi tiêu chí "Kỳ vọng" trong file tính năng được đối chiếu bằng con số hoặc chuỗi cụ thể (ví dụ `10/10`, `lib.sh:100`), không ghi "có vẻ ổn".
- Hành trình đỏ thì giữ nguyên sandbox để điều tra, ghi đường dẫn vào báo cáo, rồi mới cleanup.
- Không bao giờ làm yếu hành trình để nó pass (giảm số dòng, số lần, số bản, bỏ một mode). Thiếu điều kiện (không có Python, máy 1 CPU) thì kết luận INCONCLUSIVE cho phần đó và ghi lý do.
