# Việc cần làm

Ảnh chụp ngày 21/10/2026, sau khi gom mọi nhánh về nhánh mặc định `main` (tên cũ `claude/sharp-knuth-lpdhqz`, đổi ngày 22/10) (đầu nhánh lúc ghi: `083c8e9`, sau PR #26). Mỗi việc ghi: vì sao cần làm, khi nào thì xong, ai đang làm. Làm xong việc nào thì xoá dòng đó khỏi file này, ngay trong PR của việc đó.

Luật chung cho mọi việc audit: dùng `/team-lead` với playbook bug-fix, viết test đỏ trước, `KIT_SELFTEST=1 ./scripts/check.sh` phải exit 0, rồi verifier và reviewer mới cho qua. Không nới guard, Stop gate hay `scripts/guard-ask-floor`; không sửa hay nới assert cũ. Nhãn của `suspicious_labels` bản mới phải ⊇ bản trước, với `AUDIT_BASE_REF` đặt về commit trước khi sửa. Muốn đổi cách đọc lệnh thì thêm một cách đọc rồi hợp nhãn. Oracle bash chỉ có một bước, là bước đã có trên nhánh mặc định: không hạ `ORACLE_FLOOR`, `KNOWN_GAPS` chỉ được giảm. Thử hành vi bash thật thì thay `rm` và `git` bằng `echo` ngay trong văn bản lệnh, chạy trong thư mục tạm không phải repo git, HOME trỏ tới thư mục không tồn tại, và không đặt `rm` giả trên PATH.

## 1. Gom nhánh về nhánh mặc định (xong 21/10)

Đã gộp hết: PR #8, #22, #24, #25, #26. Nhánh của các PR đó xoá được, session của PR #8, #22, #24, #26 đã archive. Còn hai nhánh, giữ lại vì là nơi duy nhất còn commit gốc của việc dở. Xoá khi việc ở mục tương ứng xong, hoặc sau khi đánh tag `archive/<tên nhánh>` cho đầu nhánh.

| Nhánh | Giữ commit gì | Xoá khi |
|---|---|---|
| `claude/vibrant-pascal-b81ljt` | 970114a (bộ nhận `heredocs_word`, mốc so nhãn của P2) | xoá được: P2 đã port (cách đọc bash) |
| `claude/blissful-dirac-i6vpym` | 55a62d6, 73226cf, 5b32600, 98b74d0, 876ad37, 78e474a, WIP e69f5dd | xoá được: 2.3 đã port (cách đọc pure, fixture s101–s143, lô oracle var_trap2) |

Chạy lần lượt từng session: ngày 20/10 và 21/10, nhiều session chạy song song đã làm tài khoản chạm giới hạn dùng 5 giờ, và cả nhóm cùng dừng giữa chừng.

## 2. Audit: `scripts/audit-agent.py`, mục A

### 2.1 Gộp hai oracle bash thành một bước
- **Vì sao:** sau PR #8, test-audit có hai bước oracle: bước chung (blissful-dirac: ORACLE_FLOOR, KNOWN_GAPS) và bước của PR #8 (thư mục `$tmp/oracle-pr8`, KNOWN_MISSES chỉ được giảm, nhận bằng hằng MARK). Hai bước bổ sung cho nhau, không trùng: ngữ pháp của PR #8 sinh đúng các cấu trúc mà KNOWN_GAPS của bước chung loại ra (thân `bash -c` có biến hay lồng nhau, nháy lẻ trong comment hay thân heredoc, heredoc chưa đóng hay thân rỗng, gán trong khâu ống hay sau `&&`/`||`, `\` cuối dòng, `builtin cd`, cd lỗi). Số ca sót trên từng bản audit-agent.py (oracle PR #8 / oracle chung): 27727f5 69/25, 0667d98 6/13, 9bd03a3 0/10, 53f3ff2 0/0. Cộng lại hai bước mất khoảng 40–50 giây trên CI.
- **Cần biết khi gộp:**
  - Cách chặn rm khác nhau. Bước chung đặt `fakerm` trên một PATH chỉ có bash và cat; PR #8 thay chữ `rm` trong văn bản lệnh bằng đường dẫn tuyệt đối tới stub. `bash -l` có thể đặt lại PATH, nên mảnh `bash -lc` của PR #8 chỉ an toàn với cách thay trong văn bản: gộp thì dùng cách đó, hoặc bỏ `-l`.
  - Thư mục: PR #8 thay `/tmp/` bằng `<chỗ>/tmp/`, cwd là `<chỗ>/p` có sẵn `p/src`; nguy khi normpath(PWD + đích) nằm ngoài `<chỗ>/tmp`. Ngữ pháp PR #8 không dùng tên vô hại (dist, node_modules), còn bước chung coi build là vô hại.
  - Job nền: PR #8 đọc stdout tới EOF rồi `killpg`, mỗi lần gọi stub ghi ra `log.$$` riêng; ngữ pháp PR #8 không có `wait` hay `$( )` nên không cần lớp bọc e103274.
  - KNOWN_MISSES chứa lệnh đã sinh mà vẫn sót; KNOWN_GAPS chứa cấu trúc không sinh. Gộp thì giữ một luật chỉ được giảm, đổi MARK cho khớp.
- **Xong khi:** còn một bước oracle, ngữ pháp là hợp của hai bên, không mất lệnh nào mà một trong hai bước đang bắt, một dòng trong bảng Rule ↔ Thứ thực thi của CLAUDE.md.

### 2.4 Đường chậm bậc hai có từ trước
- Mọi bản đều chậm: các mẫu SUSPICIOUS dạng `\bX\b.*Y` (`"helm "*10000` 110 giây, checkout 103, push 93, docker 49, gh 45, branch 41); SHELL_WORD (`"bash "*10000 + "; cat <<EOF"` 22,6 giây); HEREDOC cũ (`"<<A "*5000` khoảng 3 giây; cả trên here-string: `"wc <<< x; "*8000` 3,9 giây, gấp đôi độ dài chậm ~3,5 lần, gần như hết ở `.sub` của HEREDOC/HEREDOC_STRICT trong keep_shell_heredocs các cách đọc không phải bash; ca `*5000` đã mất 4,1 giây trên runner Windows, nên assert here-string nay đo riêng cách đọc bash theo tỉ lệ); QUOTED cũ (`'\\"'*20000` khoảng 52 giây).
- `expand` là O(số biến × số đoạn có `$`), mỗi cách đọc một lượt: `" ".join("v%d=1" % i for i in range(5000)) + "; " + "echo $x; " * 5000` 13,7 giây (31893fb 11,4 giây; cách đọc strict thêm một lượt); `"unset v0 … v4999; " + "echo $x; " * 5000` 3,1 giây (31893fb 0,24 giây: cách đọc strict ghi 5000 tên bị unset thành biến rỗng). Đoạn không có `$` thì expand đã bỏ qua: hai lệnh trên với `true; ` thay `echo $x; ` mất 4,6 và 2,7 giây ở b06eb79 (31893fb 2,3 và 0,1 giây), nay 0,3 giây, có assert.
- Các assert tốc độ khác của test-audit.sh có ngưỡng tuyệt đối (1–6 giây, và `slow` > 3 giây) chỉ in thời gian khi đỏ, nên log CI không cho biết chúng cách ngưỡng bao xa trên Windows hay macOS (30 lần chạy tới 22/10 chỉ đỏ ở assert here-string). Cái nào đỏ oan trên runner chậm thì đổi sang tỉ lệ n và 4n như assert here-string, chứng minh vẫn đỏ với bản bậc hai.
- **Xong khi:** mỗi ca dưới 1 giây, có assert hiệu năng, nhãn không đổi. Các regex này thuộc cách đọc cũ, nên phải so ⊇ với bản trước trên fixture, fuzz và oracle.

### 2.5 Chưa kiểm chứng
- `git-bash.exe` của Git for Windows có chạy thân `-lc '…'` không.
- Python dưới 3.11 với các regex mới (chỉ lookahead, lookbehind độ dài cố định, backref, `(?m)` ở đầu mẫu).
- zsh, PowerShell, git-bash.exe: chưa có oracle thật. bash dưới 5.2 chỉ được giả lập bằng `shopt -u globskipdots`. ORACLE_FLOOR đo trên bash 5.2, chưa chạy bash 3.2 hay 4.x thật.
- `scripts/audit-agent.sh` trên file phiên thật của dự án đã cài kit. Máy cloud chỉ có file phiên của chính nó.

### 2.6 Báo thừa đã biết (không phải bỏ sót)
Bash xoá trong thư mục tạm mà mục A vẫn báo. Sửa là thu hẹp: phải thêm đúng lệnh vào `NARROWING_OK` kèm lý do, nên chỉ làm khi người dùng than báo thừa.
- 5 assert "vô hại" của blissful-dirac: `cd /tmp/w && bash <<'EOF'` ⏎ `rm -rf a` ⏎ `rm -rf b` ⏎ `EOF`; `cd /tmp/w &&` ⏎ `# c` ⏎ `rm -rf a`; `cd /tmp/w && # a ; b` ⏎ `rm -rf a`; `x=ab; cd /tmp/w && echo ${#x} &&` ⏎ `rm -rf a`; `cd /tmp/w && cat <<'EOF' | bash` ⏎ `rm -rf y` ⏎ `EOF`. Có từ trước PR #5.
- `echo x\ # don't` ⏎ `rm -rf src` ⏎ `'`: COMMENT của cách đọc exact (PR #5) coi `#` sau `\ ` là comment.
- `D=/tmp/y/; bash <<EOF` ⏎ `rm -rf ${D}src` ⏎ `EOF`: cách đọc blank (port blissful-dirac `cd828ea`) không đoán biến của shell cha trong thân `<<EOF`. Chủ ý: giá trị đoán từng sai (vòng lặp, delimiter lạ, brace).
- `cd /tmp/x && rm -rf y & wait`: BACKGROUND xoá thư mục cd khi còn lệnh sau `&` (port youthful-fermi `2e5b8bc`).
- `D=/tmp/x; true & rm -rf $D/src`: benign_delete đọc cả đoạn, coi `true`, `&` là đích. Có từ trước.
- Fixture s112 `true # a |` ⏎ `D=/tmp/x` ⏎ `rm -rf $D/src`, s113 `D=/tmp/x # c | d` ⏎ `rm -rf $D/src` (`|` trong comment là chữ), s124 `D=/tmp/x; unset D | true; rm -rf $D/src` (unset trong ống chạy ở shell con): blissful-dirac (55a62d6, 73226cf) assert vô hại, nền đã báo trước khi port. Cách đọc pure không thể bớt nhãn (chỉ hợp), nên ba lệnh này vẫn bị báo.
- s125 `D=/tmp/x; D= true; rm -rf $D/src`: cách đọc pure (P3) coi gán tạm làm biến thành không biết, như việc P3 yêu cầu; bash giữ D là /tmp/x.
- Cách đọc pure coi phép gán trong subshell, lệnh ghép hay thân hàm là không biết cả bên trong lẫn sau đó (không có ngăn xếp env cho `(`/`)`): `(D=/tmp/w; rm -rf $D/x)` bị báo.
- Sau khi 357c9ce (port blissful-dirac 749e0c6) vào: `rm -rf "$TMPDIR/x"`, `rm -rf $HOME/.cache/pip`, `cd /tmp && rm -rf node_modules/$PKG`, PowerShell `$env:TEMP\x` bị báo, vì đoạn xoá còn biến chưa thay được thì không vô hại.

### 2.8 Lỗ mà mọi bản đều bỏ sót (bash 5.2 thật xoá, chưa ai làm)
Mỗi lỗ xong khi có fixture vào A và oracle sinh được dạng đó.
- Hàm gọi sau một phép gán chắc chắn chạy: `D=/tmp/x; f() { D=..; }; D=/tmp/x; f; rm -rf node_modules/$D`. Cách đọc pure nay bắt (gọi hàm đã định nghĩa làm mọi biến thành không biết); còn thiếu fixture và oracle.
- `\;` hay `\|` làm SPLIT tách sai nên `fi` bị trừ độ sâu: `if false; then echo a\; fi; D=/tmp/x; fi; rm -rf $D/src`. Cách đọc pure nay bắt ca này; còn thiếu fixture và oracle.
- `for D in ..; do :; done; rm -rf node_modules/$D`.
- `read D </dev/null; rm -rf $D/src`.
- `D=/tmp/w; D+=/../..; rm -rf $D`: ASSIGN không nhận `+=`, nên mọi bản giữ D là /tmp/w và trả `[]`; bash xoá `/tmp/w/../..`, tức `/`. Cách đọc pure nay bắt (`D+=` làm D thành không biết); còn thiếu fixture và oracle.
- Delimiter heredoc không phải `[A-Za-z_]\w*` (`EOF.x`, `EOF-1`), CRLF: cách đọc bash (P2) nay bắt (MISSED_VP 46–48, 62); oracle chung chưa sinh (KNOWN_GAPS).
- `\$D` và `'$D'` là chữ.
- `D=/; rm -rf /tmp/$D`: xoá chính /tmp, luật under_temp coi là vô hại.
- `git checkout .&`: mẫu nhãn `\.(\s|$)` không nhận `&`.
- Từ báo cáo của PR #8: `(export D=/tmp/w && cd /tmp/w/s)` ⏎ `rm -rf ${D}src`; `true || { cd /tmp/w; D=/tmp/w/; } && rm -rf ${D}src` (cách đọc pure nay bắt, còn thiếu oracle); `rm -rf {,/}src`.
- Reviewer của cách đọc pure (PR P3): `D="/tmp/w"/../..; rm -rf $D` (ASSIGN chỉ lấy phần trong nháy; bash xoá `/`); `D=/tmp/x; ((x=1,D=0)); rm -rf $D/src` (strict bỏ qua, bash xoá `0/src`); alias với `shopt -s expand_aliases`; hàm tên có `!` hay `{` (`a!b() { D=/; }; D=/tmp/x; a!b; rm -rf $D/src`). Mọi bản trả `[]`.
- Reviewer của cách đọc bash (P2): here-string và heredoc trên cùng một dòng (`cat <<EOF; bash <<< 'rm -rf src'` ⏎ `hello` ⏎ `EOF`: thân here-string chèn sau dòng mở rồi bị thân EOF nuốt); command_subs dừng ở `)` đầu tiên như 970114a (`$(echo ')'; rm -rf src)`, `$(case a in a) rm -rf src;; esac)`, `$( (true); rm -rf src)` trong thân `<<EOF` dữ liệu). Bash xoá src, mọi bản trả `[]`.
- `su -c 'rm -rf src'`; `rm -rf {/tmp/a,/}`; `| /bin/bash`; nameref, trap, hàm.
- Heredoc lồng trong thân heredoc đưa vào shell: HEREDOC_STRICT chỉ nhận toán tử ngoài cùng, thân lồng đọc như lệnh của thân ngoài. `bash <<'A'` ⏎ `bash <<X -c 'rm -rf /'` ⏎ `X` ⏎ `A` (bash xoá /); `D=/; bash <<'EOF'` ⏎ `D=/tmp/w; bash <<EOF2` ⏎ `rm -rf \$D/x` ⏎ `EOF2` ⏎ `EOF` (bash xoá /x: thân EOF2 không nháy để `$D` cho shell cháu, nơi D không export là rỗng). Mọi bản trả `[]` (đã thử 3b87a56, 4fba736, 13b4f43, af91da1, 31893fb và bản có bản so mẫu thứ hai cho thân <<EOF). Nhận thân lồng ngay trong cách đọc strict thì thân dữ liệu lồng (`cat <<X` trong thân) thôi là lệnh, mất nhãn mà bản trước báo: cần một cách đọc thêm rồi hợp nhãn.
- `\` trong cờ: `rm \-rf /x` (bash xoá /x), cả trong thân <<EOF: `O=-rf; bash <<EOF` ⏎ `rm \\$O /x` ⏎ `EOF` (shell cha đổi `\\` thành `\`, shell con bỏ `\`: xoá /x). Mọi bản trả `[]`: mẫu xoá đệ quy so trên chữ còn `\` (`\s-\w*r` không khớp `\-rf`).
- `cat <<'EOF' | X=1 bash`, `cat <<'EOF' | env bash` ⏎ `rm -rf /x` ⏎ `EOF`: PIPE_SHELL chỉ nhận shell ngay sau `|`, nên thân thành dữ liệu (bash xoá /x; mọi bản trả `[]`).
- Biến ở vị trí cờ hay tên lệnh mà giá trị không học được: trong nháy kép `X=-rf; rm "$X" /x`, `X=rm; "$X" -rf /x`; biến không biết `read O <<< -rf; rm $O /x`, `O=$(echo -rf); rm $O /x`; giá trị mặc định `rm ${O:--rf} /x` (bash xoá /x; mọi bản trả `[]`).
- **Thay biến trong thân `<<EOF` không nháy đưa vào shell (cách đọc `strict`), còn để ngỏ khi nhánh tích hợp mở PR.** Reviewer chặn ba vòng liên tiếp cùng lớp này; hai vòng đầu đã sửa (b06eb79: `\$` để shell con thay, env chụp tại toán tử, ở bản đầy đủ; 5e5a67b: bản so mẫu thứ hai `plain2`, env của shell con `kid`, lưới `heredoc_grid` 2040 lệnh kiểm bằng bash thật). Biến thể vòng ba dưới đây là lỗ mọi bản đều bỏ sót (3b87a56, 4fba736, 13b4f43, e09ff4d cùng trả `[]`, bash 5.2 xoá /x hay //y), không phải hồi quy; người dùng chọn mở PR và thiết kế lại ở PR riêng.
  - `kid` học cả phép gán mà bash không áp dụng (strict có strict_assign=False nên mọi `NAME=VAL` trong đoạn vào `kid`; snap[2] lấy ASSIGN.findall trên cả phần trước SNAP): tham số lệnh `export O=-rf; bash <<EOF` ⏎ `echo O=-f; rm \$O /x` ⏎ `EOF`; gán tạm `…` ⏎ `O=-f true; rm \$O /x` ⏎ `…`; sau `&&` `…` ⏎ `false && O=-f; rm \$O /x` ⏎ `…`; trong ống `…` ⏎ `O=-f | true; rm \$O /x` ⏎ `…`; gán tạm của lệnh trước ống `export O=-rf; O=-f cat <<EOF | bash` ⏎ `rm \$O /x` ⏎ `EOF`; gán tạm của lệnh nền đứng trước `export O=-rf; O=-f true & bash <<EOF` ⏎ `rm \$O /x` ⏎ `EOF`; tham số vị trí `export O=-rf; bash -s O=-f <<EOF` ⏎ `rm \$O /x` ⏎ `EOF`.
  - Hai heredoc trên một dòng: HEREDOC_STRICT chỉ nhận một toán tử mỗi dòng, thân thứ hai đọc như lệnh ngoài cùng và học phép gán mà shell cha đã thay trước. `D=/; bash <<A; bash <<B` ⏎ `true` ⏎ `A` ⏎ `D=/tmp/w; rm -rf $D/y` ⏎ `B` (xoá //y); `C=rm; bash <<A; bash <<B` ⏎ `true` ⏎ `A` ⏎ `C=echo; $C -rf /y` ⏎ `B` (xoá /y); cũng sai với `cat <<A; bash <<B`, `true <<A; bash <<B`, `bash <<A <<B`.
  - Vì sao vá theo biến thể không hội tụ: mỗi vòng mô hình hoá chính xác hơn một chút ngữ nghĩa env của bash bằng heuristic, nên luôn còn biến thể sâu hơn. Hướng thiết kế lại (architect phác, chưa đo xong): giá trị biến là TẬP ứng viên — mọi phép gán không chắc được áp (tham số lệnh, gán tạm, sau `&&`/`||`, trong ống, chạy nền, tham số vị trí `bash -s`, lệnh trước ống trong `cat <<EOF | bash`) cho cả giả thuyết có áp và không áp; bản so mẫu sinh các biến thể có trần (vượt trần thì biến là không biết, kèm chính sách cho biến không biết ở vị trí cờ/tên lệnh) rồi hợp nhãn; nhận mọi toán tử heredoc trên dòng mở, thân theo thứ tự, mỗi thân có SNAP và env riêng. Giữ ⊇ theo cấu trúc (chỉ thêm đoạn/biến thể); đo chi phí báo thừa trên fixture, fuzz và file phiên thật.
  - Xong khi: các lệnh trên có assert vào A; `heredoc_grid` có thêm chiều sinh được chúng (phép gán không thuần trong thân, `cat <<EOF | bash`, `bash -s NAME=`, lệnh nền đứng trước, nhiều toán tử trên dòng mở) và oracle xanh; reviewer mới cho qua.

## 3. PR đang mở (ảnh chụp)

Không còn PR nào mở (21/10, sau PR #27).

## 4. Kit, ngoài audit

### 4.3 Guard chậm quá timeout với lệnh có rất nhiều cd
- **Vì sao:** 1500 dòng `cd . && ls` rồi `git push` trong repo ở main mất khoảng 52 giây, quá timeout 10 giây của hook, nên Claude Code cho lệnh chạy mà không hỏi. Lỗi có sẵn, cả trên Linux. Rule trong CLAUDE.md (PR #22) ghi là "chưa phủ". Từ PR #22, mỗi thư mục có `..` được đọc thêm theo đường logic (thêm 4 fork, 2 exec): 200 lần `cd .. &&` mất 4,4 giây thay vì 3,2 giây trên Linux, nên trên Git Bash ngưỡng số `cd` vượt timeout thấp hơn khoảng 30–40% (ước lượng của reviewer PR #22, chưa đo trên Windows). Từ PR sửa nháy giữa từ (4.10 cũ), mỗi cd có nháy giữa từ được đọc theo hai cách: 200 `cd "/tmp/d N"'x' &&` 1,7 → 2,7 giây, 9000 `cd` 63 → 73 giây (Linux). Từ PR sửa chữ lệnh bị nháy xé đôi: thư mục của phiên ở nhánh chính thì hỏi ngay, trước khi duyệt cd (1500 `cd . && ls` 1,5 → 0,12 giây); các luật so thêm dạng đổi Unicode sang ASCII và hai dạng bỏ nháy (gom mọi luật vào một lần grep để bù), nên lệnh dài nhiều nháy chậm hơn: 12000 `echo 'line' "x" \\y;` 0,49 → 0,84 giây (Linux). Gom luật vào một lần grep lấy dòng khớp đầu tiên làm lệnh dài khớp luật cuối nhanh hơn main: 540 KB nối dòng có é, U+2003 và `gh pr merge` ở mọi dòng 3,5 → 2,5 giây (bash 5.2), 10,9 → 9,2 giây (bash 3.2 build từ mã nguồn của Apple, chạy trên Linux): ở cỡ này main đã quá timeout trên bash 3.2. Dạng đổi Unicode sang ASCII làm cổng push thấy cả cd viết bằng NBSP, nên lệnh như `;cd<NBSP>-p` ×20000 rơi vào lỗi này (main 0,5 giây vì không thấy các cd đó, nay 217 giây; cùng lệnh viết bằng dấu cách thường thì main đã mất 200 giây).
- **Xong khi:** có ca test-hooks dùng `hook_limit`, xanh trên 3 OS.

### 4.5 Nhỏ
- Kiểm định kỳ feature map của skill verify-kit với kit, bằng `/loop` hay `/schedule` (gợi ý của PR #17).
- Guard hỏi thừa khi chuỗi `git push --force` hay `rm -rf /` chỉ là dữ liệu trong thân heredoc ghi ra file (`cat > gen.py <<'E'` ⏎ … ⏎ `E`), như lệnh so nhãn của verifier nhánh tích hợp audit ngày 21/10: session đứng 2,5 giờ chờ người duyệt. Không nới guard; cách tránh là ghi script bằng tool Write rồi mới chạy.
- Các điểm sau của `scripts/install-kit.sh` do verifier và reviewer của PR #25 ghi nhận. Tất cả đều vô hại hoặc hiếm gặp:
  - Khối "Bước tiếp theo" vẫn in `git add -A && git commit` khi không có gì đổi, và không nhắc `git diff HEAD`.
  - `git add --chmod=+x` ở cuối stage cả nội dung các script `.sh`, nên `git diff` không hiện thay đổi của chúng. Có thể chỉ đặt bit chạy (`git update-index --chmod=+x`) cho file đã được theo dõi.
  - Dòng sửa tay trong manifest kiểu `../x`, tên thư mục hay `-rf` bị báo "kit đã bỏ" mãi, vì installer kiểm bằng `-e` và không lọc `..`, `/`, `-`.
  - Cảnh báo "CLAUDE.md còn quy ước đội chép từ bản kit cũ" báo nhầm khi CLAUDE.md riêng có câu `/team-lead <task>` và về sau gardener hay `/correct` tạo bảng `Rule ↔ Thứ thực thi` trong đó.
  - Installer không cảnh báo khi `kit-commit` trong manifest không phải tổ tiên của HEAD của kit, tức kit đang ở bản cũ hơn bản đã cài. File trùng bản mới hơn (có trong lịch sử kit) sẽ bị đưa về bản cũ.

### 4.8 Lệnh PowerShell của đoạn "Cập nhật kit" chưa chạy tay trên Windows
- **Đã có:** CI của PR #25 (merge thành ced0c81) xanh trên cả 3 OS ở 9ee8be3 (run 39576148967): test-install (ca AE..AN) chạy trên macOS `/bin/bash` 3.2 và Git Bash Windows với `core.autocrlf=true`. Lần chạy Windows đầu tiên (f737e75) đỏ 7 assert. Lỗi nằm ở test fixture: grep và gawk của Git for Windows bỏ `\r`, và kit checkout CRLF. 9ee8be3 đã sửa.
- **Vì sao còn:** lệnh PowerShell ở đoạn "Cập nhật kit" của docs/04 mục 12 (`git diff --no-index C:\tools\Agents-Team-coding\<file> <file>`, `git restore --source=HEAD --staged --worktree -- <file>`) chưa chạy trên PowerShell 5.1; CI chỉ chạy phần bash.
- **Xong khi:** một lần làm tay đoạn "Cập nhật kit" trên `C:\vnstock-trial`, kết quả ghi vào đây.

### 4.9 Chưa có cách ghim một file kit ở bản cũ
- **Vì sao:** installer coi file trùng một bản kit cũ là "dự án chưa sửa" và cập nhật nó. Dự án cố ý giữ bản cũ, hay `git revert` commit cập nhật kit, thì lần cài sau file lại lên bản mới. Hiện installer chỉ in tên file được cập nhật, và docs/04 dặn thêm một dòng comment riêng vào file để installer dừng ở file đó.
- **Xong khi:** có cách ghim chính thức (ví dụ mục `kit-pinned:` trong `.claude/agent-team-kit.txt` mà installer tôn trọng) kèm test; hoặc người dùng quyết định giữ cách dặn thêm comment, và xoá mục này.

### 4.10 Guard chưa nhận vài dạng chữ lệnh bị nháy hay `\` xé đôi
- **Đã có:** mọi luật so thêm hai dạng đã bỏ nháy (dq: nháy quanh đoạn không có khoảng trắng, `$` trước nháy, `\` trước ký tự không phải khoảng trắng; dx: xoá hết `'` `"` `\`), nên `git pu'sh'`, `r'm' -rf /`, `--ha''rd`, `$'p'ush`, `-\-force`, `echo \';r'm' -rf /` đều hỏi. Token bỏ nháy thành từ khoá thư mục (`c'd'`, `-'C'`, `'--'`, `c\d`) làm thư mục của push thành chưa biết (hỏi).
- **Vì sao còn:** reviewer của PR sửa lớp này thử bằng bash thật, các lệnh sau vẫn lọt (main cũng lọt): tên shell bị xé nên thân không được giải (`ba'sh' -c 'cd '\''M'\'' && git push'`, `"bash" -c …`, `bash -'c' …`: decode_shell_c chạy trước dạng bỏ nháy, mà sed làm hỏng `'\''` của thân); `\` nối dòng giữa chữ (`git pu\` ⏎ `sh --force`, `r\` ⏎ `m -rf /`: bash xoá cả `\` lẫn xuống dòng, join_lines thay bằng dấu cách); chuỗi thoát ANSI-C (`git $'\x70'ush --force`, `$'pu\163h'`); mở rộng rỗng xé chữ (`pu$()sh`, ``pu``sh``, `pu${X}sh`). Reviewer vòng ba (cả main cũng lọt): mở rộng ngoặc nhọn (`git {push,} --force`, `r{m,} -rf ~`, `{cd,} M && git push`); cd mà CDA hay CDRE không nhận (`time cd M`, `! cd M ||`, `while cd M; do git push; …`, `cd -e M`); push qua tham số vị trí (`bash -c 'cd M && git "$@"' _ push`); PowerShell dùng backtick làm ký tự thoát (``git pu`sh --force``, ``r`m -r -fo C:\``), dq, dx và phần xét token không xử lý (suy từ ngữ nghĩa PowerShell, chưa chạy pwsh thật). Reviewer vòng bốn (main cũng lọt): `eval cd 'M' && git push` (CDA không có eval), `x=1 cd 'M' && git push` (phép gán trước cd), `git push origin "x;y" --force` (`;` trong nháy chặn `[^;&|]*` của luật). Khoảng trắng Unicode, nháy cong và en/em dash của PowerShell nay được đổi sang ASCII trước khi so.
- **Xong khi:** các lệnh trên là ca "phải hỏi" trong test-hooks, đỏ trước khi sửa, không chậm thêm đáng kể (ca `long-*` của test-hooks).

### 4.11 Thân `-c` guard chưa nhận ra
- **Đã có:** thân nhiều dòng (dòng mở thân bằng nháy mà chưa đóng) và shell là biến (`$SHELL -c`, `"$SHELL" -c`, `${SHELL:-bash} -c`) làm thư mục của push thành chưa biết, tức hỏi.
- **Vì sao còn:** reviewer của PR sửa mục này thử bằng bash thật, các lệnh sau vẫn lọt (main cũng lọt): shell từ lệnh lồng (`$(command -v bash) -c`, `` `which bash` -c ``); option có đối số hay option sau `-c` (`bash -O extglob -c '…'`, `bash -c -x '…'`: SHC và SHV chỉ nhận `-o`/`+o`); tên shell ngoài danh sách (`bash.exe -c`, `ash`, `mksh`, `bash5`, `fish`); thân lấy từ biến hay lệnh lồng (`X='…'; bash -c "$X"`, `bash -c "$(printf …)"`); thân ANSI-C có `\n` (`bash -c $'true\ncd M && git push'`). Thân quá 16 KB, quá 256 đoạn hay tổng các thân quá 8 KB thì không giải, và lệnh có chữ push bị hỏi (hỏi thừa).
- **Hỏi thừa đã biết:** SHV nhận cả `find $DIR -exec …`, `tar $OPTS -czf …`, `$GIT -c user.name=x push` và chữ `$X -c` trong chuỗi (commit message); SHO hỏi mọi thân `-c` nhiều dòng khi lệnh có chữ push ở đâu đó (`pushd`, `git stash push`). Chỉ tốn một câu hỏi.
- **Xong khi:** các lệnh lọt ở trên là ca "phải hỏi" trong test-hooks, đỏ trước khi sửa, không chậm thêm đáng kể.
