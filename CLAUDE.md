# CLAUDE.md

<!-- Giữ file này NGẮN. Với mỗi dòng, hỏi: "bỏ dòng này thì agent có làm sai không?" Không thì xoá.
     Rule nào biến được thành check hay hook thì chuyển sang đó và ghi vào bảng cuối file. -->

## Dự án

Bộ khởi động đội AI agent lập trình cho Claude Code (`.claude/agents`, `.claude/skills`, `.claude/hooks`) kèm tài liệu nghiên cứu trong `docs/`.
<!-- TODO khi cài vào dự án thật: 2–3 dòng về sản phẩm, stack chính, các thư mục quan trọng. -->

## Lệnh

- `./scripts/check.sh` là THE check: kiểm tra bộ kit cộng với check của dự án (`scripts/check.local.sh` nếu có). Chạy trước khi báo xong. CI chạy đúng lệnh này.
- `./scripts/validate-kit.sh` chỉ kiểm tra file của kit: frontmatter, link, hook, cú pháp shell, `grep -q` đọc từ pipe.
- `./scripts/test-hooks.sh`, `./scripts/test-install.sh` là test hành vi của hook và installer. Sửa hook hoặc installer thì thêm ca test tái hiện lỗi trước.
- `./scripts/audit-agent.sh --since 7 [--all]` dò sự cố từ file phiên (guard bỏ sót, hỏi thừa, Stop gate, lỗi hook, lần bạn phải sửa agent, chỉ số tuần); `--all` soát mọi dự án trên máy. `/agent-audit` dò rồi sửa kèm test, mở PR nháp.
<!-- TODO: lệnh chạy app local, lệnh chạy một test đơn lẻ, biến môi trường bắt buộc. -->

## Cách làm việc

- Task không tầm thường thì dùng `/team-lead <task>`. Luôn chốt điều kiện xong dạng pass/fail trước khi làm.
- Bug: tái hiện trước (test fail hoặc bằng chứng), rồi mới sửa. Sửa nguyên nhân gốc.
- "Xong" nghĩa là `./scripts/check.sh` exit 0 cộng bằng chứng hành vi. Không chạy được check thì nói "inconclusive".
- Người viết không tự kiểm: verify và review bằng subagent mới (`verifier`, `reviewer`).
- Commit nhỏ, có thứ tự, theo Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Bị người dùng sửa cùng một lỗi lần thứ hai thì đề xuất `/correct`.

## Quyền tự chủ

- Cứ làm: đọc, sửa trong branch hoặc worktree, commit cục bộ, chạy test, mở PR nháp.
- Luôn hỏi người: force-push, push hoặc merge vào nhánh chính, xoá dữ liệu, deploy, publish.

## Rule ↔ Thứ thực thi

| Rule | Thực thi bởi |
|---|---|
| Không kết thúc lượt khi check đỏ | `.claude/hooks/stop-gate.sh` (Stop) |
| Hỏi người trước hành động không đảo ngược được | `.claude/hooks/guard-irreversible.sh` (PreToolUse) |
| Không đọc file bí mật (`.env`, `*.pem`, `secrets/`) | `permissions.deny` trong `.claude/settings.json` |
| Format theo cấu hình của dự án | `.claude/hooks/post-edit-format.sh` (PostToolUse) |
| Agent và skill có frontmatter hợp lệ, link không gãy | `scripts/validate-kit.sh` (trong `check.sh` và CI) |
| Script của kit không cho `grep -q` đọc stdin từ pipe (pipefail đọc SIGPIPE thành "không khớp") | `scripts/validate-kit.sh` (báo file:dòng, sửa bằng `text_grep` của `lib.sh`) |
| Không bớt ca "phải hỏi" của guard để cho dễ | `scripts/guard-ask-floor` (test-hooks đỏ khi số ca dưới sàn) |
| Sửa phân tích lệnh của audit không được làm mục A bỏ sót lệnh mà bản trước vẫn báo | `scripts/test-audit.sh` (so với bản trước trên lệnh fixture và fuzz; `NARROWING_OK` cho thu hẹp có chủ ý) |
| Lệnh mà bash thật xoá đích ngoài thư mục tạm thì mục A phải báo; `KNOWN_MISSES` chỉ được giảm | `scripts/test-audit.sh` (bước oracle: lệnh fuzz cố định chạy bằng bash, `rm` thay bằng stub chỉ ghi đích; đỏ khi sót ca ngoài `KNOWN_MISSES`, khi ca trong đó đã hết sót, hoặc khi danh sách thêm ca so với bản trước) |
| Phiên có bản chép (cùng uuid ở nhiều file) không được đếm hai lần trong báo cáo audit | `scripts/test-audit.sh` (chạy lại mọi fixture kèm một bản chép đầy đủ, báo cáo phải y hệt) |
| Bug phải được tái hiện trước khi sửa | Chỉ có lời nhắc (playbook bug-fix). Ứng viên cho `/correct` |
