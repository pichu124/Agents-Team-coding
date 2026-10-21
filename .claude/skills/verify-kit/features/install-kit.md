# Cài kit vào repo khác

`scripts/install-kit.sh <repo-đích> [--force]` chép agents, hooks, 4 skill của kit và các script check sang một git repo khác. Nó gộp `permissions` và `hooks` vào `.claude/settings.json` sẵn có (giữ khoá khác), tạo `CLAUDE.md` từ khung `templates/project-CLAUDE.md` nếu chưa có (có rồi thì giữ nguyên), luôn đặt quy ước đội vào `.claude/rules/agent-team.md`, ghi commit kit đã cài và danh sách file của kit vào `.claude/agent-team-kit.txt`, thêm `*.sh text eol=lf` và `artifacts/` vào cấu hình git. File trùng tên mà khác nội dung thì dừng mà không chép gì, trừ khi có `--force`.

## Sub-features

- `fresh` repo trống: đủ file, 3 hook được đăng ký, manifest `.claude/agent-team-kit.txt` ghi đúng commit kit, validate-kit xanh ngay trong repo đích.
- `kit-skills-only` chỉ 4 skill của kit được chép, `verify-kit` thì không.
- `merge-settings` settings sẵn có được gộp, giữ khoá và hook riêng của dự án.
- `own-claude-md` CLAUDE.md riêng giữ nguyên byte, quy ước đội vào `.claude/rules/agent-team.md`.
- `reinstall` chạy lại để cập nhật kit cho cùng kết quả (manifest y hệt), giữ phần riêng dưới dòng `<!-- agent-team:kit-end`.
- `dropped` file mà lần cài trước có, kit nay đã bỏ, repo vẫn còn: báo ⚠, không xoá, báo lại tới khi người dùng xoá.
- `conflict` file của kit bị sửa riêng thì installer dừng, exit 1, không đụng gì.

## How to get to it (user POV)

- `cd <dự-án> && git switch -c chore/agent-team && /đường/dẫn/Agents-Team-coding/scripts/install-kit.sh .` (README, mục Bắt đầu nhanh).
- Cập nhật kit: `git pull` trong repo kit rồi chạy lại lệnh trên trong dự án, thêm `--force` (file của kit đã đổi thì không có `--force` installer dừng vì trùng file).

## Driving it with shell + helpers/sandbox.sh

Preconditions:

- Đã `launch`: chính `launch` là hành trình `fresh` (log ở `$SBX/install.log`, đọc ở `$SBX/ready.log`). `doctor` xanh.
- Có Python, vì installer cần nó để gộp settings.json. Có jq để đọc lại.
- Không có `load` nào đang chạy trên sandbox này: cài lại ghi đè hook đã cài, bản test-hooks đang chạy có thể đọc phải file đang ghi dở.

- **fresh.** `cat "$SBX/install.log"`. Kỳ vọng: `✔ đã chép 26 file của kit`, `✔ tạo .claude/settings.json`, `✔ tạo CLAUDE.md (điền các mục TODO)`, `✔ quy ước đội ở .claude/rules/agent-team.md`. Đọc lại: `cmp templates/project-CLAUDE.md "$SBX/app/CLAUDE.md"` và `cmp templates/agent-team-rules.md "$SBX/app/.claude/rules/agent-team.md"` đều exit 0. `jq -c '[.hooks[][].hooks[].command]' "$SBX/app/.claude/settings.json"` có đúng 3 lệnh `guard-irreversible.sh`, `post-edit-format.sh`, `stop-gate.sh`. `git -C "$SBX/app" check-ignore -q artifacts/verify/x && echo ignored` in `ignored`. Manifest: install.log có `✔ .claude/agent-team-kit.txt: kit <7 ký tự đầu của git rev-parse HEAD>`; `grep '^kit-commit:' "$SBX/app/.claude/agent-team-kit.txt"` bằng `kit-commit: $(git rev-parse HEAD)`, thêm `-dirty` khi kit có thay đổi chưa commit; `awk '/^kit-dropped:$/ { on = 0 } on; /^kit-files:$/ { on = 1 }'` của file đó in đúng 26 file đã chép, và `tail -n 1` của file là `kit-dropped:` (mục này rỗng).
- **kit-skills-only.** `ls "$SBX/app/.claude/skills"`. Kỳ vọng: đúng `agent-audit correct create-verify-skill team-lead`, không có `verify-kit`.
- **merge-settings + own-claude-md.** Repo thứ hai có settings và CLAUDE.md riêng:
  `git init -q "$SBX/merge" && git -C "$SBX/merge" -c user.email=v@v -c user.name=v -c commit.gpgsign=false commit -q --allow-empty -m init`,
  `mkdir -p "$SBX/merge/.claude" && printf '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"python notify.py"}]}]}}\n' > "$SBX/merge/.claude/settings.json"`,
  `printf '# Dự án riêng\n\nQuy ước riêng.\n' > "$SBX/merge/CLAUDE.md" && cp "$SBX/merge/CLAUDE.md" "$SBX/claude.orig"`.
  Chạy `scripts/install-kit.sh "$SBX/merge"`. Kỳ vọng: exit 0, có dòng `✔ gộp permissions + hooks vào .claude/settings.json` và `✔ CLAUDE.md đã có nên giữ nguyên`. Đọc lại: `jq -r '.model, (.hooks.Stop[].hooks[].command)' "$SBX/merge/.claude/settings.json"` in `opus`, `python notify.py`, `"$CLAUDE_PROJECT_DIR"/.claude/hooks/stop-gate.sh`. `cmp "$SBX/claude.orig" "$SBX/merge/CLAUDE.md"` exit 0. `cmp templates/agent-team-rules.md "$SBX/merge/.claude/rules/agent-team.md"` exit 0.
- **reinstall (repo có CLAUDE.md riêng).** Thêm phần riêng dưới dòng dấu: `printf '\n## Riêng dự án\n\n- Không chạm thư mục data/.\n' >> "$SBX/merge/.claude/rules/agent-team.md"`. Sao lưu rules và settings, chạy lại `scripts/install-kit.sh "$SBX/merge"`. Kỳ vọng: exit 0, `cmp` cả hai file với bản sao lưu đều exit 0, `jq '.hooks.Stop | length'` vẫn là `2`.
- **reinstall (repo mà CLAUDE.md do lần cài đầu tạo).** Chạy lại `scripts/install-kit.sh "$SBX/app"`. Kỳ vọng theo hợp đồng ở đầu installer ("Chạy lại nhiều lần vẫn cho cùng kết quả"): exit 0 và `git -C "$SBX/app" status --porcelain` rỗng, nghĩa là cả `.claude/agent-team-kit.txt` cũng y hệt bản đã commit. Trước bản sửa (đo ngày 2026-10-20 trên e5a6756) status in `?? .claude/rules/`, vì lần cài đầu chép CLAUDE.md của repo kit và chưa tạo rules.
- **reinstall (bản cài cũ, CLAUDE.md chép từ kit).** Giả lập bản cài trước bản sửa: `cp CLAUDE.md "$SBX/app/CLAUDE.md" && rm -r "$SBX/app/.claude/rules"`, rồi chạy lại `scripts/install-kit.sh "$SBX/app" --force`. Kỳ vọng: exit 0, stderr có dòng `⚠ CLAUDE.md còn quy ước đội chép từ bản kit cũ`, `cmp CLAUDE.md "$SBX/app/CLAUDE.md"` exit 0 (installer không sửa CLAUDE.md), `cmp templates/agent-team-rules.md "$SBX/app/.claude/rules/agent-team.md"` exit 0. Dọn: `git -C "$SBX/app" checkout -- CLAUDE.md`.
- **dropped.** Giả lập file mà lần cài trước có, kit nay đã bỏ: `echo cũ > "$SBX/app/.claude/agents/old-agent.md"`, rồi thêm nó vào mục `kit-files:` của manifest: `awk '{ print } $0 == "kit-files:" { print ".claude/agents/old-agent.md" }' "$SBX/app/.claude/agent-team-kit.txt" > "$SBX/m.txt" && mv "$SBX/m.txt" "$SBX/app/.claude/agent-team-kit.txt"`. Chạy lại `scripts/install-kit.sh "$SBX/app"`. Kỳ vọng: exit 0, stderr có `⚠ kit đã bỏ 1 file mà repo này vẫn còn` và dòng `  .claude/agents/old-agent.md`. Đọc lại: file vẫn còn (installer không xoá), `sed -n '/^kit-dropped:$/,$p'` của manifest có `.claude/agents/old-agent.md`. Chạy lại lần nữa vẫn báo. `rm "$SBX/app/.claude/agents/old-agent.md"` rồi chạy lại: không còn ⚠ đó, `git -C "$SBX/app" status --porcelain` rỗng.
- **conflict.** `echo "sửa riêng" >> "$SBX/app/.claude/agents/architect.md"`, chạy `scripts/install-kit.sh "$SBX/app"`. Kỳ vọng: exit 1, stderr `✘ .claude/agents/architect.md đã tồn tại và khác bản của kit` và `✘ dừng: 1 file trùng...`. Đọc lại: `git -C "$SBX/app" status --porcelain` chỉ có ` M .claude/agents/architect.md`, và `tail -n 1` của file vẫn là `sửa riêng`. Dọn: `git -C "$SBX/app" checkout -- .claude/agents/architect.md`.
- **Bằng chứng.** `artifacts/verify/install-kit/`: `doctor.txt`, `install.log` (chép từ sandbox), output và exit code của từng lần cài, kết quả `jq`/`cmp`/`git status` dùng để đọc lại.

## Gotchas

- Bản cài trước bản sửa đã chép CLAUDE.md của repo kit sang dự án. Installer không tự sửa CLAUDE.md đó, chỉ cảnh báo ⚠ ở mọi lần chạy chừng nào nó còn chuỗi `/team-lead <task>`. Người dùng tự xoá các dòng trùng.
- Installer từ chối khi repo đích chính là repo kit (`✘ repo đích trùng với kit`). Luôn cài vào sandbox.
- Không có Python thì installer không gộp được settings.json có sẵn: nó chỉ in cảnh báo. `merge-settings` khi đó là INCONCLUSIVE, không phải FAIL.
- `--force` ghi đè file của dự án. Chỉ dùng trong sandbox, và không dùng để làm `conflict` pass.
- Kit có thay đổi chưa commit (đang sửa kit) thì `kit-commit:` có hậu tố `-dirty`. Commit kit giữa `launch` và `reinstall` thì manifest đổi theo commit mới, status không còn rỗng: `cleanup` rồi `launch` lại.
- Số file chép (`26`) đổi khi kit thêm hoặc bớt file. Đối chiếu bằng `ls`/`jq` ở bước đọc lại, đừng chỉ so con số.
