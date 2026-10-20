# Cài kit vào repo khác

`scripts/install-kit.sh <repo-đích> [--force]` chép agents, hooks, 4 skill của kit và các script check sang một git repo khác. Nó gộp `permissions` và `hooks` vào `.claude/settings.json` sẵn có (giữ khoá khác), tạo `CLAUDE.md` nếu chưa có (có rồi thì đặt quy ước đội vào `.claude/rules/agent-team.md`), thêm `*.sh text eol=lf` và `artifacts/` vào cấu hình git. File trùng tên mà khác nội dung thì dừng mà không chép gì, trừ khi có `--force`.

## Sub-features

- `fresh` repo trống: đủ file, 3 hook được đăng ký, validate-kit xanh ngay trong repo đích.
- `kit-skills-only` chỉ 4 skill của kit được chép, `verify-kit` thì không.
- `merge-settings` settings sẵn có được gộp, giữ khoá và hook riêng của dự án.
- `own-claude-md` CLAUDE.md riêng giữ nguyên byte, quy ước đội vào `.claude/rules/agent-team.md`.
- `reinstall` chạy lại để cập nhật kit cho cùng kết quả, giữ phần riêng dưới dòng `<!-- agent-team:kit-end`.
- `conflict` file của kit bị sửa riêng thì installer dừng, exit 1, không đụng gì.

## How to get to it (user POV)

- `cd <dự-án> && git switch -c chore/agent-team && /đường/dẫn/Agents-Team-coding/scripts/install-kit.sh .` (README, mục Bắt đầu nhanh).
- Cập nhật kit: `git pull` trong repo kit rồi chạy lại đúng lệnh trên trong dự án.

## Driving it with shell + helpers/sandbox.sh

Preconditions:

- Đã `launch`: chính `launch` là hành trình `fresh` (log ở `$SBX/install.log`, đọc ở `$SBX/ready.log`). `doctor` xanh.
- Có Python, vì installer cần nó để gộp settings.json. Có jq để đọc lại.

- **fresh.** `cat "$SBX/install.log"`. Kỳ vọng: `✔ đã chép 26 file của kit`, `✔ tạo .claude/settings.json`, `✔ tạo CLAUDE.md`. Đọc lại: `jq -c '[.hooks[][].hooks[].command]' "$SBX/app/.claude/settings.json"` có đúng 3 lệnh `guard-irreversible.sh`, `post-edit-format.sh`, `stop-gate.sh`. `git -C "$SBX/app" check-ignore -q artifacts/verify/x && echo ignored` in `ignored`.
- **kit-skills-only.** `ls "$SBX/app/.claude/skills"`. Kỳ vọng: đúng `agent-audit correct create-verify-skill team-lead`, không có `verify-kit`.
- **merge-settings + own-claude-md.** Repo thứ hai có settings và CLAUDE.md riêng:
  `git init -q "$SBX/merge" && git -C "$SBX/merge" -c user.email=v@v -c user.name=v -c commit.gpgsign=false commit -q --allow-empty -m init`,
  `mkdir -p "$SBX/merge/.claude" && printf '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"python notify.py"}]}]}}\n' > "$SBX/merge/.claude/settings.json"`,
  `printf '# Dự án riêng\n\nQuy ước riêng.\n' > "$SBX/merge/CLAUDE.md" && cp "$SBX/merge/CLAUDE.md" "$SBX/claude.orig"`.
  Chạy `scripts/install-kit.sh "$SBX/merge"`. Kỳ vọng: exit 0, có dòng `✔ gộp permissions + hooks vào .claude/settings.json` và `✔ CLAUDE.md đã có nên giữ nguyên`. Đọc lại: `jq -r '.model, (.hooks.Stop[].hooks[].command)' "$SBX/merge/.claude/settings.json"` in `opus`, `python notify.py`, `"$CLAUDE_PROJECT_DIR"/.claude/hooks/stop-gate.sh`. `cmp "$SBX/claude.orig" "$SBX/merge/CLAUDE.md"` exit 0. `cmp templates/agent-team-rules.md "$SBX/merge/.claude/rules/agent-team.md"` exit 0.
- **reinstall (repo có CLAUDE.md riêng).** Thêm phần riêng dưới dòng dấu: `printf '\n## Riêng dự án\n\n- Không chạm thư mục data/.\n' >> "$SBX/merge/.claude/rules/agent-team.md"`. Sao lưu rules và settings, chạy lại `scripts/install-kit.sh "$SBX/merge"`. Kỳ vọng: exit 0, `cmp` cả hai file với bản sao lưu đều exit 0, `jq '.hooks.Stop | length'` vẫn là `2`.
- **reinstall (repo mà CLAUDE.md do lần cài đầu tạo).** Chạy lại `scripts/install-kit.sh "$SBX/app"`. Kỳ vọng theo hợp đồng ở đầu installer ("Chạy lại nhiều lần vẫn cho cùng kết quả"): exit 0 và `git -C "$SBX/app" status --porcelain` rỗng. **Hiện FAIL** (đo ngày 2026-10-20 trên e5a6756): status in `?? .claude/rules/`. Xem Gotchas. Dọn: `rm -r "$SBX/app/.claude/rules"`.
- **conflict.** `echo "sửa riêng" >> "$SBX/app/.claude/agents/architect.md"`, chạy `scripts/install-kit.sh "$SBX/app"`. Kỳ vọng: exit 1, stderr `✘ .claude/agents/architect.md đã tồn tại và khác bản của kit` và `✘ dừng: 1 file trùng...`. Đọc lại: `git -C "$SBX/app" status --porcelain` chỉ có ` M .claude/agents/architect.md`, và `tail -n 1` của file vẫn là `sửa riêng`. Dọn: `git -C "$SBX/app" checkout -- .claude/agents/architect.md`.
- **Bằng chứng.** `artifacts/verify/install-kit/`: `doctor.txt`, `install.log` (chép từ sandbox), output và exit code của từng lần cài, kết quả `jq`/`cmp`/`git status` dùng để đọc lại.

## Gotchas

- **Lỗi sản phẩm đang mở:** lần cài đầu vào repo chưa có CLAUDE.md thì chép CLAUDE.md của kit sang. Lần chạy lại (cập nhật kit) thấy CLAUDE.md đã có nên tạo thêm `.claude/rules/agent-team.md`, và quy ước đội nằm ở hai nơi (CLAUDE.md và rules). Trái với "cùng kết quả" ở đầu `install-kit.sh`. Đừng đổi hành trình để nó pass. Hành trình xanh khi installer được sửa.
- Installer từ chối khi repo đích chính là repo kit (`✘ repo đích trùng với kit`). Luôn cài vào sandbox.
- Không có Python thì installer không gộp được settings.json có sẵn: nó chỉ in cảnh báo. `merge-settings` khi đó là INCONCLUSIVE, không phải FAIL.
- `--force` ghi đè file của dự án. Chỉ dùng trong sandbox, và không dùng để làm `conflict` pass.
- Số file chép (`26`) đổi khi kit thêm hoặc bớt file. Đối chiếu bằng `ls`/`jq` ở bước đọc lại, đừng chỉ so con số.
