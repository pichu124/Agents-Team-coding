# Guard hỏi trước hành động không đảo ngược được

Trước mỗi lần agent gọi tool Bash hoặc PowerShell, Claude Code chạy `.claude/hooks/guard-irreversible.sh` và đưa JSON PreToolUse vào stdin. Lệnh khớp một mẫu nguy hiểm (force-push, push lên hoặc khi đang ở nhánh chính, `rm -rf` thư mục rộng, deploy, publish, xoá database...) thì guard in `"permissionDecision":"ask"` kèm lý do, và người phải xác nhận. Lệnh vô hại thì guard im lặng, exit 0. Khớp thừa chỉ tốn một câu hỏi, bỏ sót thì mất dữ liệu.

## Sub-features

- `ask-short` lệnh nguy hiểm ngắn thì hỏi, lệnh vô hại thì im lặng.
- `large-input` lệnh dài hơn pipe buffer (64 KiB) vẫn hỏi. Lỗi đã lọt: PR pichu124/Agents-Team-coding#6.
- `push-main` `git push` khi `cwd` là repo ở nhánh `main` thì hỏi, kể cả trong lệnh dài.
- `json-modes` cả ba cách đọc JSON (`KIT_JSON_TOOL=auto` dùng jq, `python`, `sed`) cho cùng kết quả.
- `sigpipe-ignored` tiến trình cha bỏ qua SIGPIPE thì guard vẫn hỏi và stderr sạch.
- `load` dưới tải (nhiều bản test chạy song song), không ca "phải hỏi" nào bị bỏ sót.
- `plugin-entry` bản plugin gọi cùng guard qua `plugin/run-hook.sh guard-irreversible`, không bao giờ nhường.

## How to get to it (user POV)

- Dự án đã cài kit: `.claude/settings.json` đăng ký `"$CLAUDE_PROJECT_DIR"/.claude/hooks/guard-irreversible.sh` cho PreToolUse, matcher `Bash|PowerShell`. Hook chạy ở mọi lệnh agent gọi.
- Cài dạng plugin: `plugin/hooks.json` gọi `bash "${CLAUDE_PLUGIN_ROOT}/plugin/run-hook.sh" guard-irreversible`.
- Người dùng chỉ thấy kết quả: hộp xác nhận kèm lý do "Hành động không đảo ngược được (...)", hoặc không thấy gì.

## Driving it with stdin JSON + helpers/sandbox.sh

Preconditions:

- Đã `launch`, `doctor` xanh. `H=.claude/skills/verify-kit/helpers/sandbox.sh`, `SBX` là đường dẫn sandbox.
- `$SBX/on-main` ở nhánh `main` (doctor đã kiểm). Có jq hoặc Python để dựng JSON.
- Hành trình `load` cần 4 CPU trở lên mới tái hiện được tải. Máy yếu hơn thì vẫn chạy và ghi số CPU, nhưng không kết luận được về tải.

- **ask-short.** Dựng hai input ngắn (0 dòng đệm): `$H big-input "$SBX/in-force.json" 'git push --force origin feat/x' "$SBX/app" 0` và `$H big-input "$SBX/in-ls.json" 'ls -la' "$SBX/app" 0`. Chạy `$H guard-loop "$SBX" "$SBX/in-force.json" 3`. Kỳ vọng: mỗi mode `3/3`, lý do `force-push hoặc xoá nhánh remote`. Chạy `CLAUDE_PROJECT_DIR="$SBX/app" "$SBX/app/.claude/hooks/guard-irreversible.sh" < "$SBX/in-ls.json"; echo "exit $?"`. Kỳ vọng: stdout rỗng, `exit 0`.
- **large-input (hành trình tái hiện 1, tất định).** Dựng hai input khoảng 320 KiB, lệnh không đi qua argv:
  `$H big-input "$SBX/in-deploy.json" 'npm run deploy' "$SBX/app"` và `$H big-input "$SBX/in-push.json" 'git push' "$SBX/on-main"`. Mỗi file phải in khoảng 329000 byte và `20000 dòng vô hại`.
  Chạy `$H guard-loop "$SBX" "$SBX/in-deploy.json" 10` và `$H guard-loop "$SBX" "$SBX/in-push.json" 10`.
  Kỳ vọng: `auto`, `python`, `sed` đều `10/10 "permissionDecision":"ask"`, lý do lần lượt là `deploy` và `push khi đang ở nhánh main`, stderr 0 byte, exit 0.
- **Lệnh dài vô hại vẫn im lặng.** `$H big-input "$SBX/in-big-ls.json" 'ls -la' "$SBX/app"`, rồi `CLAUDE_PROJECT_DIR="$SBX/app" "$SBX/app/.claude/hooks/guard-irreversible.sh" < "$SBX/in-big-ls.json" | wc -c`. Kỳ vọng `0`. Ca này giữ cho "luôn hỏi" không thành cách pass.
- **sigpipe-ignored (hành trình tái hiện 3).** `IGNORE_SIGPIPE=1 $H guard-loop "$SBX" "$SBX/in-deploy.json" 10`, rồi làm lại với `in-push.json`. Kỳ vọng: mọi mode `10/10`, `stderr 0 byte`, exit 0. Helper chạy guard trong `( trap '' PIPE; ... )`: subshell kế thừa việc bỏ qua SIGPIPE, `printf` không chết mà báo lỗi ghi ra stderr.
- **plugin-entry.** Chạy `VIA_PLUGIN=1 $H guard-loop "$SBX" "$SBX/in-deploy.json" 3`. Dòng `entry point:` phải là `bash .../plugin/run-hook.sh guard-irreversible`. Kỳ vọng: `3/3` mỗi mode, dù `$SBX/app` đã cài kit (guard không nhường).
- **load (hành trình tái hiện 2, xác suất, bề mặt thật).** Chạy nền: `$H load "$SBX" artifacts/verify/guard-load 4 6`. Lệnh này chạy 6 bản `./scripts/test-hooks.sh` song song trong `$SBX/app`, lặp 4 vòng, mỗi bản một log riêng. Kỳ vọng: dòng cuối `TỔNG: 0/24 lần chạy đỏ`, exit 0. Bản đỏ thì log của nó (`r<vòng>-<bản>.log`) có dòng `✘ guard phải hỏi [...]` kèm input: chép dòng đó vào báo cáo. Mất khoảng 15 phút trên 4 CPU.
- **Đối chứng (khi cần chứng minh hành trình còn bắt được lỗi).** Thay hook trong sandbox bằng bản trước khi sửa: `git archive cad746e .claude/hooks | tar -x -C "$SBX/app"`. Chạy lại `large-input`. Kỳ vọng `0/10` mọi mode (đo ngày 2026-10-20: 0/10 cả 6 tổ hợp). Bản `126dc5e` (đã sửa SIGPIPE, chưa sửa stderr) với `sigpipe-ignored`: vẫn hỏi nhưng stderr khác rỗng (`printf: write error`). Xong thì `cleanup` rồi `launch` lại: doctor sẽ báo bản cài khác kit.
- **Bằng chứng.** `$H doctor "$SBX" > artifacts/verify/guard-irreversible/doctor.txt`, mỗi bước `... 2>&1 | tee artifacts/verify/guard-irreversible/<bước>.txt` kèm `echo "exit ${PIPESTATUS[0]}"`. Với `load`: `artifacts/verify/guard-load/summary.txt` cùng 24 log.

## Gotchas

- Lỗi gốc (PR pichu124/Agents-Team-coding#6): guard so mẫu bằng `printf '%s' "$cmd" | grep -Eiq` dưới `set -o pipefail`. `grep -q` thoát ở dòng khớp đầu tiên, `printf` (mỗi dòng một `write()`) nhận SIGPIPE, và pipefail biến "khớp" thành "không khớp". Lệnh nhiều dòng ngắn chỉ bị bỏ sót khi máy bận, lệnh dài hơn 64 KiB thì lần nào cũng bị bỏ sót. **Vì sao lọt:** check không phủ. Test chỉ có lệnh ngắn và chạy trên máy rảnh.
- Lệnh dưới 128 KiB chỉ bỏ sót theo may rủi: `grep` đọc tối đa 64 KiB một lần, `printf` kịp ghi thêm 64 KiB. Muốn tất định thì input phải trên 128 KiB. Mặc định 20000 dòng (khoảng 320 KiB) đủ dư.
- Đừng dựng lệnh dài bằng `--arg c "$(cat file)"` hay đối số dòng lệnh: Windows giới hạn khoảng 32K ký tự, Linux có ARG_MAX. Dùng `$H big-input` (jq `--rawfile`, hoặc Python đọc file).
- Thấy "ask" chưa đủ: phải đúng **lý do**. `git push` hỏi vì một mẫu khác (ví dụ cwd không phải `on-main`) thì không chứng minh được `push-main`. Ca `push-main` cần `cwd` là repo đang ở `main`. Nếu `$SBX/on-main` bị đổi nhánh thì guard im lặng, đó là thiếu điều kiện chứ không phải pass hay fail của guard.
- Không có Python thì `KIT_JSON_TOOL=python` âm thầm dùng sed, không có jq thì `auto` không phải jq. Ba dòng vẫn in ra nhưng không phủ đủ ba cách đọc. Ghi theo dòng `công cụ:` của doctor.
- `load` là bằng chứng xác suất. Trước khi sửa, tỉ lệ đỏ khoảng 1/6 bản trong 1 vòng trên 3–5 vòng, nên 4 vòng xanh vẫn để lọt bản lỗi với xác suất khoảng (3/4)^4 ≈ 32%. Hành trình tất định là `large-input`. Cần chắc hơn thì tăng số vòng (8 vòng ≈ 10%), không bao giờ giảm.
- Trong lúc `load` chạy, mọi lệnh khác trên máy chậm đi nhiều lần. Chạy các bước tất định trước, hoặc sau khi `load` xong. Đừng chạy hai `load` cùng lúc rồi gộp kết quả.
- `load` dùng hook đã cài trong `$SBX/app`. Hành trình nào sửa file trong đó (như `pipe-quiet-grep` của validate-kit) thì chạy trên một sandbox khác (`launch` lần nữa), không thì các bản test-hooks đang chạy đọc phải file đã sửa.
- `IGNORE_SIGPIPE=1` chỉ có tác dụng trong subshell của helper. Đừng gõ `trap '' PIPE` trực tiếp trong shell của mình: các lệnh sau đó sẽ thừa hưởng.
