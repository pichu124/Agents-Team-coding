# Nghiên cứu: Agentic Engineering qua chia sẻ của Lydia Hallie và Lauren Tan

> Tổng hợp ngày 15/10/2026.
>
> **Độ tin cậy của nguồn.** Phần về Lauren Tan dựa chủ yếu vào mã nguồn gốc của bộ skill **pstack** mà cô công bố trong repo [`cursor/plugins`](https://github.com/cursor/plugins/tree/main/pstack) (đọc ở commit `850d7f2`, ngày 14/10/2026). Các bản tóm tắt talk của cô là nguồn thứ cấp. Phần về Lydia Hallie dựa vào tài liệu chính thức của Claude Code mà cô công bố, các bài đăng của cô trên X và mô tả khoá học của cô. Mình chưa tìm được bài nào của Lydia đặt tên trực tiếp là "agentic engineering". Những gì cô chia sẻ đều xoay quanh cách làm việc với Claude Code. Những chỗ chỉ có nguồn thứ cấp, hoặc các nguồn mâu thuẫn nhau, đều được ghi chú ngay tại chỗ.

---

## 0. Agentic Engineering là gì?

Đây là định nghĩa dùng xuyên suốt tài liệu này, rút ra từ cả hai người:

> **Agentic Engineering** là nghề thiết kế *hệ thống* giúp các AI agent viết code đúng, tự chứng minh được là đúng, và làm việc song song mà không cần người kèm từng bước. Đó là hệ thống gồm context, công cụ kiểm chứng, ràng buộc trong codebase, quy trình và vòng lặp.

Vai trò của kỹ sư dịch chuyển như sau:

| Trước | Với agentic engineering |
|---|---|
| Tự viết code | Đặt mục tiêu và **điều kiện hoàn thành có thể kiểm tra** |
| Tự review từng dòng | Duyệt **bằng chứng** (test output, ảnh chụp, trace) và một quyết định log |
| Nhắc lại cùng một lỗi trong review | **Mã hoá bài học vào cấu trúc**: type, lint, CI, hook |
| Một người, một việc | Nhiều agent song song, nhưng **chỉ sau khi đã tin được từng agent** |

Lauren Tan tóm gọn ý này trong README của pstack: *"if you want to go fast, go deep first"*. Muốn đi nhanh thì trước hết phải đi sâu.

---

## 1. Lydia Hallie (Anthropic, Claude Code team)

### 1.1. Lydia là ai

- Member of Technical Staff trong đội Claude Code ở Anthropic, phụ trách developer experience và giáo dục kỹ thuật ([theorg](https://theorg.com/org/anthropic/org-chart/lydia-hallie)).
- Trước đó cô là Head of DX ở Bun và DX engineer ở Vercel. Cô đồng tác giả [patterns.dev](https://www.patterns.dev/about/) cùng Addy Osmani.

### 1.2. Dòng thời gian các chia sẻ chính

| Thời điểm | Nội dung | Nguồn |
|---|---|---|
| 01/2026 | Công bố trang **Best Practices for Claude Code** trong tài liệu chính thức | [X](https://x.com/lydiahallie/status/2014136373645820165), [docs](https://code.claude.com/docs/en/best-practices) |
| 02/2026 | Công bố **agent teams** (research preview): một lead agent giao việc cho nhiều teammate chạy song song và phối hợp với nhau | [X](https://x.com/lydiahallie/status/2019469032844587505), [docs](https://code.claude.com/docs/en/agent-teams) |
| 04/2026 | Workshop "Claude Code Deep Dive" | [master.dev](https://master.dev/blog/free-claude-workshop/) |
| 05/2026 | **Khoá học Claude Code miễn phí** (Frontend Masters / master.dev): agentic loop, CLAUDE.md, permissions, skills, hooks, subagents, agent teams, plugins | [master.dev](https://master.dev/courses/claude-code/), [bài subagents](https://frontendmasters.com/courses/claude-code/subagents/), [bài hooks](https://master.dev/courses/claude-code/hooks/) |
| 08/2026 | Auto mode: một model phân loại riêng duyệt từng hành động. Lệnh `claude auto-mode critique` tìm các rule mơ hồ, thừa hoặc dễ chặn nhầm | [X](https://x.com/lydiahallie/status/2090134983625285845) |
| 2026 | **Mods**, "middleware cho Claude Code": hàm TypeScript chặn và sửa các sự kiện nội bộ (tool call, prompt, request tới model) | [X](https://x.com/lydiahallie/status/2105737466254598362) |

### 1.3. Các ý tưởng cốt lõi

Các ý dưới đây lấy từ trang Best Practices do Lydia công bố và từ nội dung khoá học của cô.

**(1) Context window là tài nguyên quan trọng nhất.**
Mọi tin nhắn, mọi file đã đọc và mọi output lệnh đều nằm trong context. Context càng đầy thì model càng dễ "quên" chỉ dẫn và mắc lỗi. Gần như mọi best practice khác đều xuất phát từ ràng buộc này:

- Chạy `/clear` giữa các việc không liên quan.
- Nếu đã sửa agent **hơn hai lần** cho cùng một vấn đề, hãy `/clear` rồi viết lại prompt tốt hơn. Một phiên sạch với prompt tốt gần như luôn thắng một phiên dài đầy lần sửa.
- Đẩy việc đọc nhiều file sang **subagent**. Subagent có context riêng và chỉ trả về bản tóm tắt.

**(2) Cho agent một cách tự kiểm chứng.** Đây là đòn bẩy lớn nhất.
> "Give Claude a check it can run: tests, a build, a screenshot to compare. It's the difference between a session you watch and one you walk away from."

Không có check chạy được thì "trông có vẻ xong" là tín hiệu duy nhất, và *bạn* trở thành vòng kiểm chứng. Có bốn mức gắn check vào điểm dừng của agent, từ nhẹ tới chặt:

| Mức | Cơ chế | Khi nào dùng |
|---|---|---|
| Trong một prompt | "chạy test và lặp tới khi pass" | Mọi việc, dùng ngay được |
| Cả phiên | `/goal <điều kiện>`: một evaluator riêng kiểm tra sau mỗi lượt | Việc lớn, có trạng thái kết thúc đo được |
| Cổng tất định | **Stop hook** chạy script và chặn lượt kết thúc tới khi pass | Chạy không người trông |
| Ý kiến thứ hai | Subagent kiểm chứng trong context mới | Để agent làm việc không tự chấm điểm chính mình |

Yêu cầu agent **đưa bằng chứng** chứ không chỉ khẳng định: output test, lệnh đã chạy và kết quả, ảnh chụp. Review bằng chứng nhanh hơn tự chạy lại.

**(3) Explore → Plan → Implement → Commit.**
Dùng plan mode để tách nghiên cứu khỏi thực thi. Nếu mô tả được diff trong một câu thì bỏ qua bước plan. Với tính năng lớn, cho Claude **phỏng vấn bạn** rồi viết `SPEC.md`, sau đó mở phiên mới để thực thi. Spec tốt nêu rõ file, interface, phạm vi loại trừ và kết thúc bằng một bước kiểm chứng end-to-end.

**(4) CLAUDE.md ngắn, hooks cho thứ "bắt buộc", skills cho thứ "thỉnh thoảng".**
- Với mỗi dòng trong CLAUDE.md, hỏi: *"Bỏ dòng này thì Claude có làm sai không?"* Nếu không thì xoá. CLAUDE.md dài khiến Claude bỏ qua chính những rule quan trọng.
- Hooks là **tất định**, còn CLAUDE.md chỉ là **khuyến nghị**. Việc gì phải xảy ra 100% thì đặt vào hook.
- Skills (`.claude/skills/<tên>/SKILL.md`) chỉ nạp khi cần, dùng cho kiến thức miền và quy trình lặp lại.
- Nếu Claude đã làm đúng mà không cần chỉ dẫn, hãy xoá chỉ dẫn đó hoặc chuyển nó thành hook.

**(5) Subagents và agent teams.**
- **Subagent** chạy vòng lặp riêng với context, tools và system prompt riêng, nên không làm bẩn cuộc hội thoại chính. Định nghĩa trong `.claude/agents/*.md`.
- **Agent team** gồm một lead, các teammate, một task list chung và mailbox. Các teammate nhắn trực tiếp cho nhau. Subagent thì chỉ báo kết quả một chiều về agent chính.
- Kinh nghiệm từ tài liệu agent teams:
  - Bắt đầu với **3–5 teammate**, mỗi teammate khoảng **5–6 task**.
  - Bắt đầu bằng việc **nghiên cứu và review** trước khi cho cả đội viết code song song.
  - **Mỗi teammate sở hữu một nhóm file riêng** để tránh ghi đè.
  - Dùng hook `TeammateIdle`, `TaskCreated`, `TaskCompleted` làm cổng chất lượng.
  - Mẫu "giả thuyết cạnh tranh": nhiều teammate cố bác bỏ giả thuyết của nhau để tránh hiệu ứng mỏ neo (anchoring).

**(6) Người viết khác người duyệt.**
Mẫu Writer/Reviewer: phiên B review code của phiên A trong context mới, không thiên vị code mình vừa viết. Có một cảnh báo đáng giá: reviewer được bảo "tìm lỗ hổng" thì gần như luôn tìm ra thứ gì đó. Đuổi theo mọi phát hiện sẽ dẫn tới over-engineering. Chỉ yêu cầu báo **lỗ hổng ảnh hưởng tới correctness hoặc yêu cầu**.

**(7) Mở rộng quy mô.**
- Chạy nhiều phiên trên **git worktree** riêng.
- Fan-out bằng `claude -p` trong vòng lặp shell, hoặc `/batch`.
- `--permission-mode auto` để chạy không người trông. Auto mode có một classifier chặn hành động rủi ro.
- `/sandbox` để cách ly filesystem và network.

**(8) Các kiểu thất bại thường gặp.**
- *Kitchen sink session*: một phiên ôm nhiều việc không liên quan.
- *Sửa đi sửa lại*: context đầy những hướng đã thất bại.
- *CLAUDE.md quá dài.*
- *Trust-then-verify gap*: code trông hợp lý nhưng hổng ở edge case.
- *Khám phá vô hạn*: cho agent "tìm hiểu" mà không giới hạn phạm vi.

### 1.4. Bối cảnh từ chính đội Claude Code

Các bài dưới đây không phải của Lydia, nhưng đến từ cùng đội Claude Code và bổ sung cho các ý trên:

- **Bốn kiểu vòng lặp** ([Getting started with loops](https://claude.com/blog/getting-started-with-loops), Delba de Oliveira và Michael Segner, 30/06/2026):

| Kiểu | Kích hoạt | Dừng khi | Công cụ |
|---|---|---|---|
| Turn-based | Prompt của người | Claude cho là xong | Prompt kèm skill kiểm chứng |
| Goal-based | Prompt, thời gian thực | Đạt mục tiêu hoặc hết số lượt | `/goal` |
| Time-based | Theo chu kỳ | Bạn huỷ, hoặc việc xong (PR merge, queue rỗng) | `/loop` (local), `/schedule` (cloud) |
| Proactive | Sự kiện hoặc lịch, không có người | Mỗi task đạt mục tiêu; routine chạy tới khi tắt | Routines kết hợp `/goal`, skills, workflows, auto mode |

  Lời khuyên của bài: chọn **một** việc mà bạn đang là nút thắt. Hỏi ba câu: có viết được check tự động không? Mục tiêu đủ rõ chưa? Việc có đến theo lịch không? Rồi chạy vòng lặp, quan sát chỗ nó kẹt hoặc làm quá tay, và chỉnh lại.

- **Chuỗi kiểm chứng của đội Claude Code** ([Building verification loops with skills](https://claude.com/resources/articles/building-verification-loops-in-claude-code-with-skills)): `/code-review` (bug) → `/simplify` (dọn code) → `/verify` (hành vi end-to-end) → `/design` (kiểm tra theo `DESIGN.md` nếu có thay đổi UI).

- **Compounding Engineering** ([power user tips](https://support.claude.com/en/articles/14554000-claude-code-power-user-tips)): mỗi lần Claude sai, đưa bài học vào CLAUDE.md dùng chung của cả đội. Các tip khác trong cùng bài: chạy 3–5 phiên song song trên worktree, và đặt `isolation: worktree` cho subagent làm migration lớn.

---

## 2. Lauren Tan, "poteto" (SpaceXAI, trước đây ở Cursor)

### 2.1. Lauren là ai

- Thành viên React core team. Cô làm **React Compiler** ở Meta, từng là tech lead và engineering manager ở Netflix, rồi làm Member of Technical Staff ở **Cursor**. Đây là những gì README của pstack tự giới thiệu.
- Theo mô tả các talk và livestream năm 2026, cô hiện làm ở **SpaceXAI** (nhóm GrokBot) ([GitHub issue tóm tắt talk](https://github.com/peter-trost/emotely/issues/161), [livestream](https://www.youtube.com/watch?v=MN9dGgmLyso)). Mình chưa thấy nguồn chính thức từ SpaceX hay xAI xác nhận chức danh của cô.
- Con số tự báo cáo: khoảng **1.000 PR/tháng** sau 5 tháng ở Cursor ([X](https://x.com/Michaelzsguo/status/2092578668316864525)), rồi talk *"How I Shipped 2,000 PRs Last Month"*. Tiêu đề bài đăng trên X ghi 2.500, còn lịch Cursor Compile London và phụ đề talk ghi khoảng 2.000 ([folkfox](https://folkfox.com/pstack-2500-ai-agent-prs-verification/)). Chưa có bên ngoài nào kiểm toán các con số này.
- Mạng xã hội lan truyền mô tả "đội 15–20+ GrokBot agent" của cô, gồm một Chief of Staff, các manager và worker ([ví dụ](https://x.com/0xMovez/status/2094477810177806468)). **Các con số mâu thuẫn giữa các bài.** Chỉ nên xem đây là minh hoạ cho ý "tổ chức agent như tổ chức người".

### 2.2. Luận điểm trung tâm: giới hạn là *niềm tin*, không phải *số agent*

> "Running more agents before you trust their work only multiplies bad pull requests." ([tóm tắt talk](https://github.com/peter-trost/emotely/issues/161))

pstack được giới thiệu là thứ đem lại **"fearless parallelism"**: khi đã tin được *một* agent viết code tốt và kiểm chứng được, bạn mới song song hoá một cách tự tin. Mục tiêu không phải tối đa số dòng code. Ngược lại, pstack giúp *viết ít hơn nhưng chất lượng cao hơn*.

### 2.3. Kiểm chứng là skill quan trọng nhất

**Verification skill cho từng dự án.** Skill `/create-verification-skill` "phỏng vấn repo, không phỏng vấn người", rồi sinh ra một skill cục bộ gồm 5 phần:

| Phần | Nội dung |
|---|---|
| **Launch** | Lệnh chính xác để khởi động app từ thư mục dữ liệu trống. "Ready" nghĩa là *dùng được*, không chỉ là process đã trả lời |
| **Doctor** | Một check chỉ-đọc: instance này có đáng để drive không (đúng build, đúng port, auth hợp lệ)? |
| **Drive** | Công thức điều khiển với selector và lệnh *thật* của repo. Ưu tiên handle ổn định như ARIA label hay data attribute |
| **Evidence** | Ghi lại *hành động* lẫn *trạng thái kết quả*. Kiểm tra cả side effect (file đã ghi, row đã chèn). Không dùng endpoint chỉ dành cho test |
| **Cleanup** | Chỉ kill thứ mình đã khởi động. Không bao giờ xoá bằng chứng |

Trước khi bàn giao, skill được sinh ra phải **tự chạy thử end-to-end một lần**. *"Một skill chưa từng được chạy là bản nháp, không phải sản phẩm."*

**Feature map.** Đây là chỉ mục gọn của mọi tính năng mà người dùng chạm tới. Mỗi tính năng là một file gồm 4 mục: `Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, `Gotchas`. Feature map biến một bug report mơ hồ thành ca tái hiện được. Nó cần được **làm mới ít nhất mỗi ngày**, tốt nhất bằng automation (`/maintain-verification-skill`), để mô hình của agent không trôi lệch khỏi sản phẩm. Quy tắc quan trọng: **không bao giờ làm yếu hành trình kiểm chứng để nó pass.**

**"Build the lever": làm CLI điều khiển app.** Khi agent cứ viết script vứt đi để click qua app, hãy làm một CLI nhỏ cho skill gọi. Một CLI mà agent dùng tốt có:
- ít lệnh nhưng mỗi lệnh làm việc thật;
- `--dry-run` cho mọi lệnh phá huỷ;
- lỗi chỉ ra cách sửa;
- `--help` đầy đủ;
- output dạng JSON.

**Nguyên tắc "Prove it works".** Kiểm chứng trên *hiện vật thật*: chạy tính năng, đọc giá trị thật, xem diff. Không kiểm chứng bằng proxy, lời tự báo cáo, hay "nó compile được". Câu trả lời tự tin mà không kèm bằng chứng là cờ đỏ. Nếu không chạy được check thì phải nói **"inconclusive"**.

### 2.4. "Trust ladder": sửa lỗi ở tầng cao nhất có thể giữ được nó

Khi phải sửa một agent, hãy đặt bản sửa ở tầng cao nhất có thể. Danh sách dưới đây ghép hai nguồn của Lauren: các tầng trong talk ([tóm tắt](https://github.com/peter-trost/emotely/issues/161): codebase → phân tích tĩnh/CI → rules/skills/review bot → style guide do người review), và thứ tự sửa trong skill `/correct` (kiến trúc → type → lint/CI → test → docs):

1. **Chính codebase.** Agent bắt chước thứ nó nhìn thấy, nên code là bộ nhớ mạnh nhất. Hãy làm cho cách sai *không thể viết ra*: mỗi state có một chủ, mỗi việc có một cách được hỗ trợ, xoá cách cũ và code chết mà agent có thể chép theo.
2. **Type.** Làm cho trạng thái sai không biểu diễn được.
3. **Phân tích tĩnh, lint, CI.** Thông báo lỗi phải **chỉ ra cách đúng** (file, type, hàm nên dùng). Nếu pattern sai đã phổ biến, chỉ fail khi thay đổi *thêm* vào.
4. **Test hành vi.** Test vẫn pass khi mọi hàm trả về `undefined` thì phải viết lại hoặc xoá.
5. **Rules, skills, review bot.** Agent thường làm theo nhưng có thể bỏ qua.
6. **Style guide chỉ được người thực thi khi review.** Tầng này không mở rộng được theo tốc độ ra PR.

Ba quy tắc đi kèm:
- Một lớp lỗi chỉ được tính khi đã xảy ra **2 lần**.
- Phải **chứng minh check mới fail trên một lỗi thật trong quá khứ**.
- Giữ một **bảng "rule ↔ thứ thực thi rule"** trong file chỉ dẫn agent. Bỏ rule khi lỗi của nó không còn xảy ra được.

Nguyên tắc *Encode lessons in structure* nói: *"The instruction is the symptom."* Khi thấy mình viết cùng một chỉ dẫn lần thứ hai, hãy biến nó thành lint, check hay script.

### 2.5. "Người làm vườn" (the gardener)

- Anti-pattern lan rất nhanh. Một workaround được giải thích một lần có thể thành pattern mặc định chỉ trong vài tuần, vì agent chép ví dụ gần nhất.
- Hãy xoá nợ kỹ thuật, giữ **một cách "được ban phước"** cho mỗi việc, và viết lint rule *ngay khi* pattern xấu xuất hiện.
- Nguyên tắc *Migrate callers then delete legacy APIs*: chuyển hết caller và xoá API cũ trong cùng một đợt, không giữ lớp tương thích.

### 2.6. Người viết không bao giờ là người phán xử

- *"The agent that judges a change is never the one that wrote it."* Playbook Shipping cho mỗi PR một agent mới để kiểm chứng hành vi live trước khi merge. Nó chỉ merge **đoạn liên tục đã được kiểm chứng tính từ đáy stack**.
- **Babysit** chỉ đưa PR tới trạng thái merge-ready: xử lý conflict, rồi review thread, rồi CI, gom các bản sửa thành một lần push. Nó **không bao giờ tự merge**, vì "merge là một quyết định khác". Bình luận của bot review được triage một cách hoài nghi: sửa cái thật, bác cái nhiễu kèm lý do cụ thể.
- **Đa model**: skill `/interrogate` cho nhiều model khác nhau cùng cố phá một diff. Quy tắc của pstack: *"A second opinion is the same prompt against a different model. Agreement is high-signal."*

### 2.7. Điều phối subagent

- **Subagent mới cho mỗi việc**, kèm phạm vi đã hợp nhất: brief gốc, mọi chỉ thị sau đó, báo cáo và branch của agent trước. Chỉ resume agent cũ khi cần state đắt để chuyển (checkout cục bộ, dev server đang chạy...).
- **Bạn sở hữu công việc của mọi subagent.** Tự review diff và tự viết tóm tắt, không chuyển tiếp nguyên văn lời subagent nói.
- **Guard the context window**: đẩy khối lượng lớn sang subagent, chỉ giữ tóm tắt ở luồng chính. Truyền đường dẫn file thay vì dán nội dung.
- **Chọn model theo vai**: model nhanh cho code thường, model mạnh nhất cho thay đổi khó nhất và cho phán đoán hay văn bản. Effort tăng cho việc khó, giảm cho việc thường lệ.

### 2.8. Quyền tự chủ

- **Just do it**: việc đảo ngược được thì cứ làm.
- **Always pause** trước các hành động không đảo ngược được: force-push lên nhánh chung, deploy, xoá dữ liệu, nhắn khách hàng.
- *Never block on the human*: nếu câu hỏi "chọn cách nào" có thể trả lời bằng cách *chạy thử*, hãy làm prototype và để kết quả quyết định. Chỉ hỏi người khi đó là lựa chọn sản phẩm hoặc sở thích. Cũng theo nguyên tắc này, "No" là một câu trả lời hợp lệ: thẳng thắn hơn là chiều lòng.

### 2.9. Chạy qua đêm và vòng lặp ngoài

**Phải đạt đủ 4 điều kiện trước khi cho một vòng lặp tự chạy:**
1. Đã làm task này bằng tay một lần, hoặc đã xem agent làm, nên biết "tốt" trông thế nào.
2. Agent có đủ công cụ và tín hiệu bạn sẽ dùng: verification skill, profiler, log.
3. Mọi giai đoạn đều chứng minh được kết quả và **có thể dừng dây chuyền**.
4. Đã đọc vài transcript và biến các lỗi lặp lại thành tool, skill hoặc check.

**"Hợp đồng qua đêm"** gồm: mục tiêu, điều kiện xong, quyền hạn, lối thoát. Ví dụ:
```text
im going to bed. migrate every caller to the new parser in a fresh worktree off <base>.
done means zero old callers, all parser fixtures pass, old api deleted.
keep a decision log. don't ask me before committing.
/loop until done. if you're truly stuck after a few hours, stop and write up why.
```
Cạm bẫy: ***"a duration is not a finish condition"***. "Làm 4 tiếng" sẽ cho bạn 4 tiếng chuyển động, không phải một kết quả.

**Decision log.** Mỗi vòng lặp là một thay đổi, một check, một dòng log. Mỗi dòng TSV ghi thời gian, giai đoạn, quyết định, lý do, con trỏ tới bằng chứng và kết quả. Buổi sáng, một reviewer *khác họ model* đọc log và transcript, rồi trả về mục "Attention" để bạn đọc trước.

**Vòng lặp ngoài (outer loop).** Sự kiện từ Slack, Sentry hay alert sẽ khởi động agent: triage → tái hiện → sửa → kiểm chứng. Gói automation "benny" trong pstack làm đúng việc này. Có hai luật:
- **Mọi giai đoạn đều có thể dừng dây chuyền**, ví dụ triage kết luận đây là hành vi đúng, hay không tái hiện được.
- **Mọi giai đoạn đều bàn giao bằng chứng.**

### 2.10. 24 nguyên tắc của pstack (chọn lọc)

| Nguyên tắc | Nội dung |
|---|---|
| laziness-protocol | Ưu tiên xoá; làm thay đổi nhỏ nhất giải quyết được vấn đề |
| foundational-thinking / model-the-domain | Chốt data structure trước, code phía sau sẽ hiển nhiên |
| build-the-lever | Làm công cụ (codemod, script, generator, skill) thay vì làm tay. Công cụ là thứ reviewer chạy lại được |
| sequence-verifiable-units | Chia việc thành các đơn vị nhỏ, mỗi đơn vị kết thúc ở trạng thái kiểm chứng được |
| test-behavior-not-implementation | Gọi code như người dùng gọi, assert trên giá trị literal |
| explain-the-number | Trước khi tin một con số đo được, tìm xem cái gì giới hạn nó |
| guard-the-context-window | Đẩy khối lượng lớn sang subagent |
| never-block-on-the-human | Làm, trình kết quả, để người sửa hướng sau. Chỉ xin xác nhận với việc không đảo ngược được |
| encode-lessons-in-structure | Biến rule thành lint, flag, runtime check hay script thay vì thêm chữ |

### 2.11. Những quan điểm gây tranh luận

- **"Không tin vào planning"**: *"the best spec is code"*. pstack không có skill lập kế hoạch mặc định mà dùng prototype để trả lời câu hỏi thiết kế. Điều này trái với quy trình explore → plan → code mà Anthropic khuyến nghị (xem mục 3).
- **Tháng 10/2026** Lauren đưa ra giả thuyết rằng *maintainability* không còn quan trọng như trước, vì agent làm cho việc sửa code trở nên rẻ ([X](https://x.com/poteto/status/2109306052495946239)). Hãy coi đây là một giả thuyết đang được thảo luận, chưa phải kết luận. Chính pstack vẫn đặt nặng việc xoá code chết và giữ "một cách được ban phước", vì agent chép những gì nó thấy.

---

## 3. Điểm hội tụ và điểm khác biệt

| Chủ đề | Lydia Hallie / Anthropic | Lauren Tan / pstack | Kết luận cho đội của bạn |
|---|---|---|---|
| Nút thắt | Context window | Niềm tin (trust) | Hai mặt của một vấn đề. Giữ context sạch để agent làm đúng; có bằng chứng để *bạn tin* nó đúng |
| Kiểm chứng | Check chạy được; `/goal`; Stop hook; `/verify` | Verification skill + feature map + control CLI | **Đầu tư vào kiểm chứng trước khi tăng số agent** |
| Ghi nhớ bài học | CLAUDE.md ngắn; hook cho việc bắt buộc; compounding engineering | Trust ladder; `/correct`; bảng rule ↔ thứ thực thi | Ưu tiên cấu trúc > hook/CI > skill > CLAUDE.md |
| Review | Writer/Reviewer, subagent đối kháng, cảnh báo over-engineering | Người phán xử ≠ người viết; đa model; triage bot hoài nghi | Reviewer độc lập, chỉ báo lỗi correctness |
| Song song | Worktree, subagents, agent teams (3–5) | "Fearless parallelism" sau khi có trust; swarm/arena | Song song hoá **việc độc lập, tách file** |
| Kế hoạch | Explore → Plan → Code; bỏ plan nếu diff chỉ một câu | "Best spec is code"; prototype thay vì hỏi | Plan cho việc mơ hồ hoặc nhiều file; prototype cho câu hỏi đo được |
| Tự chủ | Permission modes, auto mode, sandbox | Làm việc đảo ngược được; dừng ở việc không đảo ngược được | Cho phép rộng nhưng có **cổng cứng** cho hành động không đảo ngược được |
| Vòng lặp | turn → goal → time → proactive | Hợp đồng qua đêm, decision log, outer loop | Leo từng bậc. **Không tự động hoá thứ chưa kiểm chứng được** |

---

## 4. Mười nguyên tắc Agentic Engineering cho đội của bạn

1. **Trust trước, song song sau.** Một agent đáng tin có giá trị hơn mười agent phải kèm.
2. **Không có check chạy được thì không giao việc.** Mỗi task phải có điều kiện hoàn thành dạng pass/fail.
3. **Bằng chứng thay cho lời khẳng định.** Kèm lệnh, output và ảnh chụp. Không chạy được check thì báo "inconclusive".
4. **Context là ngân sách.** Một việc một phiên. Đẩy việc đọc nhiều file sang subagent. Sửa sai hai lần thì làm lại từ đầu.
5. **Người viết ≠ người duyệt.** Kiểm chứng bằng agent mới, context mới, nếu được thì model khác.
6. **Sửa ở tầng cao nhất.** Cấu trúc > type > lint/CI > hook > test > skill > CLAUDE.md.
7. **Làm vườn liên tục.** Xoá cách cũ, giữ một cách đúng. Anti-pattern xuất hiện là có lint ngay.
8. **Đơn vị nhỏ, kiểm chứng được.** PR nhỏ, commit có thứ tự, mỗi bước kết thúc ở trạng thái xanh.
9. **Tự chủ có rào chắn.** Việc đảo ngược được thì tự làm. Việc không đảo ngược được phải qua người, và rào chắn này phải do hook hoặc permission thực thi, không chỉ ghi bằng lời.
10. **Leo thang vòng lặp từng bậc.** turn → `/goal` → `/loop` hoặc `/schedule` → proactive. Chỉ leo khi bậc hiện tại đã đáng tin.

---

## 5. Nguồn tham khảo

**Nguồn chính (đã đọc trực tiếp)**
- pstack, Lauren Tan, MIT: <https://github.com/cursor/plugins/tree/main/pstack>. Gồm README, `docs/guide/06-verify-and-ship.md`, `docs/guide/07-overnight.md`, `skills/poteto-mode/SKILL.md`, `skills/create-verification-skill/`, `skills/correct/SKILL.md` và các `principle-*`.
- Claude Code docs: [Best practices](https://code.claude.com/docs/en/best-practices), [Agent teams](https://code.claude.com/docs/en/agent-teams), [Subagents](https://code.claude.com/docs/en/sub-agents), [Hooks](https://code.claude.com/docs/en/hooks), [Skills](https://code.claude.com/docs/en/skills), [/goal](https://code.claude.com/docs/en/goal).
- Anthropic: [Getting started with loops](https://claude.com/blog/getting-started-with-loops), [Building verification loops with skills](https://claude.com/resources/articles/building-verification-loops-in-claude-code-with-skills), [Claude Code power user tips](https://support.claude.com/en/articles/14554000-claude-code-power-user-tips).

**Nguồn thứ cấp (tóm tắt hoặc bài đăng, không truy cập trực tiếp được hết)**
- Lydia Hallie: [X](https://x.com/lydiahallie), [khoá học Claude Code](https://master.dev/courses/claude-code/), [theorg](https://theorg.com/org/anthropic/org-chart/lydia-hallie).
- Lauren Tan:
  - Tóm tắt talk: [GitHub issue tóm tắt talk "trust ladder"](https://github.com/peter-trost/emotely/issues/161), [redreamality](https://redreamality.com/blog/lauren-tan-poteto-trust-before-parallel/), [ratstack](https://ratstack.sh/lore/poteto-lauren-tan-2500-prs-dune), [folkfox](https://folkfox.com/pstack-2500-ai-agent-prs-verification/), [The Neuron](https://www.theneuron.ai/explainer-articles/pstack-explained-lauren-tans-system-for-trustworthy-ai-agents/).
  - Video: [livestream](https://www.youtube.com/watch?v=MN9dGgmLyso), [YouTube](https://www.youtube.com/watch?v=Zc07HI9Ppxk).
  - X: [bài về maintainability](https://x.com/poteto/status/2109306052495946239).
