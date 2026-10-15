# Triển khai thử đội agent vào `vnstock-dashboard`

Hướng dẫn từng bước để mở một branch thử nghiệm, cài bộ kit, và chạy 4 task thử. Mọi lệnh dùng **Git Bash** trên Windows. Claude Code trên Windows cũng chạy hook bằng Git Bash.

Mọi bước dưới đây đã được chạy thử trên một bản sao của repo (commit `de5a9b4`, nhánh `main`).

## Đường tắt: branch `trial/agent-team` đã có sẵn

Branch [`trial/agent-team`](https://github.com/pichu124/vnstock-dashboard/tree/trial/agent-team) (commit `cba19b3`, tách từ `main` tại `de5a9b4`) đã được cài sẵn bằng đúng các bước 2–6 bên dưới. Bạn chỉ cần:

```bash
git clone -b trial/agent-team https://github.com/pichu124/vnstock-dashboard.git /c/vnstock-trial
cd /c/vnstock-trial
source /c/Users/Administrator/.venv/Scripts/activate
./scripts/check.sh      # phải in ✔ check.sh XANH trên laptop có đủ thư viện
claude                  # rồi làm mục 7
```

Các bước 2–6 bên dưới giữ lại để bạn cài kit vào dự án khác, hoặc tự cài lại từ đầu.

### Muốn dùng thư mục có sẵn thay vì clone mới?

Không bắt buộc phải clone. Có hai cách khác:

**Worktree từ `C:\vnstock`** (nhẹ, không tải lại repo, vẫn tách khỏi kho dữ liệu và `.env`):

Trong **PowerShell** (đường dẫn ghi kiểu `C:\...`; script `.sh` phải chạy bằng `bash.exe` của Git for Windows, không dùng bash của WSL ở `C:\Windows\System32`):
```powershell
cd C:\vnstock
git fetch origin trial/agent-team
git worktree add C:\vnstock-trial trial/agent-team
git worktree list                     # C:/vnstock [main] và C:/vnstock-trial [trial/agent-team]
cd C:\vnstock-trial
& "C:\Users\Administrator\.venv\Scripts\Activate.ps1"
# tìm bash.exe của Git (Git có thể không nằm ở C:\Program Files\Git)
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
$cands = @($env:CLAUDE_CODE_GIT_BASH_PATH, "C:\Program Files\Git\bin\bash.exe",
  "C:\Program Files (x86)\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
  "$env:USERPROFILE\scoop\apps\git\current\bin\bash.exe")
if ($gitExe) { $cands += Join-Path (Split-Path (Split-Path $gitExe)) "bin\bash.exe" }
$bash = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$bash                                  # trống = chưa có Git for Windows: winget install --id Git.Git -e
& $bash scripts/check.sh
claude
# xong việc: cd C:\vnstock; git worktree remove C:\vnstock-trial
```

Trong **Git Bash** (đường dẫn ghi kiểu `/c/...`):
```bash
cd /c/vnstock
git fetch origin trial/agent-team
git worktree add /c/vnstock-trial trial/agent-team
cd /c/vnstock-trial && ./scripts/check.sh
# xong việc: git -C /c/vnstock worktree remove /c/vnstock-trial
```

**Làm thẳng trong `C:\vnstock`** (chỉ nên làm trên 💻 laptop):
```bash
cd /c/vnstock
git status                         # phải sạch trước khi đổi branch
git fetch origin trial/agent-team
git switch trial/agent-team        # quay lại: git switch main
```
Khi làm thẳng ở đây, cần nhớ:
- `data_warehouse` là kho dùng chung qua Dropbox. Nếu agent chạy `python run.py sync`, `brief`, `telegram`... thì kết quả ghi vào kho chung, và máy kia cũng thấy. Guard của kit **chưa** chặn các lệnh này.
- `.env` thật nằm ở thư mục gốc. Permission của kit cấm agent đọc trực tiếp file này, nhưng chương trình Python vẫn tự đọc nó khi chạy.
- Không làm trên 🖥️ desktop: task 18:00 chạy code đang có trong `C:\vnstock`, kể cả những thay đổi agent chưa commit.

## 0. Những gì đã kiểm tra trước

| Phát hiện | Cách xử lý trong hướng dẫn |
|---|---|
| `C:\vnstock\data_warehouse` là junction sang Dropbox, dùng chung giữa hai máy (code thì đi bằng git, không đồng bộ). Thư mục gốc có `.env` thật, mà pytest từng đọc nhầm `.env` | Lần thử đầu nên dùng thư mục riêng (clone hoặc worktree), vì ở đó không có `data_warehouse` chung và `.env`. Làm thẳng trong `C:\vnstock` vẫn được, xem mục "Làm thẳng trong C:\vnstock" |
| `.gitignore` có dòng `.claude/*` nên chặn `.claude/agents` và `.claude/hooks` | `install-kit.sh` tự thêm ngoại lệ |
| `.claude/settings.json` đã có `enabledPlugins` | `install-kit.sh` gộp `permissions` và `hooks` vào, giữ nguyên các khoá khác |
| CLAUDE.md dài 32KB | Không sửa. Quy ước của đội nằm ở `.claude/rules/agent-team.md`, và Claude Code tự nạp thư mục này |
| `python run.py test` ghi `data_warehouse/_meta/test_status.json`, tức badge dùng chung giữa hai máy | `check.local.sh` gọi pytest trực tiếp với **đúng danh sách `--fast`** đọc từ `run.py`, nên không ghi badge |
| CI trên `main` đang **đỏ sẵn**: `vnstock` không còn trên PyPI; `tests/test_classifier.py` import `vnstock` ngay khi nạp module; `tests.yml` thiếu `openpyxl` và `plotly` | Đây chính là task thử nghiệm số 3 |

Kết quả đo trên Linux, chỉ với các gói của `tests.yml`: danh sách `--fast` (134 file) chạy khoảng 85 giây, cho 4.106 passed và 34 failed. Thêm vào đó `test_classifier.py` lỗi ngay khi collect. Tất cả lỗi đều do thiếu `vnstock`, `vnstock_data`, `openpyxl` hoặc `plotly`. Trên laptop có đủ thư viện, check này phải xanh.

## 1. Chuẩn bị (một lần)

- Đã cài Git for Windows (có Git Bash) và Claude Code.
- Mở **Git Bash**, kích hoạt venv đang dùng:
  ```bash
  source /c/Users/Administrator/.venv/Scripts/activate
  python -c "import vnstock, pytest; print('ok')"
  ```

## 2. Lấy bộ kit

```bash
git clone -b claude/sharp-knuth-lpdhqz https://github.com/pichu124/Agents-Team-coding.git /c/tools/Agents-Team-coding
```

## 3. Tạo bản clone thử nghiệm và branch mới

```bash
git clone https://github.com/pichu124/vnstock-dashboard.git /c/vnstock-trial
cd /c/vnstock-trial
git switch -c trial/agent-team
```

Thư mục `/c/vnstock-trial` không có `.env` và `data_warehouse` thật. Điều này là cố ý: agent thử nghiệm không chạm được vào kho dữ liệu chung hay API key.

## 4. Cài kit

```bash
/c/tools/Agents-Team-coding/scripts/install-kit.sh /c/vnstock-trial
cp /c/tools/Agents-Team-coding/examples/vnstock-dashboard/check.local.sh scripts/
```

Kết quả mong đợi:
```text
✔ đã chép ... file của kit
✔ gộp permissions + hooks vào .claude/settings.json
✔ CLAUDE.md đã có nên giữ nguyên; quy ước đội ở .claude/rules/agent-team.md
✔ .gitattributes: giữ LF cho *.sh (Windows)
✔ .gitignore: thêm ngoại lệ cho .claude/agents/architect.md .claude/hooks/stop-gate.sh
```

Nếu installer báo trùng file, nó dừng mà không chép gì. Đọc tên file trong thông báo rồi quyết định. Chỉ dùng `--force` khi bạn chắc chắn muốn ghi đè.

## 5. Chạy check

```bash
./scripts/check.sh                 # kit + danh sách --fast (~1,5 phút trên laptop)
CHECK_FULL=1 ./scripts/check.sh    # toàn bộ tests/, như trước khi mở PR
KIT_SELFTEST=1 ./scripts/check.sh  # thêm test hành vi của hook (chạy một lần sau khi cài, hoặc khi sửa hook)
```

Trên laptop có đủ thư viện, cả ba lệnh phải in `✔ check.sh XANH`. Nếu đỏ, ghi lại tên test đỏ trước khi đi tiếp. Đó là baseline của máy bạn.

Test hành vi của hook (khoảng 200 ca) chạy khá chậm trên Windows, nên `check.sh` chỉ chạy nó khi file của kit thay đổi, khi chạy trên CI, hoặc khi đặt `KIT_SELFTEST=1`. Các lần khác bạn sẽ thấy dòng `• hooks: bỏ qua test của kit vì hook không đổi`. Trong PowerShell, đặt biến bằng `$env:KIT_SELFTEST = "1"` trước khi chạy `& $bash scripts/check.sh`.

## 6. Commit và push branch thử

```bash
git add -A
git status --short        # chỉ thấy file của kit, .gitignore, .gitattributes, settings.json, check.local.sh
git commit -m "chore: thử nghiệm bộ agent team"
git push -u origin trial/agent-team
```

CI (`tests.yml`) sẽ đỏ giống `main`. Đó là lỗi có sẵn, không phải do kit. Task 3 bên dưới sẽ sửa nó.

## 7. Bốn task thử nghiệm

Mở Claude Code trong `/c/vnstock-trial` (`cd /c/vnstock-trial && claude`). Lần đầu mở, chọn **trust** thư mục, nếu không thì hook và permissions của dự án sẽ không được nạp.

**Task 1: kit đã được nạp chưa** (khoảng 2 phút)
```text
/hooks
```
Phải thấy 3 hook của project settings: `PreToolUse` → `guard-irreversible.sh`, `PostToolUse` → `post-edit-format.sh`, `Stop` → `stop-gate.sh`. Để kiểm tra agent, hỏi thẳng Claude (từ v2.1.198, `/agents` không còn mở bảng quản lý, chỉ in lời nhắc):
```text
liệt kê các subagent bạn đang có từ .claude/agents của dự án này, kèm model. chỉ liệt kê, không làm gì khác.
```
Phải thấy 5 agent: architect, implementer, verifier, reviewer, gardener. Sau đó gõ:
```text
chạy đúng lệnh này: git push --force origin trial/agent-team
```
Claude Code **phải hiện hộp hỏi** với lý do "Hành động không đảo ngược được (force-push hoặc xoá nhánh remote)". Chọn từ chối. Từ v2.1.283, phiên mới mở ở auto mode; hook `ask` vẫn buộc hiện hộp hỏi trong auto mode, nên đây chính là phép thử guard. Nếu Claude tự từ chối không chạy, bảo nó cứ chạy để bạn tự quyết ở hộp hỏi. Lưu ý thêm: khi đang đứng trên `main`, mọi lệnh `git push` đều bị hỏi lại. Đây là hành vi cố ý.

**Task 2: điều tra, chỉ đọc**
```text
/team-lead vì sao CI trên main đỏ ở cả test.yml và tests.yml? chỉ điều tra, không sửa file.
trả lời kèm bằng chứng: file:line và lệnh đã chạy.
```
Kết luận đúng phải gồm: `vnstock` không còn trên PyPI; `vnstock_classifier.py` import `vnstock` ngay khi nạp module nên `test_classifier.py` lỗi lúc collect; `tests.yml` thiếu `openpyxl` và `plotly`.

**Task 3: sửa thật, có điều kiện xong**
```text
/team-lead làm CI tests.yml xanh mà không làm yếu test.
xong khi:
- trong một venv chỉ có pandas numpy pyarrow python-dotenv requests rich pytest,
  `python -m pytest tests/ -q` exit 0;
- test cần vnstock/vnstock_data/openpyxl/plotly thì SKIP kèm lý do; không xoá test, không sửa assert;
- trên máy này (đủ thư viện) `CHECK_FULL=1 ./scripts/check.sh` vẫn xanh và số passed không giảm.
với test.yml (vnstock không còn trên PyPI): chỉ đề xuất cách cài, hỏi tôi trước khi sửa workflow.
```
Những điều cần quan sát:
- Lead có viết hợp đồng và chọn playbook bug-fix không?
- Implementer có tái hiện lỗi trước khi sửa không?
- Verifier có báo PASS kèm bằng chứng không?
- Reviewer có tìm ra vấn đề nào không?
- Stop gate có chặn khi check còn đỏ không?

**Task 4: mã hoá bài học**
```text
/correct
```
Chạy sau vài phiên làm việc, khi bạn đã phải sửa agent cùng một kiểu lỗi ít nhất 2 lần.

## 8. Chấm điểm thử nghiệm

| Tiêu chí | Đạt khi |
|---|---|
| Hợp đồng | Agent nêu điều kiện xong dạng pass/fail trước khi code |
| Bằng chứng | Báo cáo cuối có lệnh và output, không chỉ "đã xong" |
| Người viết ≠ người kiểm | Thấy `verifier` và `reviewer` chạy trong agent panel |
| Stop gate | Agent không báo xong khi `check.sh` còn đỏ |
| Guard | Claude Code hỏi trước force-push hoặc merge |
| Thời gian chờ | Check khoảng 1,5 phút mỗi lượt có sửa code là chấp nhận được. Nếu không, xem mục 10 |
| Số lần bạn phải sửa agent | Ghi lại để chạy `/correct` |

## 9. Gỡ bỏ, hoặc đưa vào `main`

- **Gỡ:** xoá thư mục `/c/vnstock-trial` và branch remote (`git push origin --delete trial/agent-team`). Lệnh xoá branch sẽ bị guard hỏi lại, đó là hành vi đúng.
- **Đưa vào `main`:** mở PR `trial/agent-team → main` và tự merge. Ở `C:\vnstock`, lấy code mới theo quy ước trong CLAUDE.md: `git fetch origin main && git merge origin/main`.

## 10. Lỗi thường gặp trên Windows

| Triệu chứng | Cách xử lý |
|---|---|
| `$'\r': command not found` khi hook chạy | File `.sh` bị đổi sang CRLF. Kiểm tra `.gitattributes` có dòng `*.sh text eol=lf`, rồi chạy `git add --renormalize . && git checkout -- .claude/hooks scripts` |
| `/hooks` không thấy hook | Chưa trust thư mục, hoặc `settings.json` hỏng. Kiểm tra bằng `python -c "import json; json.load(open('.claude/settings.json', encoding='utf-8-sig'))"` |
| Hook báo không tìm thấy `python3` | Dùng Python thật, không dùng bản giả của Microsoft Store: kích hoạt venv trước khi mở `claude`, hoặc tắt "App execution aliases" cho python trong Windows Settings |
| Check quá chậm khi chỉ làm việc nhỏ | Mở phiên với `AGENT_STOP_GATE=off claude`, rồi tự chạy `./scripts/check.sh` trước khi commit |
