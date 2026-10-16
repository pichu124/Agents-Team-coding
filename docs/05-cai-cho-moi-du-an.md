# Cài đội agent cho mọi dự án (plugin)

Cài kit vào từng repo (`install-kit.sh`) chỉ có tác dụng trong repo đó. Bản **plugin** cài một lần trên mỗi máy, rồi có tác dụng ở mọi dự án bạn mở bằng Claude Code: `claude` trong terminal, và phiên Local trong tab Code của app Claude (hai nơi đọc cùng file settings trên máy).

## Plugin cho gì, không cho gì

| Thành phần | Ở dự án chưa cài kit | Ở dự án đã tự cài kit (vd `C:\vnstock-trial`) |
|---|---|---|
| 5 agent | Có, tên có tiền tố: `agent-team:architect`, `agent-team:implementer`, `agent-team:verifier`, `agent-team:reviewer`, `agent-team:gardener` | Có cả hai bản. `/team-lead` của dự án gọi bản không tiền tố |
| 4 skill | `/agent-team:team-lead`, `/agent-team:correct`, `/agent-team:create-verify-skill`, `/agent-team:agent-audit` | Có cả `/team-lead` (của dự án) lẫn `/agent-team:team-lead`. Dùng `/team-lead` |
| Guard hỏi trước hành động không đảo ngược được | Có | Hook của dự án chạy, plugin **nhường** nên bạn chỉ thấy **một** hộp hỏi |
| Stop gate | Chỉ ở dự án có `scripts/check.sh` | Hook của dự án chạy, plugin nhường |
| Format sau khi sửa file | Chỉ khi dự án đã cấu hình formatter | Hook của dự án chạy, plugin nhường |
| Chặn đọc `.env`, `*.pem`, `secrets/` | **Không**: plugin không được mang luật quyền | Có (luật trong `.claude/settings.json` của dự án) |

Ở dự án chưa có `scripts/check.sh`, `/agent-team:team-lead` lấy lệnh lint và test trong CLAUDE.md, README hoặc CI làm "lệnh check", và ghi lệnh đó vào hợp đồng. Không tìm được lệnh nào thì phần chưa kiểm được báo INCONCLUSIVE.

Không có tác dụng ở phiên cloud (claude.ai/code): máy ảo cloud không đọc plugin cài trên máy bạn. Mỗi phiên tốn thêm khoảng 650 token cho phần mô tả agent và skill.

## Cài: làm trên cả 💻 laptop và 🖥️ desktop

Plugin cài theo máy và không đi qua Dropbox, nên máy nào cũng phải cài. Mở PowerShell (không cần venv):
```powershell
claude --version
claude plugin marketplace add pichu124/Agents-Team-coding
claude plugin install agent-team@agents-team-coding --scope user
claude plugin list
```
Dòng cuối phải thấy `agent-team@agents-team-coding` với trạng thái enabled. Sau đó đóng mọi phiên Claude đang mở, kể cả app trên desktop, rồi mở lại.

Trong app, bấm nút **+** cạnh ô nhập rồi chọn **Plugins**. Mục quản lý plugin ở đó cũng thấy `agent-team`; bật, tắt hay gỡ làm được ngay trong app.

## Kiểm tra sau khi cài (khoảng 5 phút mỗi máy)

Mở Claude ở một repo **chưa cài kit**, ví dụ `C:\vnstock` (nhánh `main`):

1. Gõ: `Không chạy lệnh nào. Liệt kê tên các agent type bạn có.` Danh sách phải có 5 dòng bắt đầu bằng `agent-team:`.
2. Gõ `/agent-team:`. Ô gợi ý phải hiện 4 skill.
3. Gõ: `Chạy đúng lệnh này: git push --force origin khong-co-nhanh-nay`. Phải hiện hộp hỏi "Hành động không đảo ngược được (force-push hoặc xoá nhánh remote)". Chọn từ chối. Lỡ bấm duyệt cũng vô hại, vì nhánh này không tồn tại.
4. Làm lại bước 3 trong `C:\vnstock-trial`. Phải hiện **đúng một** hộp hỏi.

Bước nào sai thì chụp màn hình gửi cho người hỗ trợ, kèm output của `claude plugin list`.

## Cập nhật

Plugin không ghim phiên bản, nên mỗi commit mới trên GitHub là một bản cập nhật. Claude Code không tự cập nhật plugin của bên thứ ba, nên khi có bản mới thì chạy trên từng máy:
```powershell
claude plugin marketplace update agents-team-coding
claude plugin update agent-team@agents-team-coding
```
Rồi mở lại phiên Claude, hoặc gõ `/reload-plugins` trong phiên đang mở.

Bản kit chép trong `C:\vnstock-trial` vẫn cập nhật như cũ bằng `git pull`, vì repo đó tự cài kit.

## Tắt hoặc gỡ

```powershell
claude plugin disable agent-team@agents-team-coding     # tắt tạm, giữ nguyên bản cài
claude plugin enable agent-team@agents-team-coding
claude plugin uninstall agent-team@agents-team-coding   # gỡ hẳn
```
Đừng chạy `claude plugin marketplace remove agents-team-coding` nếu chỉ muốn tắt: lệnh đó gỡ luôn plugin.

## Dò sự cố cho mọi dự án

`--all` đọc file phiên của mọi dự án trên máy. Mỗi dòng trong báo cáo ghi thư mục nơi lệnh chạy. Cách nhanh nhất là dùng bản script trong `C:\vnstock-trial` (lấy `$bash` như ở mục 11 của [docs/04](04-thu-nghiem-vnstock-dashboard.md)):
```powershell
cd C:\vnstock-trial
& $bash scripts/audit-agent.sh --all --since 1
```
Hoặc trong Claude, ở bất kỳ dự án nào, gõ `/agent-team:agent-audit 1`. Skill này lập cùng báo cáo đó. Nếu mục A, B, H hoặc F có dòng, nó viết test, sửa, rồi mở PR nháp. Lỗi nằm ở dự án chưa cài kit thì bản sửa thuộc repo kit này.

Mục H sẽ có nhiều dòng nếu `--since` lùi về trước ngày cài plugin: lúc đó các dự án khác chưa có guard. Sau khi cài, dùng `--since 1`.

## Cơ chế (cho người bảo trì kit)

- `.claude-plugin/marketplace.json` khai marketplace `agents-team-coding` với một plugin `agent-team`, nguồn là gốc repo. `.claude-plugin/plugin.json` trỏ thẳng vào `.claude/agents/*.md` và `.claude/skills/`, nên plugin và bản cài vào dự án dùng chung một bộ file.
- Hook đi qua `plugin/run-hook.sh <tên>`. Script này nhường cho hook của dự án chỉ khi lần đăng ký đó có hiệu lực cho đúng lần gọi: dự án có `.claude/hooks/<tên>.sh`, `.claude/settings.json` hoặc `settings.local.json` đọc được, đăng ký hook đó ở đúng sự kiện, và matcher khớp tool (dự án cài kit cũ có matcher chỉ `Bash` thì plugin vẫn canh lệnh PowerShell). Không đọc được JSON (thiếu Python) thì không nhường. Claude Code không gộp hook trùng giữa plugin và settings, nên thiếu bước nhường thì guard hỏi hai lần và Stop gate chạy check hai lần.
- Thêm agent mới thì phải thêm vào `agents` trong `plugin.json`, vì trường này không nhận thư mục. `scripts/validate-kit.sh` báo lỗi nếu quên, nếu `hooks.json` lệch với `settings.json`, hoặc nếu có ai ghim `version`.
- `scripts/test-plugin.sh` test việc nhường, và chạy `claude plugin validate` khi máy có `claude`.
