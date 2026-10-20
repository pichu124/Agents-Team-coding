# Stop gate: chưa được kết thúc lượt khi check đỏ

Khi agent định kết thúc lượt, Claude Code chạy `.claude/hooks/stop-gate.sh` với JSON sự kiện Stop. Repo có thay đổi ở file không phải tài liệu (chưa commit, hoặc commit chưa push) thì gate chạy `./scripts/check.sh`. Check đỏ thì gate in `{"decision":"block","reason":"..."}` kèm 40 dòng cuối của output, và agent phải làm tiếp. Sau `AGENT_STOP_GATE_MAX` lần chặn liên tiếp (mặc định 3), gate nhả bằng một `systemMessage` để người xem. Không có thay đổi, chỉ đổi file `.md`, hoặc check xanh thì gate im lặng, exit 0.

## Sub-features

- `clean` repo sạch thì không chạy check, im lặng.
- `block-red` có thay đổi và check đỏ thì chặn, lý do có đếm `lần chặn n/max` và output của check.
- `pass-green` check xanh thì im lặng, bộ đếm về 0.
- `docs-only` chỉ đổi `.md`/`.txt`/`.rst` thì không chạy check.
- `release` quá `AGENT_STOP_GATE_MAX` lần chặn liên tiếp thì nhả bằng `systemMessage`.
- `off` `AGENT_STOP_GATE=off` tắt gate cho phiên.

## How to get to it (user POV)

- Dự án đã cài kit: `.claude/settings.json` đăng ký `"$CLAUDE_PROJECT_DIR"/.claude/hooks/stop-gate.sh` cho Stop. Hook chạy ở cuối mọi lượt của agent.
- Plugin: `plugin/run-hook.sh stop-gate` nhường cho bản của dự án khi dự án đã đăng ký (xem `scripts/test-plugin.sh`).
- Người dùng thấy agent không dừng mà sửa tiếp kèm lý do "check.sh đang đỏ", hoặc thấy thông báo "Stop gate: ... vẫn đỏ sau N lần chặn".

## Driving it with stdin JSON + helpers/sandbox.sh

Preconditions:

- Đã `launch`, `doctor` xanh. Bản cài trong `$SBX/app` đã được commit, nên `git -C "$SBX/app" status --porcelain` rỗng.
- Mỗi lần thử dùng một `session_id` mới (ví dụ `verify-kit-$RANDOM`), vì bộ đếm nằm ở `${TMPDIR:-/tmp}/agent-stop-gate/<session_id>.count`.
- Input Stop: `printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","stop_hook_active":false}' "$SID" "$SBX/app" > "$SBX/stop.json"`. Gọi bằng `CLAUDE_PROJECT_DIR="$SBX/app" "$SBX/app/.claude/hooks/stop-gate.sh" < "$SBX/stop.json"`. Dưới đây `GATE` là viết tắt của lệnh đó. Shell không giữ hàm hay alias giữa các lần gọi, nên mỗi lần phải gõ đầy đủ.

- **clean.** Chạy `GATE; echo "exit $?"`. Kỳ vọng: stdout rỗng, `exit 0`.
- **block-red.** Tạo check riêng của dự án, đỏ và có dấu nhận biết: `printf '#!/usr/bin/env bash\necho "lint đỏ: app.py:3" >&2\nexit 1\n' > "$SBX/app/scripts/check.local.sh"`. Chạy `GATE | jq -r '.decision, (.reason | split("\n")[0]), (.reason | contains("lint đỏ: app.py:3"))'`. Kỳ vọng: `block`, `./scripts/check.sh đang đỏ (exit 1), chưa được kết thúc lượt (lần chặn 1/3).`, `true`, exit 0. Chạy lại lần nữa: dòng đầu phải là `(lần chặn 2/3)`.
- **pass-green.** `printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX/app/scripts/check.local.sh"`, chạy `GATE`. Kỳ vọng: stdout rỗng, exit 0, và file đếm `${TMPDIR:-/tmp}/agent-stop-gate/$SID.count` không còn.
- **docs-only.** `rm "$SBX/app/scripts/check.local.sh"`, `echo ghi chú > "$SBX/app/NOTES.md"`, chạy `time GATE`. Kỳ vọng: stdout rỗng, exit 0, dưới 1 giây (không chạy check). Dọn: `rm "$SBX/app/NOTES.md"`.
- **release.** `SID` mới, check đỏ lại như `block-red`, chạy hai lần `AGENT_STOP_GATE_MAX=1 GATE`. Kỳ vọng: lần 1 `"decision":"block"`; lần 2 exit 0 với `systemMessage` "Stop gate: ./scripts/check.sh vẫn đỏ sau 1 lần chặn liên tiếp. Agent được dừng để bạn xem xét."
- **Xác nhận.** Sau khi dọn, `git -C "$SBX/app" status --porcelain` rỗng.
- **Bằng chứng.** `artifacts/verify/stop-gate/`: `doctor.txt`, output JSON của từng bước (qua `jq .`), exit code, và `time` của `docs-only`.

## Gotchas

- Gate chỉ chạy khi có thay đổi ở file không phải tài liệu. Quên tạo `check.local.sh` (hoặc chỉ đổi `.md`) thì gate im lặng. Đó là `docs-only` chứ không phải `pass-green`.
- `check.sh` trong `$SBX/app` chỉ chạy test của kit khi hooks/scripts của kit có thay đổi chưa commit. Bản cài đã được commit nên bước `block-red` nhanh. Nếu bạn sửa hook trong sandbox thì mỗi lần gọi gate mất hơn 1 phút (chạy `test-hooks.sh`).
- `AGENT_STOP_GATE=off` hoặc `AGENT_STOP_GATE_ACTIVE` chứa `$SBX/app` trong môi trường của bạn thì gate thoát ngay, im lặng. Kiểm bằng `env | grep AGENT_STOP_GATE` trước khi kết luận.
- Dùng lại `session_id` cũ thì bộ đếm cộng dồn từ lần trước, và `release` hay `(lần chặn 1/3)` sẽ lệch.
- Dựng input bằng `printf` chỉ đúng khi đường dẫn không chứa `"` hoặc `\`. Đường dẫn lạ thì dùng `jq -cn --arg d "$SBX/app" ...`.
