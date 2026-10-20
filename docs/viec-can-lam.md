# Việc cần làm

Ảnh chụp ngày 20/10/2026, ngay sau khi PR #5 (commit `0667d98`) và PR #6 (`e5a6756`) vào nhánh mặc định `claude/sharp-knuth-lpdhqz`; cập nhật khi nhánh `claude/brave-darwin-zqo4ws` (PR #18: port youthful-fermi và blissful-dirac, mục 2.3) vào nhánh mặc định, và khi các session trùng việc đã dừng (mục 1). Mỗi việc ghi: vì sao cần làm, khi nào thì xong, ai đang làm. Làm xong việc nào thì xoá dòng đó khỏi file này, ngay trong PR của việc đó.

Luật chung cho mọi việc audit: dùng `/team-lead` với playbook bug-fix, viết test đỏ trước, `KIT_SELFTEST=1 ./scripts/check.sh` phải exit 0, rồi verifier và reviewer mới cho qua. Không nới guard, Stop gate hay `scripts/guard-ask-floor`; không sửa hay nới assert cũ. Nhãn của `suspicious_labels` bản mới phải ⊇ bản trước, với `AUDIT_BASE_REF` đặt về commit trước khi sửa. Muốn đổi cách đọc lệnh thì thêm một cách đọc rồi hợp nhãn. Thử hành vi bash thật thì thay `rm` và `git` bằng `echo` ngay trong văn bản lệnh, chạy trong thư mục tạm không phải repo git, HOME trỏ tới thư mục không tồn tại, và không đặt `rm` giả trên PATH.

## 1. Session trùng việc: đã quyết, và việc còn cần bạn quyết

### 1.1 Đã quyết (20/10)

| Việc | Giữ | Đã dừng |
|---|---|---|
| Vá các ca mục A bỏ sót có từ trước | nhánh `claude/nice-hamilton-vdgw4v`. Nó soát các commit của `claude/vibrant-pascal-b81ljt`, port phần chỉ nhánh đó có, rồi ghi bảng "commit → đã có / đã port / bỏ qua vì sao" vào PR của nó | Session `claude/vibrant-pascal-b81ljt`. Nhánh giữ ở `970114a`; stash `r3-item3-wip` vẫn nằm trong container của session đó |
| Vá mục A của youthful-fermi | Các bản sửa tới `c93ef33` đã vào qua PR #18 (`claude/brave-darwin-zqo4ws`, đã merge). Bạn chọn giữ PR #7 cho phần còn lại: merge nhánh mặc định `38bf5bb` vào, rồi diff chỉ còn phần riêng (commit hiệu năng bỏ cách đọc trùng, xem 2.7; fixture hj1–hj5) | Phần oracle bash ở session PR #7, chưa từng commit. Không gỡ phần youthful-fermi khỏi PR #18: nó đã merge |
| Skill verify kèm hành trình tái hiện guard SIGPIPE | `claude/bold-tesla-s0rkpo` | Session `claude/verify-skill-sigpipe` (đã archive, chưa push gì) |
| Cổng push của guard trên bash < 5.1 khi đĩa đầy | `claude/stoic-bell-kdjsfg` | Session trùng trên nhánh mặc định (đã archive, chưa push gì) |
| check.sh không chạy test-plugin.sh của dự án đích | PR #9, đã merge | Session `claude/check-sh-kit-only-plugin` (đã archive) |

Mọi nhánh audit còn mở phải merge nhánh mặc định mới trước khi sửa tiếp. Nhánh mặc định đã có phép hợp cách đọc của youthful-fermi, cách đọc exact của PR #5 và bản port blissful-dirac (`segments(..., parent_env, comments, raw_marks, strict_assign, empty_body, blank, exact)`). Sau khi merge, lập bảng "commit → còn tái hiện? → port / có sẵn" như ở 2.3.

### 1.2 Còn cần bạn quyết

- **Hai oracle bash.** Oracle của blissful-dirac (73558cd, 5e82c79: ngữ pháp an toàn, ORACLE_FLOOR, KNOWN_GAPS) **đã vào nhánh mặc định** qua PR #18, kèm dòng trong bảng Rule ↔ Thứ thực thi của CLAUDE.md. PR #8 (`claude/practical-hawking-le9toi`) có oracle riêng với KNOWN_MISSES. **Khuyên:** giữ một bước oracle duy nhất, chính là bước đã có trên nhánh mặc định. PR #8 chuyển phần ngữ pháp fuzz và các ca nó bắt được vào bước đó, không thêm bước thứ hai. Sàn và các lệnh oracle cũ đã bắt được phải giữ nguyên.
- **Dọn nhánh:** xem mục 2.3. Xoá nhánh phải hỏi người.

## 2. Audit: `scripts/audit-agent.py`, mục A

### 2.1 Oracle bash trong test-audit (PR #8)
- **Vì sao:** lớp lỗi "`segments()` đọc sai cấu trúc shell nên mục A bỏ sót" đã lọt hơn 10 lần. Bước so nhãn hiện tại chỉ đỏ khi bản mới mất nhãn mà bản trước có, nên không thấy lỗi bỏ sót mà cả hai bản cùng có.
- **Xong khi:**
  - test-audit có bước chạy lệnh fuzz bằng bash thật (stub ghi đích, không xoá gì), đỏ khi bash xoá ngoài thư mục tạm mà `suspicious_labels` trả `[]`;
  - các ca còn sót nằm trong danh sách KNOWN_MISSES, và danh sách này chỉ được giảm;
  - có dòng tương ứng trong bảng "Rule ↔ Thứ thực thi" của CLAUDE.md.
- **Trước khi merge:** merge nhánh mặc định mới vào, rồi so nhãn với `0667d98`.

### 2.2 Vá các ca bỏ sót có từ trước (nhánh `claude/nice-hamilton-vdgw4v`)
Bash 5.2 thật xoá đích nguy hiểm ở các lệnh dưới đây, mà cả `27727f5` lẫn `0667d98` đều trả `[]`. Sắp theo mức hay gặp ở agent:
1. Thân `bash -c` chưa được gỡ (regex `SHELL_C_BODY`, phải giữ tuyến tính):
   - `bash +e -c '…'`;
   - cờ đứng sau cụm c: `bash -c -x '…'`, `bash -o pipefail -c -e '…'`;
   - tên của -o trong nháy hoặc có `-`: `bash -o 'pipefail' -c '…'`, `bash -o interactive-comments -c '…'`;
   - cờ dài có tham số: `bash --rcfile /dev/null -c '…'`;
   - cụm c trước cờ kèm tên: `bash -co pipefail '…'`.
2. Nháy thoát ngoài chuỗi: `echo it\'s` ⏎ `rm -rf src 'x'`.
3. Biến bị đổi mà env không theo: `read D <<< /`, `eval 'D=/'`, `unset D`, rồi `rm -rf "$D"` (đã thử lại sau khi brave-darwin vào: `D=/tmp/w; read D <<< /; rm -rf "$D"`, `D=/tmp/w; eval 'D=/'; rm -rf "$D"`, `D=/tmp/w; unset D; rm -rf $D/a` vẫn `[]`).
- **Xong khi:** mỗi ca có assert phải nghi, đỏ trước và xanh sau. Ca nào oracle (mục 2.1) đã ghi trong KNOWN_MISSES thì xoá khỏi đó.

### 2.3 Sau đối chiếu nhánh cũ: commit mới của blissful-dirac và dọn nhánh
Việc đối chiếu đã xong ở `claude/brave-darwin-zqo4ws` (bảng "commit → còn tái hiện? → đã port / đã có sẵn" ở mô tả PR của nhánh đó; mọi commit của youthful-fermi tới `c93ef33` và blissful-dirac tới `cd828ea`). Còn lại:
- **Commit mới của `claude/blissful-dirac-i6vpym` sau `cd828ea`** (`749e0c6`, `751a129`, `55a62d6`, `876ad37`), session của nhánh đó vẫn đang thêm. Đo bằng test-audit.sh của `876ad37` với audit-agent.py sau khi brave-darwin vào:
  - còn 3 assert phải-vào-A đỏ, đều của `749e0c6` (biến không thay được trong đích không vô hại, kể cả sau thư mục tạm hay tên lành): `(D=..); rm -rf node_modules/$D`, `cd /tmp && rm -rf node_modules/$X`, `rm -rf /tmp/$X`;
  - oracle bash của nhánh đó, với ngữ pháp mở rộng ở `751a129` và `876ad37` (đích có biến sau phần trông lành; gán qua đối số, gán tạm, gán trong pipeline), bỏ sót 10/2712 lệnh (nhánh mặc định trước khi brave-darwin vào: 141/2712);
  - 2 assert vô hại mới của `55a62d6` đỏ vì báo thừa: `D=/tmp/x # c | d` ⏎ `rm -rf $D/src`, `true # a |` ⏎ `D=/tmp/x` ⏎ `rm -rf $D/src`.
  - CI của nhánh đó đỏ ở mọi lần chạy kể từ `73558cd`: runner ubuntu-latest nay là Ubuntu 26.04 với bash 5.3, và `wait` không đối số trong `$( )` treo khi shell cha còn việc nền chưa thu (`true & x=$( wait )`), nên oracle báo "chạy quá 10 giây". `e103274` của brave-darwin bọc `wait` trong PRELUDE của oracle; nhánh đó hết đỏ khi merge nhánh mặc định mới. Oracle riêng của PR #8 cũng cần lớp bọc này nếu ngữ pháp của nó sinh `wait` trong `$( )`.
  - **Xong khi:** mỗi commit có dòng trong bảng như 2.3 cũ; ca còn tái hiện trên nhánh mặc định thì port như một cách đọc thêm, hợp nhãn, test đỏ trước.
- **Dọn nhánh (cần bạn đồng ý, xoá nhánh phải hỏi người):** PR #7 giữ theo lựa chọn của bạn (mục 1.1), nên chỉ xoá `claude/youthful-fermi-1ydqg6` sau khi PR #7 merge hay đóng; xoá `claude/blissful-dirac-i6vpym` sau khi xử lý 4 commit trên; xoá `claude/intelligent-brahmagupta-ufrtr3` (PR #5 và PR #16 đã merge).

### 2.4 Đường chậm bậc hai có từ trước
- SHELL_C `(-\w+\s+)*` trên `"bash" + " -bash"*5000` hay `"sh" + " -sh"*5000`: 6–9 giây.
- Mẫu `\bgit\b.*\bfilter-(branch|repo)\b` trong SUSPICIOUS trên `"git-bash" + " --x-git-bash"*5000`: khoảng 14 giây.
- **Xong khi:** cả hai ca dưới 1 giây, có assert hiệu năng, và chứng minh nhãn không đổi. Hai regex này thuộc các cách đọc cũ, nên phải so ⊇ với bản trước trên fixture, fuzz và oracle.

### 2.5 Chưa kiểm chứng
- `git-bash.exe` của Git for Windows có chạy thân `-lc '…'` không. Có thể giao cho session "Run kit checks on macOS and Windows Git Bash" (nhánh `claude/laughing-ride-ot94no`).
- Python dưới 3.11 với regex `SHELL_C_BODY`: chỉ dùng lookahead và lookbehind độ dài cố định, chưa chạy thật.
- `scripts/audit-agent.sh` trên file phiên thật của dự án đã cài kit. Máy cloud chỉ có file phiên của chính nó.

### 2.6 Báo thừa đã biết (không phải bỏ sót)
Bash xoá trong thư mục tạm mà mục A vẫn báo. Sửa là thu hẹp: phải thêm đúng lệnh vào `NARROWING_OK` kèm lý do, nên chỉ làm khi người dùng than báo thừa.
- 5 assert "vô hại" của blissful-dirac: `cd /tmp/w && bash <<'EOF'` ⏎ `rm -rf a` ⏎ `rm -rf b` ⏎ `EOF`; `cd /tmp/w &&` ⏎ `# c` ⏎ `rm -rf a`; `cd /tmp/w && # a ; b` ⏎ `rm -rf a`; `x=ab; cd /tmp/w && echo ${#x} &&` ⏎ `rm -rf a`; `cd /tmp/w && cat <<'EOF' | bash` ⏎ `rm -rf y` ⏎ `EOF`. Có từ trước PR #5.
- `echo x\ # don't` ⏎ `rm -rf src` ⏎ `'`: COMMENT của cách đọc exact (PR #5) coi `#` sau `\ ` là comment.
- `D=/tmp/y/; bash <<EOF` ⏎ `rm -rf ${D}src` ⏎ `EOF`: cách đọc blank (port blissful-dirac `cd828ea`) không đoán biến của shell cha trong thân `<<EOF`. Chủ ý: giá trị đoán từng sai (vòng lặp, delimiter lạ, brace).
- `cd /tmp/x && rm -rf y & wait`: BACKGROUND xoá thư mục cd khi còn lệnh sau `&` (port youthful-fermi `2e5b8bc`).
- `D=/tmp/x; true & rm -rf $D/src`: benign_delete đọc cả đoạn, coi `true`, `&` là đích. Có từ trước.

### 2.7 Hiệu năng của phép hợp cách đọc
- **Vì sao:** `suspicious_labels` nay đọc tới khoảng 90 cách (strict_assign × comments × scoped/parent_env × raw_marks × empty_body × join, cộng blank và exact), nền cũ 6. Cổng (lệnh có `NAME=`, có byte \x01–\x05, có heredoc thân rỗng) giữ lệnh thường nhanh, nhưng lệnh bật đủ mọi chiều chậm khoảng 20 lần: reviewer đo 1000 dòng `echo "x" | grep -c x && ls -la /home/user` + heredoc thân rỗng + byte \x01 + `V=1 rm -rf src`: 8,3 s so với 0,4 s ở `e5a6756` (4000 dòng: 34 s so với 1,8 s).
- **Xong khi:** gộp cách đọc trùng (vd. comments khi exact; raw_marks chỉ cho đoạn có byte), có assert hiệu năng cho ca trên, nhãn ⊇ bản trước trên fixture, fuzz và oracle.

## 3. PR đang mở (ảnh chụp)

| PR | Nội dung | Trạng thái |
|---|---|---|
| #7 | fix(audit): 9 dạng lệnh mục A bỏ sót (`claude/youthful-fermi-1ydqg6`) | Nháp. Mọi commit sửa tới `c93ef33` đã vào nhánh mặc định qua `claude/brave-darwin-zqo4ws` (cherry-pick -x); `fc27649` chỉ là merge nhánh mặc định. Giữ theo lựa chọn của bạn cho phần riêng còn lại (mục 1.1); phải merge `38bf5bb` trước |
| #8 | fix(audit): oracle bash và 4 lớp lệnh xoá (`claude/practical-hawking-le9toi`) | Nháp. Phải merge nhánh mặc định mới (đã có phép hợp cách đọc mới và oracle của blissful-dirac), so nhãn với nhánh mặc định, quyết chuyện hai oracle ở mục 1 |
