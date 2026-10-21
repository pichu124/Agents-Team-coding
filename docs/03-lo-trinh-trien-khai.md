# Lộ trình triển khai đội agent

Nguyên tắc xuyên suốt: **leo từng bậc, và chỉ leo khi bậc hiện tại đã đáng tin.**

> *"Running more agents before you trust their work only multiplies bad pull requests."* — Lauren Tan

## 1. Sáu cấp độ trưởng thành

| Cấp | Bạn có gì | Cổng để lên cấp tiếp theo |
|---|---|---|
| **0. Một agent, từng lượt** | `CLAUDE.md` ngắn; `scripts/check.sh` là một lệnh duy nhất | `check.sh` bắt được lỗi thật; agent tự chạy nó mà không cần nhắc |
| **1. Tự kiểm chứng** | Stop hook; skill `verify-<app>` kèm feature map cho 3–5 tính năng chính | Agent tự đưa bằng chứng; bạn ít phải tự chạy lại app hơn |
| **2. Tách vai** | architect / implementer / verifier / reviewer; `/team-lead` | Verifier bắt được lỗi trước bạn; reviewer không còn spam lỗi vặt |
| **3. Song song** | 2–5 task độc lập trên worktree; agent teams cho review và nghiên cứu | Tỷ lệ PR phải làm lại thấp; không còn xung đột file |
| **4. Tự chạy dài** | `/goal`, hợp đồng qua đêm, decision log, playbook babysit PR | Đủ 4 điều kiện "earn the trust" (mục 4) |
| **5. Chủ động** | `/schedule` hoặc routine: gardener định kỳ, triage bug từ Slack/Sentry, cập nhật dependency | Mọi giai đoạn đều có thể dừng dây chuyền và bàn giao bằng chứng |

Phần lớn đội nên ở cấp **1–2** trong vài tuần đầu. Cấp 1 là cấp đem lại nhiều giá trị nhất trên mỗi giờ đầu tư.

## 2. Kế hoạch 30 ngày

### Tuần 1: Nền móng (cấp 0 → 1)
1. **Cài kit** vào dự án thật (xem mục 3).
2. **Định nghĩa "the check"** trong `scripts/check.local.sh`: lint, typecheck, test nhanh. Chạy thử, rồi cố tình gây một lỗi để chắc rằng nó **fail**.
3. **Tỉa `CLAUDE.md`**: chỉ giữ lệnh, quirk môi trường và quy ước mà Claude không tự đoán được. Nhớ cập nhật bảng rule ↔ enforcer.
4. Chạy `/create-verify-skill` để sinh `verify-<app>` và feature map cho 3–5 tính năng quan trọng nhất. Hoặc thử `/verify` (built-in của Claude Code) trước, rồi tinh chỉnh công thức nó ghi lại.
5. Làm 5–10 task thật **một agent, có người xem**. Ghi lại mọi lần bạn phải sửa agent.

### Tuần 2: Tách vai (cấp 1 → 2)
1. Dùng `/team-lead <task>` cho mọi việc không tầm thường.
2. So sánh kết luận của verifier với cảm nhận của bạn. Khi verifier sai, sửa skill `verify-<app>` hoặc feature map, đừng sửa bằng lời.
3. Chạy `/correct` lần đầu với các lỗi đã ghi ở tuần 1. Mục tiêu: **ít nhất 2 lớp lỗi được mã hoá thành check**, và có bằng chứng check đó fail trên lỗi cũ.
4. Đặt CI (`.github/workflows/check.yml`) làm required check cho PR.

### Tuần 3: Song song (cấp 2 → 3)
1. Chạy 2–3 task độc lập cùng lúc, mỗi task trên một worktree riêng: `claude --worktree`, hoặc lead giao với `isolation: "worktree"`.
2. Bật agent teams (tuỳ chọn) và thử **review PR theo 3 lăng kính**, hoặc **debug bằng giả thuyết cạnh tranh**. Chưa dùng teams để viết code.
3. Theo dõi chỉ số ở mục 6. Nếu tỷ lệ làm lại tăng, quay về cấp 2.

### Tuần 4: Tự chạy (cấp 3 → 4)
1. Chọn **một** việc lặp lại mà bạn đang là nút thắt, ví dụ migration hoặc dọn lint.
2. Viết hợp đồng qua đêm (mục 5), chạy với `/goal` và decision log. Lần đầu nên chạy khi bạn còn ngồi xem.
3. Buổi sáng: đọc mục Attention và decision log, *không* đọc lại toàn bộ transcript.
4. Lên lịch gardener chạy hằng tuần bằng `/schedule` hoặc `/loop`.

## 3. Cài kit vào dự án của bạn

```bash
# Khi kit chưa được merge vào main, thêm: -b claude/sharp-knuth-lpdhqz
git clone https://github.com/pichu124/Agents-Team-coding.git /đường/dẫn/tới/Agents-Team-coding
cd /đường/dẫn/tới/dự-án            # git repo của bạn, nên làm trên một branch mới
git switch -c chore/agent-team
/đường/dẫn/tới/Agents-Team-coding/scripts/install-kit.sh .
./scripts/check.sh
```

`install-kit.sh` làm những việc sau và có test tự động ([`scripts/test-install.sh`](../scripts/test-install.sh)):
- Kiểm tra `.claude/settings.json` có sẵn trước: JSON hỏng hoặc có comment thì dừng mà không chép gì. File có BOM UTF-8 (Notepad trên Windows) vẫn đọc được.
- Chép agents, hooks, 3 skill và các script check của kit. Nếu có file trùng tên mà khác nội dung, nó dừng và không chép gì; muốn ghi đè thì dùng `--force`.
- Stage các script `.sh` của kit với quyền chạy, để commit từ Windows vẫn giữ được quyền này.
- Gộp `permissions` và `hooks` vào `.claude/settings.json` sẵn có, giữ nguyên các khoá khác. Chạy lại nhiều lần không bị nhân đôi hook.
- Nếu dự án chưa có CLAUDE.md thì tạo từ khung [`templates/project-CLAUDE.md`](../templates/project-CLAUDE.md), có các mục TODO để bạn điền. Nếu đã có thì giữ nguyên. CLAUDE.md còn quy ước đội chép từ bản kit cũ thì installer cảnh báo ở mọi lần chạy: xoá các dòng đó, giữ phần riêng của dự án.
- Luôn đặt quy ước của đội vào `.claude/rules/agent-team.md`. Khi chạy lại để cập nhật kit, nó chỉ thay phần của kit trong file này, tới dòng `<!-- agent-team:kit-end ... -->`. Quy ước riêng viết dưới dòng đó được giữ. Bản cài cũ chưa có dòng này thì giữ các mục `#`/`##` không có trong template.
- Thêm `*.sh text eol=lf` vào `.gitattributes`, để script không bị đổi sang CRLF trên Windows.
- Nếu `.gitignore` đang bỏ qua thư mục của kit thì thêm ngoại lệ dạng `!thư-mục/`. Các luật như `.env` hay `*.log` vẫn giữ hiệu lực.
- Thêm `artifacts/` vào `.gitignore`: đó là nơi verifier lưu bằng chứng. Không ignore thì Stop gate coi đó là thay đổi và chạy check ở mọi lượt.

Ví dụ đầy đủ cho một dự án Python có sẵn cấu hình Claude Code: [04-thu-nghiem-vnstock-dashboard.md](./04-thu-nghiem-vnstock-dashboard.md).

Sau đó:
- **Khai báo check thật** của dự án trong `scripts/check.local.sh`. Nếu file này tồn tại, `check.sh` dùng nó thay cho phần tự nhận diện:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  npm run -s lint
  npm run -s typecheck
  npm test -- --run
  ```
- Mở Claude Code trong dự án và chạy `/create-verify-skill`.
- Điền phần `<!-- TODO -->` trong `CLAUDE.md`.
- Tạm tắt Stop gate cho một phiên: `AGENT_STOP_GATE=off claude`.

Yêu cầu: `bash` và `git`. Trên Windows dùng Git Bash, vì Claude Code cũng chạy hook bằng Git Bash. Hook đọc JSON bằng `jq`, nếu không có thì bằng Python (`python3`, `python` hay `py`), nếu không có nữa thì bằng `sed`. Cả ba cách đều được test với cùng một bộ lệnh. Stop gate không có jq/Python thì chặn bằng exit code 2.

Guard cố ý hỏi thừa hơn là bỏ sót. Ví dụ, khi đang đứng trên nhánh chính thì **mọi** `git push` đều phải hỏi, kể cả push một nhánh khác.

Trên Windows, Claude Code chạy lệnh qua **PowerShell tool** là chính (mặc định với tài khoản claude.ai khi đã có Git Bash). Vì vậy guard đăng ký với matcher `Bash|PowerShell` và có thêm mẫu cho `Remove-Item -Recurse`, `rd /s`. `validate-kit.sh` báo đỏ nếu matcher thiếu PowerShell, và khi cài lại lên bản cũ, `install-kit.sh` tự thêm PowerShell vào matcher (cần `--force` nếu file của kit đã đổi). Nếu bạn đặt hook riêng chung nhóm với guard, hook đó cũng sẽ nhận lệnh PowerShell.

### Kit chạy được ở đâu

Kit là file trong repo, nên mọi nơi chạy Claude Code **trên máy bạn** đều nạp nó, vì chúng đọc cùng các file settings. Bản plugin (cài một lần cho mọi dự án, xem [docs/05](05-cai-cho-moi-du-an.md)) cũng vậy, trừ cloud.

| Nơi dùng | Kit có tác dụng | Ghi chú |
|---|---|---|
| `claude` trong terminal | Có | Đã thử trên Windows: hook, agent, `/team-lead`, hộp hỏi của guard |
| App Claude trên máy, tab Code, phiên Local | Có | Tài liệu không ghi rõ phần agent và `/hooks`. Kiểm bằng cách hỏi Claude danh sách agent type, và thử guard |
| Extension VS Code | Có | Xem hook ở Customize > Hooks |
| Remote Control | Có | Là phiên `claude` trên máy bạn, chỉ điều khiển từ điện thoại hoặc web. Máy phải bật |
| Cloud (claude.ai/code, phiên cloud mở từ app) | Có, nếu kit đã được push | Chạy trên máy ảo Linux clone từ GitHub: không có `.env`, không có dữ liệu local, không có thư viện ngoài PyPI. Nếu check của dự án cần những thứ đó thì Stop gate sẽ chặn vì check đỏ |

## 4. Bốn điều kiện trước khi cho agent tự chạy

Theo Lauren Tan:
1. Bạn đã làm task này bằng tay một lần, hoặc đã xem agent làm, nên biết "tốt" trông thế nào.
2. Agent có đủ công cụ và tín hiệu bạn sẽ dùng: verify skill, profiler, log.
3. Mọi giai đoạn đều tự chứng minh được kết quả và **có thể dừng dây chuyền**.
4. Bạn đã đọc vài transcript và biến các lỗi lặp lại thành tool, skill hoặc check.

## 5. Prompt mẫu

**Sửa bug**
```text
/team-lead xuất CSV bị trùng dòng khi retry giữa chừng. tái hiện trước bằng test fail,
rồi sửa và kiểm chứng. xong = test mới pass, ./scripts/check.sh xanh, verifier PASS.
```

**Tính năng**
```text
/team-lead thêm output JSON cho lệnh `report`. output text giữ nguyên từng byte,
JSON parse được, cả hai chạy trên sample project. cho tôi xem bằng chứng.
```

**Hợp đồng qua đêm**
```text
/team-lead tôi đi ngủ. chuyển mọi caller sang parser mới trên worktree mới từ main.
xong = 0 caller cũ, mọi fixture của parser pass, API cũ đã xoá, ./scripts/check.sh xanh.
ghi decision log. không cần hỏi tôi trước khi commit. KHÔNG push lên main, KHÔNG merge.
nếu thật sự kẹt quá 3 giờ, dừng lại và viết rõ vì sao.
```
Rồi gắn điều kiện bằng `/goal`:
```text
/goal grep không còn import từ "legacy/parser", ./scripts/check.sh exit 0, decisions.tsv có dòng cho mỗi commit; hoặc dừng sau 40 lượt
```

**Review song song bằng agent team** (cần bật agent teams)
```text
Spawn three teammates using the reviewer agent type to review PR #142:
one for security, one for performance, one for test coverage.
Report only issues that affect correctness or stated requirements.
```

**Debug bằng giả thuyết cạnh tranh**
```text
App thoát sau một tin nhắn thay vì giữ kết nối. Spawn 4 teammates, mỗi người một giả thuyết.
Họ phải cố bác bỏ giả thuyết của nhau như một cuộc tranh luận khoa học.
Ghi kết luận đồng thuận vào docs/investigations/<ngày>-disconnect.md.
```

**Mã hoá lỗi lặp lại**
```text
/correct
```

## 6. Chỉ số nên theo dõi

| Chỉ số | Vì sao |
|---|---|
| PR merged / tuần | Thông lượng, nhưng **đừng tối ưu riêng chỉ số này** |
| % PR phải làm lại hoặc bị revert trong 7 ngày | Chất lượng thật |
| % PR có bằng chứng kiểm chứng đính kèm | Mức độ trust |
| Số lần bạn phải sửa agent / tuần, theo lớp lỗi | Đầu vào cho `/correct`. Phải giảm dần |
| Số rule trong CLAUDE.md không có enforcer | Nên tiến về 0 |
| % lần chạy CI đỏ trên PR do agent tạo | Hiệu quả của cổng `check.sh` |

## 7. Cạm bẫy thường gặp

- **Tăng số agent trước khi có kiểm chứng.** Bạn chỉ nhận thêm việc phải review.
- **"Làm trong 4 tiếng"** không phải điều kiện xong. Hãy cho một vị từ pass/fail.
- **CLAUDE.md phình to.** Rule quan trọng bị chìm. Chuyển rule thành check hoặc hook.
- **Reviewer bắt bẻ mọi thứ.** Bạn sẽ over-engineer. Chỉ sửa lỗi correctness.
- **Verifier dùng endpoint test hoặc mock để pass.** Bằng chứng giả. Phải đi đúng đường người dùng đi.
- **Hai agent sửa cùng file.** Chúng ghi đè nhau. Chia việc theo ranh giới file.
- **Một phiên dài sửa đi sửa lại.** Context bẩn. `/clear` rồi viết brief tốt hơn.
- **Tự động hoá hành động không đảo ngược được.** Luôn để hook buộc hỏi người.
