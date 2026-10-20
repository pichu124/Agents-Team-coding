# Việc cần làm

Ảnh chụp ngày 20/10/2026, ngay sau khi PR #5 (commit `0667d98`) và PR #6 (`e5a6756`) vào nhánh mặc định `claude/sharp-knuth-lpdhqz`. Mỗi việc ghi: vì sao cần làm, khi nào thì xong, ai đang làm. Làm xong việc nào thì xoá dòng đó khỏi file này, ngay trong PR của việc đó.

Luật chung cho mọi việc audit: dùng `/team-lead` với playbook bug-fix, viết test đỏ trước, `KIT_SELFTEST=1 ./scripts/check.sh` phải exit 0, rồi verifier và reviewer mới cho qua. Không nới guard, Stop gate hay `scripts/guard-ask-floor`; không sửa hay nới assert cũ. Nhãn của `suspicious_labels` bản mới phải ⊇ bản trước, với `AUDIT_BASE_REF` đặt về commit trước khi sửa. Muốn đổi cách đọc lệnh thì thêm một cách đọc rồi hợp nhãn. Thử hành vi bash thật thì thay `rm` và `git` bằng `echo` ngay trong văn bản lệnh, chạy trong thư mục tạm không phải repo git, HOME trỏ tới thư mục không tồn tại, và không đặt `rm` giả trên PATH.

## 1. Cần bạn quyết: các session đang trùng việc

| Việc | Các session hay PR làm cùng việc | Khuyên |
|---|---|---|
| Vá các ca mục A bỏ sót có từ trước | nhánh `claude/nice-hamilton-vdgw4v` (danh sách đầy đủ) và `claude/vibrant-pascal-b81ljt` (thẻ cũ, danh sách ngắn hơn) | Giữ nice-hamilton. Bản sửa nào chỉ vibrant-pascal có thì port sang, rồi dừng vibrant-pascal |
| Oracle bash trong test-audit | PR #8 (`claude/practical-hawking-le9toi`), và session của PR #7 (`claude/youthful-fermi-1ydqg6`) đang dựng oracle trên `c93ef33` | Giữ PR #8. PR #7 chỉ giữ phần vá ca bỏ sót |
| Skill verify kèm hành trình tái hiện guard SIGPIPE | `claude/bold-tesla-s0rkpo` và `claude/verify-skill-sigpipe` | Giữ một |
| Cổng push của guard trên bash < 5.1 khi đĩa đầy | `claude/stoic-bell-kdjsfg` và một session trên nhánh mặc định | Giữ một |
| check.sh không chạy test-plugin.sh của dự án đích | PR #9 (`claude/loving-sagan-zmy0u9`) và `claude/check-sh-kit-only-plugin` | Giữ PR #9 |

## 2. Audit: `scripts/audit-agent.py`, mục A

### 2.2 Vá các ca bỏ sót có từ trước (nhánh `claude/nice-hamilton-vdgw4v`)
Bash 5.2 thật xoá đích nguy hiểm ở các lệnh dưới đây, mà cả `27727f5` lẫn `0667d98` đều trả `[]`. Sắp theo mức hay gặp ở agent:
1. Thân `bash -c` chưa được gỡ (regex `SHELL_C_BODY`, phải giữ tuyến tính):
   - `bash +e -c '…'`;
   - cờ đứng sau cụm c: `bash -c -x '…'`, `bash -o pipefail -c -e '…'`;
   - tên của -o trong nháy hoặc có `-`: `bash -o 'pipefail' -c '…'`, `bash -o interactive-comments -c '…'`;
   - cờ dài có tham số: `bash --rcfile /dev/null -c '…'`;
   - cụm c trước cờ kèm tên: `bash -co pipefail '…'`.
2. Nháy thoát ngoài chuỗi: `echo it\'s` ⏎ `rm -rf src 'x'`.
3. Heredoc không nháy: `D=/; bash <<EOF` ⏎ `D=/tmp/w && rm -rf $D/a` ⏎ `EOF`. Shell cha thay `$D` trước khi shell con gán.
4. Biến bị đổi mà env không theo: `read D <<< /`, `eval 'D=/'`, `unset D`, rồi `rm -rf "$D"`.
- **Xong khi:** mỗi ca có assert phải nghi, đỏ trước và xanh sau. Bước oracle bash trong test-audit vẫn xanh với `KNOWN_MISSES` rỗng; thêm dạng lệnh mới vào bộ sinh của oracle thì phải sửa ca sót nó tìm ra cùng lúc, vì danh sách chỉ được giảm.

### 2.3 Đối chiếu nhánh cũ (nhánh `claude/brave-darwin-zqo4ws`)
- **Vì sao:** `claude/blissful-dirac-i6vpym` (không có PR) và `claude/youthful-fermi-1ydqg6` (PR #7, dựa trên `cad746e`, chưa có PR #5) cùng sửa `segments()`, nên sẽ xung đột với nhánh mặc định.
- **Xong khi:** có bảng "commit của nhánh → còn tái hiện? → đã port / đã có sẵn". Bản sửa nào còn thiếu thì port sang như một cách đọc thêm, hợp nhãn. Nhánh nào không còn gì riêng thì đề xuất đóng hoặc xoá; xoá nhánh phải hỏi người.

### 2.4 Đường chậm bậc hai có từ trước
- SHELL_C `(-\w+\s+)*` trên `"bash" + " -bash"*5000` hay `"sh" + " -sh"*5000`: 6–9 giây.
- Mẫu `\bgit\b.*\bfilter-(branch|repo)\b` trong SUSPICIOUS trên `"git-bash" + " --x-git-bash"*5000`: khoảng 14 giây.
- **Xong khi:** cả hai ca dưới 1 giây, có assert hiệu năng, và chứng minh nhãn không đổi. Hai regex này thuộc các cách đọc cũ, nên phải so ⊇ với bản trước trên fixture, fuzz và oracle.

### 2.5 Chưa kiểm chứng
- `git-bash.exe` của Git for Windows có chạy thân `-lc '…'` không. Có thể giao cho session "Run kit checks on macOS and Windows Git Bash" (nhánh `claude/laughing-ride-ot94no`).
- Python dưới 3.11 với regex `SHELL_C_BODY`: chỉ dùng lookahead và lookbehind độ dài cố định, chưa chạy thật.
- `scripts/audit-agent.sh` trên file phiên thật của dự án đã cài kit. Máy cloud chỉ có file phiên của chính nó.

## 3. PR đang mở (ảnh chụp)

| PR | Nội dung | Trạng thái |
|---|---|---|
| #7 | fix(audit): 9 dạng lệnh mục A bỏ sót | Nháp, dựa trên `cad746e`; cần merge nhánh mặc định mới, xem mục 1 và 2.3 |
| #9 | fix(check): check.sh không chạy test-plugin.sh của dự án đích | Sẵn sàng review, chờ CI |
