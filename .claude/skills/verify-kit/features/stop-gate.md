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
- Bộ đếm lần chặn nằm ở `${TMPDIR:-/tmp}/agent-stop-gate/<session_id>.count`. Trong một hành trình, mọi lần gọi gate phải cùng `TMPDIR`, và mỗi hành trình dùng một `session_id` mới.
- Dựng input và gọi gate bằng hai dòng sau. Shell không giữ biến hay hàm giữa các lần gọi Bash, nên gõ đầy đủ mỗi lần, với `session_id` gắn với tên sandbox (dựng lại được ở mỗi lần gọi, và khác nhau giữa các lần chạy):

  ```bash
  printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","stop_hook_active":false}' "$(basename "$SBX")-red" "$SBX/app" > "$SBX/stop.json"
  CLAUDE_PROJECT_DIR="$SBX/app" "$SBX/app/.claude/hooks/stop-gate.sh" < "$SBX/stop.json"; echo "exit $?"
  ```

  Dưới đây `GATE` là dòng thứ hai, bỏ phần `; echo`. Mỗi bước ghi hậu tố của session_id (`-clean`, `-red`, `-release`): chạy lại dòng đầu với hậu tố đó.

- **clean.** Dựng `stop.json` với hậu tố `-clean`, chạy `GATE; echo "exit $?"`. Kỳ vọng: stdout rỗng, `exit 0`.
- **block-red.** Dựng `stop.json` với hậu tố `-red`. Tạo check riêng của dự án, đỏ và có dấu nhận biết: `printf '#!/usr/bin/env bash\necho "lint đỏ: app.py:3" >&2\nexit 1\n' > "$SBX/app/scripts/check.local.sh"`. Chạy `CLAUDE_PROJECT_DIR="$SBX/app" "$SBX/app/.claude/hooks/stop-gate.sh" < "$SBX/stop.json" | jq -r '.decision, (.reason | split("\n")[0]), (.reason | contains("lint đỏ: app.py:3"))'`. Kỳ vọng: `block`, `./scripts/check.sh đang đỏ (exit 1), chưa được kết thúc lượt (lần chặn 1/3).`, `true`. Chạy lại đúng lệnh đó: dòng thứ hai phải kết thúc bằng `(lần chặn 2/3).`
- **pass-green.** Giữ hậu tố `-red`. `printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX/app/scripts/check.local.sh"`, chạy `GATE; echo "exit $?"`. Kỳ vọng: stdout rỗng, `exit 0`. `ls "${TMPDIR:-/tmp}/agent-stop-gate/$(basename "$SBX")-red.count"` phải báo không có file (bộ đếm về 0).
- **docs-only.** `rm "$SBX/app/scripts/check.local.sh"`, `echo ghi chú > "$SBX/app/NOTES.md"`, chạy `time GATE`. Kỳ vọng: stdout rỗng, exit 0, dưới 1 giây (không chạy check). Dọn: `rm "$SBX/app/NOTES.md"`.
- **release.** Dựng `stop.json` với hậu tố `-release`, tạo lại check đỏ như `block-red`, rồi chạy hai lần `AGENT_STOP_GATE_MAX=1 CLAUDE_PROJECT_DIR="$SBX/app" "$SBX/app/.claude/hooks/stop-gate.sh" < "$SBX/stop.json"`. Kỳ vọng: lần 1 `"decision":"block"` với `(lần chặn 1/1)`; lần 2 exit 0 với `systemMessage` "Stop gate: ./scripts/check.sh vẫn đỏ sau 1 lần chặn liên tiếp. Agent được dừng để bạn xem xét." Dọn: `rm "$SBX/app/scripts/check.local.sh"`.
- **Xác nhận.** Sau khi dọn, `git -C "$SBX/app" status --porcelain` rỗng.
- **Bằng chứng.** `artifacts/verify/stop-gate/`: `doctor.txt`, output JSON của từng bước (qua `jq .`), exit code, và `time` của `docs-only`.

## Gotchas

- Gate chỉ chạy khi có thay đổi ở file không phải tài liệu. Quên tạo `check.local.sh` (hoặc chỉ đổi `.md`) thì gate im lặng. Đó là `docs-only` chứ không phải `pass-green`.
- `check.sh` trong `$SBX/app` chỉ chạy test của kit khi hooks/scripts của kit có thay đổi chưa commit. Bản cài đã được commit nên bước `block-red` nhanh. Nếu bạn sửa hook trong sandbox thì mỗi lần gọi gate mất hơn 1 phút (chạy `test-hooks.sh`).
- `AGENT_STOP_GATE=off` hoặc `AGENT_STOP_GATE_ACTIVE` chứa `$SBX/app` trong môi trường của bạn thì gate thoát ngay, im lặng. Kiểm bằng `env | grep AGENT_STOP_GATE` trước khi kết luận.
- Dùng lại `session_id` cũ (hoặc quên dựng lại `stop.json` sau khi đổi session_id) thì bộ đếm cộng dồn từ lần trước, và `release` hay `(lần chặn 1/3)` sẽ lệch. Đổi `TMPDIR` giữa hai lần gọi cũng làm bộ đếm như mới.
- Dựng input bằng `printf` chỉ đúng khi đường dẫn không chứa `"` hoặc `\`. Đường dẫn lạ thì dùng `jq -cn --arg d "$SBX/app" ...`.
