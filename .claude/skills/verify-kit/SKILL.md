---
name: verify-kit
description: Kiểm chứng bộ kit Agents-Team-coding trên bề mặt thật, tức một repo git mới đã cài kit bằng scripts/install-kit.sh. Hook nhận JSON trên stdin giống hệt Claude Code gửi, script chạy từ shell. Dùng khi verifier hoặc lead cần bằng chứng hành vi cho guard-irreversible, stop-gate, validate-kit hay install-kit. Chỉ có ở repo kit, installer không chép và plugin không phát skill này.
---

# Kiểm chứng kit Agents-Team-coding

Bề mặt người dùng chạm vào là **repo của họ sau khi cài kit**: Claude Code gọi `"$CLAUDE_PROJECT_DIR"/.claude/hooks/<hook>.sh` và đưa JSON của sự kiện vào stdin; người (hoặc agent) chạy `./scripts/check.sh`, `./scripts/validate-kit.sh`, `scripts/install-kit.sh` từ shell. Bản thân Claude Code là hệ thống bên ngoài: hành trình dừng ở hợp đồng stdin/stdout của hook, không mock gì bên trong kit.

Mọi lệnh dưới đây chạy từ gốc repo kit. Helper: `.claude/skills/verify-kit/helpers/sandbox.sh` (gọi là `H` bên dưới). Shell của agent không giữ biến giữa các lần gọi Bash, nên mỗi lệnh con nhận đường dẫn sandbox làm đối số. Giữ đường dẫn đó trong ghi chú, hoặc ghi ra file rồi đọc lại bằng `cat`.

## Launch

```bash
H=.claude/skills/verify-kit/helpers/sandbox.sh
SBX="$($H launch)"; echo "$SBX"
```

`launch` tạo thư mục mới bằng `mktemp -d` (theo `TMPDIR`), trong đó có:
- `app/`: repo git ở nhánh `feat/verify`, đã chạy `scripts/install-kit.sh` và commit bản cài.
- `on-main/`: repo git rỗng ở nhánh `main`, làm `cwd` cho ca push lên nhánh chính.
- `.verify-kit-sandbox`: dấu ghi đường dẫn repo kit, để `doctor` và `cleanup` chỉ nhận sandbox của mình.

**Sẵn sàng** khi stderr in `✔ sẵn sàng: ...`, exit 0, và dòng cuối stdout là đường dẫn sandbox. Lúc đó `./scripts/validate-kit.sh` đã xanh trong `app/` (dùng được, không chỉ là đã chép file). Installer hoặc validate-kit đỏ thì `launch` in log rồi exit 1, và giữ sandbox để xem.

Không có gì chạy nền, nên **tắt** chính là `cleanup` (xem dưới).

## Doctor

```bash
$H doctor "$SBX"
```

Chỉ đọc. Nó kiểm tra: sandbox có dấu của đúng repo kit này; hook và script trong `app/` giống từng byte với cây làm việc của kit (kit đổi sau `launch` thì đỏ, phải cleanup rồi launch lại); `app/` ở `feat/verify`, `on-main/` ở `main`; `validate-kit.sh` xanh trong `app/`. Nó in commit của kit và phiên bản bash, jq, python3. Thiếu jq thì `auto` không phải jq, thiếu Python thì mode `python` âm thầm rơi về sed. Ghi điều đó vào báo cáo.

## Drive

Chọn tính năng trong [features/README.md](features/README.md), mở file của tính năng và làm đúng các bước trong mục `Driving it with ...`. Các lệnh con của helper:

| Lệnh | Làm gì |
|---|---|
| `$H big-input <file ra> <dòng đầu> <cwd> [số dòng=20000]` | JSON PreToolUse: dòng đầu là lệnh nguy hiểm, sau đó N dòng `echo line-N`. Lệnh được ghi vào file rồi mới đưa vào JSON (`jq --rawfile`, hoặc Python đọc file), không đi qua argv. |
| `$H guard-loop "$SBX" <input.json> [số lần=10]` | Chạy `app/.claude/hooks/guard-irreversible.sh` với `CLAUDE_PROJECT_DIR=app`, mỗi `KIT_JSON_TOOL=auto\|python\|sed`. In `n/N "permissionDecision":"ask"`, lý do và số byte stderr. Exit 0 chỉ khi mọi lần đều hỏi và stderr rỗng. `IGNORE_SIGPIPE=1` chạy guard trong `( trap '' PIPE; ... )`. |
| `$H load "$SBX" <thư mục log> [số vòng=4] [số bản=6]` | Mỗi vòng chạy song song N bản `./scripts/test-hooks.sh` trong `app/`, mỗi bản một log riêng. Ghi `summary.txt`. Exit 0 khi 0 lần đỏ. Khoảng 4 phút mỗi vòng trên 4 CPU, nên chạy nền. |

## Evidence

Lưu ở `artifacts/verify/<slug>/` trong repo kit (đã có trong `.gitignore`), `<slug>` là id của hành trình trong feature map. Với mỗi bước, ghi lệnh, stdout, stderr và exit code, ví dụ `$H guard-loop "$SBX" "$SBX/in-deploy.json" 2>&1 | tee artifacts/verify/<slug>/guard-loop.txt`, rồi `echo "exit ${PIPESTATUS[0]}" >> ...`. Bằng chứng phải đến từ đường người dùng thật: hook đã cài trong `app/`, gọi qua stdin như Claude Code, script gọi như người gõ. Không source `lib.sh` để gọi hàm lẻ, không sửa hook trong sandbox để nó dễ pass. Mọi thay đổi trạng thái (file đã ghi, settings đã gộp, dòng lint báo) phải đọc lại bằng một lệnh khác (`cat`, `jq`, `git status`). Ghi cả *hành động* lẫn *kết quả*. Chép `doctor` vào `doctor.txt` ở đầu mỗi thư mục bằng chứng.

## Cleanup

```bash
$H cleanup "$SBX"
```

Lệnh này chỉ xoá thư mục có dấu `.verify-kit-sandbox` trỏ về đúng repo kit này. Nó không kill tiến trình nào theo tên. `load` đang chạy nền thì chờ nó xong (hoặc dừng đúng task mình đã khởi động) rồi mới cleanup. Bằng chứng ở `artifacts/verify/` được giữ lại: kiểm tra bằng `ls artifacts/verify/<slug>/` sau khi cleanup.

## Helpers

- `helpers/sandbox.sh`: gõ `$H` không kèm lệnh con để in cách dùng. `validate-kit.sh` của repo kit kiểm cú pháp, lint `grep -q` đọc từ pipe và shellcheck trên file này.
- Không có helper nào cần mạng hay quyền root. Chạy song song nhiều sandbox được: mỗi `launch` có thư mục riêng, `test-hooks.sh` tự dùng `mktemp -d`.
