# Việc cần làm

Ảnh chụp ngày 20/10/2026, lúc gom mọi nhánh về nhánh mặc định `claude/sharp-knuth-lpdhqz` (đầu nhánh lúc ghi: `0b75004`, sau PR #21). Mỗi việc ghi: vì sao cần làm, khi nào thì xong, ai đang làm. Làm xong việc nào thì xoá dòng đó khỏi file này, ngay trong PR của việc đó.

Luật chung cho mọi việc audit: dùng `/team-lead` với playbook bug-fix, viết test đỏ trước, `KIT_SELFTEST=1 ./scripts/check.sh` phải exit 0, rồi verifier và reviewer mới cho qua. Không nới guard, Stop gate hay `scripts/guard-ask-floor`; không sửa hay nới assert cũ. Nhãn của `suspicious_labels` bản mới phải ⊇ bản trước, với `AUDIT_BASE_REF` đặt về commit trước khi sửa. Muốn đổi cách đọc lệnh thì thêm một cách đọc rồi hợp nhãn. Oracle bash chỉ có một bước, là bước đã có trên nhánh mặc định: không hạ `ORACLE_FLOOR`, `KNOWN_GAPS` chỉ được giảm. Thử hành vi bash thật thì thay `rm` và `git` bằng `echo` ngay trong văn bản lệnh, chạy trong thư mục tạm không phải repo git, HOME trỏ tới thư mục không tồn tại, và không đặt `rm` giả trên PATH.

## 1. Gom nhánh về nhánh mặc định (20/10)

Mọi nhánh đã merge đều đã bị xoá. Thứ tự gộp: PR #8, rồi PR mục 2.7, rồi nhánh tích hợp audit; PR #22 khác vùng code, gộp lúc nào CI xanh cũng được. Chạy lần lượt từng session: ngày 20/10 năm session chạy song song đã làm tài khoản chạm giới hạn dùng 5 giờ, và cả năm cùng dừng giữa chừng.

| Nhánh | Phần đã xong đi đâu | Session |
|---|---|---|
| `claude/youthful-fermi-1ydqg6` | PR mới của mục 2.7 (1d75753 gộp tổ hợp đọc, 8645ba3 xoá 2.7) | Đang chạy; archive khi PR merge |
| `claude/nice-hamilton-vdgw4v` | **Nhánh tích hợp audit duy nhất**: merge nhánh mặc định, giữ mọi cách đọc của PR #18 và PR #5, thêm cách đọc `strict`; cherry-pick 357c9ce, 1792c19 của blissful-dirac; revert WIP 1a1a9a0; verifier và reviewer mới cho cả 9 commit chưa qua review vòng 2 (eb9f3b8..847928b) | Đang chạy; archive khi PR merge |
| `claude/blissful-dirac-i6vpym` | 357c9ce (port 749e0c6) và 1792c19 (port oracle 751a129) đi qua nhánh tích hợp; phần dở ghi ở 2.3 | Đã archive. Xoá nhánh khi nhánh tích hợp merge |
| `claude/vibrant-pascal-b81ljt` | nice-hamilton đã nhận hết (d7ce707: 103 ca MISSED, fuzz_b/fuzz_c; bảng commit ở PR của nhánh tích hợp); phần dở ở 2.2 (P2, P3) | Đã archive. Xoá nhánh khi nhánh tích hợp merge |
| `claude/practical-hawking-le9toi` (PR #8) | Merge chính PR #8, sau khi verifier và reviewer mới cho qua a744f97. Phần riêng của nó: cách đọc `pipe_scope` (bắt `D=/tmp/x/; true && D=/srv/; true \| D=/tmp/x/; rm -rf ${D}src`, bash xoá /srv/src, nhánh mặc định trả `[]`); oracle thứ hai bổ sung cho oracle chung (xem 2.1); MUST_FLAG 18 lệnh phải báo và 5 lệnh vô hại. 4 ca sửa cũ của nó (0c347b2, a43055e, 3543fb4, 6b50142) nhánh mặc định đã báo nhờ PR #18 | Đang chạy; archive khi PR #8 merge |

## 2. Audit: `scripts/audit-agent.py`, mục A

### 2.1 Gộp hai oracle bash thành một bước (sau khi PR #8 merge)
- **Vì sao:** sau PR #8, test-audit có hai bước oracle: bước chung (blissful-dirac: ORACLE_FLOOR, KNOWN_GAPS) và bước của PR #8 (thư mục `$tmp/oracle-pr8`, KNOWN_MISSES chỉ được giảm, nhận bằng hằng MARK). Hai bước bổ sung cho nhau, không trùng: ngữ pháp của PR #8 sinh đúng các cấu trúc mà KNOWN_GAPS của bước chung loại ra (thân `bash -c` có biến hay lồng nhau, nháy lẻ trong comment hay thân heredoc, heredoc chưa đóng hay thân rỗng, gán trong khâu ống hay sau `&&`/`||`, `\` cuối dòng, `builtin cd`, cd lỗi). Số ca sót trên từng bản audit-agent.py (oracle PR #8 / oracle chung): 27727f5 69/25, 0667d98 6/13, 9bd03a3 0/10, 53f3ff2 0/0. Cộng lại hai bước mất khoảng 40–50 giây trên CI.
- **Cần biết khi gộp:**
  - Cách chặn rm khác nhau. Bước chung đặt `fakerm` trên một PATH chỉ có bash và cat; PR #8 thay chữ `rm` trong văn bản lệnh bằng đường dẫn tuyệt đối tới stub. `bash -l` có thể đặt lại PATH, nên mảnh `bash -lc` của PR #8 chỉ an toàn với cách thay trong văn bản: gộp thì dùng cách đó, hoặc bỏ `-l`.
  - Thư mục: PR #8 thay `/tmp/` bằng `<chỗ>/tmp/`, cwd là `<chỗ>/p` có sẵn `p/src`; nguy khi normpath(PWD + đích) nằm ngoài `<chỗ>/tmp`. Ngữ pháp PR #8 không dùng tên vô hại (dist, node_modules), còn bước chung coi build là vô hại.
  - Job nền: PR #8 đọc stdout tới EOF rồi `killpg`, mỗi lần gọi stub ghi ra `log.$$` riêng; ngữ pháp PR #8 không có `wait` hay `$( )` nên không cần lớp bọc e103274.
  - KNOWN_MISSES chứa lệnh đã sinh mà vẫn sót; KNOWN_GAPS chứa cấu trúc không sinh. Gộp thì giữ một luật chỉ được giảm, đổi MARK cho khớp.
- **Xong khi:** còn một bước oracle, ngữ pháp là hợp của hai bên, không mất lệnh nào mà một trong hai bước đang bắt, một dòng trong bảng Rule ↔ Thứ thực thi của CLAUDE.md.

### 2.2 Việc dở của nice-hamilton (sau khi nhánh tích hợp merge)
- **P2: nhận heredoc như bash**, 40 ca trong `MISSED_VP_PENDING` (38, 40, 41, 46–54, 61–70, 72, 83–87, 91–102). Ca 55 của P2 (`<<E\X`) đã nghi.
  - Vì sao: nhận heredoc hiện là heuristic. Cần cách đọc "tên là cả từ shell": bỏ nháy tên, `$"…"`, `\`⏎ trong tên, giải `$'…'`, `\r`, tên mở bằng chữ số; `<<` trong `$((`/`((`/`$[` là dịch bit; `<<` trong nháy, comment hay sau `\`; `<<\EOF`; `$(…)` và backtick trong thân dữ liệu không nháy (phải tuyến tính).
  - Thiết kế đề xuất: thêm cách đọc `segments(..., exact=True, strict=True, bash=True)` với bộ nhận `heredocs_word` port từ vibrant-pascal 970114a (audit-agent.py khoảng dòng 234–270), hợp nhãn, bỏ qua khi lệnh không có `<<`.
  - Tái hiện: bỏ chỉ số khỏi PENDING rồi chạy test-audit, hoặc `suspicious_labels(MISSED_VP[i][0], SUSPICIOUS)` trả `[]`.
  - Thêm: here-string đưa vào shell `bash <<< 'rm -rf src'` (bash xoá src, mọi bản trả `[]`).
  - Xong khi: hết chỉ số P2 trong PENDING, assert xanh, nhãn ⊇ bản trước.
- **P3: env chỉ học từ phép gán thuần**, 7 ca trong PENDING (29, 32, 35, 36, 76, 77, 79). 10 ca khác của P3 (10, 11, 12, 30, 80–82, 88–90) đã nghi sau khi nhánh tích hợp merge nhánh mặc định và 357c9ce; chú thích của PENDING ở test-audit.sh liệt kê chung 11 ca đã nghi, gồm 10 ca này và ca 55 của P2. **Cùng việc với 2.3**, làm một lần.
  - Vì sao: env chỉ nên học từ đoạn chỉ gồm phép gán thuần, đứng sau đầu dòng, `;` hay xuống dòng, không đứng trước `|`, `|&`, `&`. Gán ở chỗ khác (`echo D=`, gán tạm, sau `&&`, `local`, `D[0]=`, `((D=0))`, `${N:=}`) phải thành "không biết". Cần ngăn xếp env cho `(`/`)`; IFS; `r\ead`, `read -aD`; cd trong nháy hay có `\`.
  - Thêm: `D=/tmp/w; read -aD <<< /etc; rm -rf "$D"`, `unset D -f`.
  - Xong khi: PENDING rỗng; so với `AUDIT_BASE_REF=970114a` chỉ mất nhãn ở 52 lệnh mà vibrant-pascal báo thừa (bash thật không xoá ngoài /tmp/w).
- **Phép gán có nháy trong thân đưa vào shell qua ống**: `cat <<'EOF' | bash` ⏎ `D=~; D="x /"; D=/tmp/w & true; rm -rf /tmp/w/$D` ⏎ `EOF` (bash xoá `/`), mọi bản trả `[]`. Có `| bash` thì shell_c bật, nháy không được che, nên `ASSIGN_STMT` của strict_assign không nhận `D="x /"` là phép gán. Ngữ pháp oracle của 1792c19 sinh được lớp này ở seed khác (seed 7 và 1009 không gặp). Xong khi: lệnh trên có assert vào A, oracle xanh.

### 2.3 Việc dở của blissful-dirac (cùng việc với P3 ở 2.2)
Nhánh `claude/blissful-dirac-i6vpym` còn giữ commit gốc. Fixture s101–s137 nằm trong test-audit.sh của 98b74d0. Mỗi ý xong khi assert vào A có nhãn "xoá đệ quy", oracle xanh, `AUDIT_BASE_REF=<nền> ./scripts/test-audit.sh` exit 0.
- **55a62d6, chỉ ghi phép gán thật:** `true D=dist; rm -rf $D/src`, `make PREFIX=/tmp/x install; rm -rf $PREFIX/lib` (bash xoá /src, /lib). Còn 2 assert báo thừa phải giữ vô hại sau khi port: `D=/tmp/x # c | d` ⏎ `rm -rf $D/src`, `true # a |` ⏎ `D=/tmp/x` ⏎ `rm -rf $D/src`.
- **73226cf, gán rỗng, `unset`, `local`:** `local D=/tmp/x; rm -rf $D/src`, `D=/tmp/x; D=; rm -rf $D/src`, `D=/tmp/x; unset D; rm -rf $D/src`.
- **5b32600 + 98b74d0, gán có điều kiện:** `D=..; if false; then D=; fi; true D=/tmp/y; rm -rf node_modules/$D` (xoá thư mục dự án), `false && D=/tmp/x; rm -rf $D/src`, `while false; do D=/tmp/x; done; rm -rf $D/src`, `function f {`.
- **Oracle 876ad37 và 78e474a:** ngữ pháp sinh gán qua đối số, gán tạm, gán trong pipeline (WIP e69f5dd: sàn 2500, KNOWN_GAPS bỏ gán tạm/pipeline) và gán có điều kiện, `if`, thân hàm, `{ }|` (ORACLE_FLOOR 2600, đo được 2836). Oracle 78e474a phải đỏ trên nền trước khi port 5b32600.

### 2.4 Đường chậm bậc hai có từ trước
- Mọi bản đều chậm: các mẫu SUSPICIOUS dạng `\bX\b.*Y` (`"helm "*10000` 110 giây, checkout 103, push 93, docker 49, gh 45, branch 41); SHELL_WORD (`"bash "*10000 + "; cat <<EOF"` 22,6 giây); HEREDOC cũ (`"<<A "*5000` khoảng 3 giây); QUOTED cũ (`'\\"'*20000` khoảng 52 giây).
- `expand` là O(số biến × số đoạn có `$`), mỗi cách đọc một lượt: `" ".join("v%d=1" % i for i in range(5000)) + "; " + "echo $x; " * 5000` 13,7 giây (31893fb 11,4 giây; cách đọc strict thêm một lượt); `"unset v0 … v4999; " + "echo $x; " * 5000` 3,1 giây (31893fb 0,24 giây: cách đọc strict ghi 5000 tên bị unset thành biến rỗng). Đoạn không có `$` thì expand đã bỏ qua: hai lệnh trên với `true; ` thay `echo $x; ` mất 4,6 và 2,7 giây ở b06eb79 (31893fb 2,3 và 0,1 giây), nay 0,3 giây, có assert.
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
- Sau khi 357c9ce (port blissful-dirac 749e0c6) vào: `rm -rf "$TMPDIR/x"`, `rm -rf $HOME/.cache/pip`, `cd /tmp && rm -rf node_modules/$PKG`, PowerShell `$env:TEMP\x` bị báo, vì đoạn xoá còn biến chưa thay được thì không vô hại.

### 2.8 Lỗ mà mọi bản đều bỏ sót (bash 5.2 thật xoá, chưa ai làm)
Mỗi lỗ xong khi có fixture vào A và oracle sinh được dạng đó.
- Hàm gọi sau một phép gán chắc chắn chạy: `D=/tmp/x; f() { D=..; }; D=/tmp/x; f; rm -rf node_modules/$D`.
- `\;` hay `\|` làm SPLIT tách sai nên `fi` bị trừ độ sâu: `if false; then echo a\; fi; D=/tmp/x; fi; rm -rf $D/src`.
- `for D in ..; do :; done; rm -rf node_modules/$D`.
- `read D </dev/null; rm -rf $D/src`.
- `D=/tmp/w; D+=/../..; rm -rf $D`: ASSIGN không nhận `+=`, nên mọi bản giữ D là /tmp/w và trả `[]`; bash xoá `/tmp/w/../..`, tức `/`.
- Delimiter heredoc không phải `[A-Za-z_]\w*` (`EOF.x`, `EOF-1`), CRLF.
- `\$D` và `'$D'` là chữ.
- `D=/; rm -rf /tmp/$D`: xoá chính /tmp, luật under_temp coi là vô hại.
- `git checkout .&`: mẫu nhãn `\.(\s|$)` không nhận `&`.
- Từ báo cáo của PR #8: `(export D=/tmp/w && cd /tmp/w/s)` ⏎ `rm -rf ${D}src`; `false && D=/tmp/w/; rm -rf ${D}src`; `{ D=/tmp/w/; } | true; rm -rf ${D}src`; `true || { cd /tmp/w; D=/tmp/w/; } && rm -rf ${D}src`; `rm -rf {,/}src`; `D=/tmp/w/ true; rm -rf ${D}src`.
- `su -c 'rm -rf src'`; `{ D=/tmp/w; } | true; rm -rf $D` (gán trong nhóm thuộc ống); `rm -rf {/tmp/a,/}`; `| /bin/bash`; nameref, trap, hàm.
- Heredoc lồng trong thân heredoc đưa vào shell: HEREDOC_STRICT chỉ nhận toán tử ngoài cùng, thân lồng đọc như lệnh của thân ngoài. `bash <<'A'` ⏎ `bash <<X -c 'rm -rf /'` ⏎ `X` ⏎ `A` (bash xoá /); `D=/; bash <<'EOF'` ⏎ `D=/tmp/w; bash <<EOF2` ⏎ `rm -rf \$D/x` ⏎ `EOF2` ⏎ `EOF` (bash xoá /x: thân EOF2 không nháy để `$D` cho shell cháu, nơi D không export là rỗng). Mọi bản trả `[]` (đã thử 3b87a56, 4fba736, 13b4f43, af91da1, 31893fb và bản có bản so mẫu thứ hai cho thân <<EOF). Nhận thân lồng ngay trong cách đọc strict thì thân dữ liệu lồng (`cat <<X` trong thân) thôi là lệnh, mất nhãn mà bản trước báo: cần một cách đọc thêm rồi hợp nhãn.
- `\` trong cờ: `rm \-rf /x` (bash xoá /x), cả trong thân <<EOF: `O=-rf; bash <<EOF` ⏎ `rm \\$O /x` ⏎ `EOF` (shell cha đổi `\\` thành `\`, shell con bỏ `\`: xoá /x). Mọi bản trả `[]`: mẫu xoá đệ quy so trên chữ còn `\` (`\s-\w*r` không khớp `\-rf`).
- `cat <<'EOF' | X=1 bash`, `cat <<'EOF' | env bash` ⏎ `rm -rf /x` ⏎ `EOF`: PIPE_SHELL chỉ nhận shell ngay sau `|`, nên thân thành dữ liệu (bash xoá /x; mọi bản trả `[]`).
- Biến ở vị trí cờ hay tên lệnh mà giá trị không học được: trong nháy kép `X=-rf; rm "$X" /x`, `X=rm; "$X" -rf /x`; biến không biết `read O <<< -rf; rm $O /x`, `O=$(echo -rf); rm $O /x`; giá trị mặc định `rm ${O:--rf} /x` (bash xoá /x; mọi bản trả `[]`).
- **Thay biến trong thân `<<EOF` không nháy đưa vào shell (cách đọc `strict`), còn để ngỏ khi nhánh tích hợp mở PR.** Reviewer chặn ba vòng liên tiếp cùng lớp này; hai vòng đầu đã sửa (b06eb79: `\$` để shell con thay, env chụp tại toán tử, ở bản đầy đủ; 5e5a67b: bản so mẫu thứ hai `plain2`, env của shell con `kid`, lưới `heredoc_grid` 2040 lệnh kiểm bằng bash thật). Biến thể vòng ba dưới đây là lỗ mọi bản đều bỏ sót (3b87a56, 4fba736, 13b4f43, e09ff4d cùng trả `[]`, bash 5.2 xoá /x hay //y), không phải hồi quy; người dùng chọn mở PR và thiết kế lại ở PR riêng.
  - `kid` học cả phép gán mà bash không áp dụng (strict có strict_assign=False nên mọi `NAME=VAL` trong đoạn vào `kid`; snap[2] lấy ASSIGN.findall trên cả phần trước SNAP): tham số lệnh `export O=-rf; bash <<EOF` ⏎ `echo O=-f; rm \$O /x` ⏎ `EOF`; gán tạm `…` ⏎ `O=-f true; rm \$O /x` ⏎ `…`; sau `&&` `…` ⏎ `false && O=-f; rm \$O /x` ⏎ `…`; trong ống `…` ⏎ `O=-f | true; rm \$O /x` ⏎ `…`; gán tạm của lệnh trước ống `export O=-rf; O=-f cat <<EOF | bash` ⏎ `rm \$O /x` ⏎ `EOF`; gán tạm của lệnh nền đứng trước `export O=-rf; O=-f true & bash <<EOF` ⏎ `rm \$O /x` ⏎ `EOF`; tham số vị trí `export O=-rf; bash -s O=-f <<EOF` ⏎ `rm \$O /x` ⏎ `EOF`.
  - Hai heredoc trên một dòng: HEREDOC_STRICT chỉ nhận một toán tử mỗi dòng, thân thứ hai đọc như lệnh ngoài cùng và học phép gán mà shell cha đã thay trước. `D=/; bash <<A; bash <<B` ⏎ `true` ⏎ `A` ⏎ `D=/tmp/w; rm -rf $D/y` ⏎ `B` (xoá //y); `C=rm; bash <<A; bash <<B` ⏎ `true` ⏎ `A` ⏎ `C=echo; $C -rf /y` ⏎ `B` (xoá /y); cũng sai với `cat <<A; bash <<B`, `true <<A; bash <<B`, `bash <<A <<B`.
  - Vì sao vá theo biến thể không hội tụ: mỗi vòng mô hình hoá chính xác hơn một chút ngữ nghĩa env của bash bằng heuristic, nên luôn còn biến thể sâu hơn. Hướng thiết kế lại (architect phác, chưa đo xong): giá trị biến là TẬP ứng viên — mọi phép gán không chắc được áp (tham số lệnh, gán tạm, sau `&&`/`||`, trong ống, chạy nền, tham số vị trí `bash -s`, lệnh trước ống trong `cat <<EOF | bash`) cho cả giả thuyết có áp và không áp; bản so mẫu sinh các biến thể có trần (vượt trần thì biến là không biết, kèm chính sách cho biến không biết ở vị trí cờ/tên lệnh) rồi hợp nhãn; nhận mọi toán tử heredoc trên dòng mở, thân theo thứ tự, mỗi thân có SNAP và env riêng. Giữ ⊇ theo cấu trúc (chỉ thêm đoạn/biến thể); đo chi phí báo thừa trên fixture, fuzz và file phiên thật.
  - Xong khi: các lệnh trên có assert vào A; `heredoc_grid` có thêm chiều sinh được chúng (phép gán không thuần trong thân, `cat <<EOF | bash`, `bash -s NAME=`, lệnh nền đứng trước, nhiều toán tử trên dòng mở) và oracle xanh; reviewer mới cho qua.

### 2.9 Oracle của PR #8 chạy với PATH có `rm` và `git` thật
- **Vì sao:** `run()` của oracle thứ hai (PR #8) thay `rm` bằng stub bằng phép thay trên văn bản lệnh (`\brm\b`) rồi chạy bash với PATH đầy đủ. Dạng che tên lệnh (`r\m`, `'r'm`, `"r"m`, `$X` mang tên rm, `command rm`, `$(echo rm)`, `env rm`, `/bin/rm`) lọt qua phép thay và chạy rm thật: chuyện này đã xảy ra với một lệnh thăm dò ngoài repo (`r\m -rf /x`, /x không tồn tại nên không mất gì). Reviewer vòng 4 của nhánh tích hợp đã kiểm tĩnh 2365 lệnh fuzz và 2040 lệnh lưới: hiện không lệnh nào có đường tới rm hay git thật, nhưng chỉ nhờ ngữ pháp không bao giờ che tên lệnh. Oracle chung đã an toàn (PATH chỉ có bash và cat).
- **Xong khi:** `run()` chạy với PATH là thư mục chỉ có symlink tới bash/sh/cat (không có rm, git), và đỏ khi văn bản lệnh (sau khi bỏ nháy và `\`) còn `\brm\b`/`\bgit\b`, hoặc có `$(`, backtick, `eval`, `env`, `command`, `exec`, `xargs`, `find`, `/bin/` — chỉ hạn chế PATH chưa đủ, vì ngữ pháp có `bash -lc` mà `/etc/profile` của Debian đặt lại PATH ở login shell.

## 3. PR đang mở (ảnh chụp)

| PR | Nội dung | Trạng thái |
|---|---|---|
| #8 | fix(audit): oracle bash cho mục A, cách đọc `pipe_scope` (`claude/practical-hawking-le9toi`) | Nháp, đầu a744f97 đã merge 53f3ff2, check cục bộ xanh. Chờ verifier và reviewer mới, cập nhật mô tả, rồi merge (mục 1) |
| #25 | fix(install): quy ước đội luôn ở `.claude/rules`, manifest `.claude/agent-team-kit.txt`, cài lại tự cập nhật file kit mà dự án chưa sửa (nhận theo lịch sử git của kit); docs cập nhật kit và auto-update plugin | Nháp, mở ngày 21/10. Đã qua verifier và reviewer mới; CI xanh trên Linux, macOS và Windows (9ee8be3). Chờ người review. Việc còn lại: 4.6–4.9 |

## 4. Kit, ngoài audit

### 4.2 Cài lại kit trên macOS dừng khi phần riêng có byte không phải UTF-8 (ca Q của PR #22)
- **Vì sao:** reviewer của PR #22 suy ra installer dừng trên macOS trong locale UTF-8 khi `.claude/rules/agent-team.md` có byte Latin-1. Ca Q đỏ trên macos-latest (run 39454475168, 1/98). Bản sửa `LC_ALL=C tr` (3749c74) không làm ca này xanh, nên nguyên nhân không chỉ ở `tr`; nghi awk BWK hay grep của macOS. Ca test 6a08ee9 và bản sửa 3749c74 đã được revert khỏi PR #22.
- **Tái hiện trên macOS:** repo có CLAUDE.md; tạo `.claude/rules/agent-team.md` = `templates/agent-team-rules.md` + `printf '## Riêng Z\n- caf\351\n'`; chạy `env LC_ALL=en_US.UTF-8 bash -x ./scripts/install-kit.sh <repo>`, tìm lệnh exit khác 0. Chạy thêm với install-kit.sh của e5a6756 để biết lỗi có sẵn hay là hồi quy.
- **Xong khi:** ca Q (lấy lại từ 6a08ee9) xanh trên macos-latest.

### 4.3 Guard chậm quá timeout với lệnh có rất nhiều cd
- **Vì sao:** 1500 dòng `cd . && ls` rồi `git push` trong repo ở main mất khoảng 52 giây, quá timeout 10 giây của hook, nên Claude Code cho lệnh chạy mà không hỏi. Lỗi có sẵn, cả trên Linux. Rule trong CLAUDE.md (PR #22) ghi là "chưa phủ".
- **Xong khi:** có ca test-hooks dùng `hook_limit`, xanh trên 3 OS.

### 4.4 Lớp lỗi "guard cho qua khi I/O của shell hỏng" đã lọt hai lần
- **Vì sao:** PR #6 (SIGPIPE dưới pipefail) và PR #21 (bash không tạo được file tạm cho here-doc). Theo quy ước của repo, lỗi lặp lần hai thì chạy `/correct`.
- **Xong khi:** `validate-kit.sh` có lint cấm here-doc, `<<<` và `<(...)` trong file hook, báo file:dòng; có dòng trong bảng Rule ↔ Thứ thực thi.

### 4.5 Nhỏ
- Kiểm định kỳ feature map của skill verify-kit với kit, bằng `/loop` hay `/schedule` (gợi ý của PR #17).
- `actions/checkout@v4` báo cảnh báo Node 20 trong CI.
- Các điểm sau của `scripts/install-kit.sh` do verifier và reviewer của nhánh `ccr-651f0a3f-wykij0` ghi nhận. Tất cả đều vô hại hoặc hiếm gặp:
  - Khối "Bước tiếp theo" vẫn in `git add -A && git commit` khi không có gì đổi, và không nhắc `git diff HEAD`.
  - `git add --chmod=+x` ở cuối stage cả nội dung các script `.sh`, nên `git diff` không hiện thay đổi của chúng. Có thể chỉ đặt bit chạy (`git update-index --chmod=+x`) cho file đã được theo dõi.
  - Dòng sửa tay trong manifest kiểu `../x`, tên thư mục hay `-rf` bị báo "kit đã bỏ" mãi, vì installer kiểm bằng `-e` và không lọc `..`, `/`, `-`.
  - Cảnh báo "CLAUDE.md còn quy ước đội chép từ bản kit cũ" báo nhầm khi CLAUDE.md riêng có câu `/team-lead <task>` và về sau gardener hay `/correct` tạo bảng `Rule ↔ Thứ thực thi` trong đó.
  - CLAUDE.md là symlink gãy thì installer ✘ exit 1, nhưng lúc đó đã chép file kit và gộp settings. Nó không dừng trước khi đụng repo như ca C/E của test-install.
  - Installer không cảnh báo khi `kit-commit` trong manifest không phải tổ tiên của HEAD của kit, tức kit đang ở bản cũ hơn bản đã cài. File trùng bản mới hơn (có trong lịch sử kit) sẽ bị đưa về bản cũ.

### 4.6 `kit_had` của installer chưa thấy đủ các bản trong lịch sử kit
- **Vì sao:** cài lại thì installer tự cập nhật file kit trùng một bản đã commit trong lịch sử kit (hàm `kit_had`, dùng `git log --raw -m`). Có hai chỗ hở, cả hai chỉ làm installer báo ✘ thừa và dừng, không ghi đè gì:
  - `-m` phụ thuộc config `log.diffMerges` của người dùng. Với `off`, merge bị bỏ qua. Với `remerge`, output có thêm blob giả (bản gộp lại có conflict marker), gần như không thể trùng.
  - Lọc theo đường dẫn thì `git log` cắt bớt lịch sử: ở merge mà file trùng một parent, git chỉ đi theo parent đó, nên bản trên nhánh bị bỏ không được nhận.
  Reviewer của 12bf299 đã tái hiện chỗ đầu. Chỗ sau do implementer chỉ ra.
- **Xong khi:** `kit_had` gọi `git -c log.diffMerges=separate -C "$kit" log --full-history ...`; có ca test-install cho kit có `log.diffMerges=off` và cho lịch sử bị cắt bớt, đỏ trước rồi xanh.

### 4.7 Cài lại trên Windows ghi `settings.json` từ CRLF sang LF
- **Vì sao:** kit clone với `core.autocrlf=true` (mặc định của Git for Windows) thì `.claude/settings.json` của kit là CRLF. Lần cài đầu chép nguyên văn (CRLF), lần cài lại gộp bằng Python và ghi LF, nên `git diff HEAD` hiện cả file (66 dòng) dù nội dung không đổi. Lỗi có từ trước nhánh `ccr-651f0a3f-wykij0`; verifier của nhánh đó thấy khi mô phỏng autocrlf trên Linux.
- **Xong khi:** có ca test-install với kit `autocrlf=true`: cài, commit, cài lại, `git status --porcelain` rỗng.

### 4.8 Lệnh PowerShell của đoạn "Cập nhật kit" chưa chạy tay trên Windows
- **Đã có:** CI của PR #25 xanh trên cả 3 OS ở 9ee8be3 (run 39576148967): test-install (ca AE..AN) chạy trên macOS `/bin/bash` 3.2 và Git Bash Windows với `core.autocrlf=true`. Lần chạy Windows đầu tiên (f737e75) đỏ 7 assert. Lỗi nằm ở test fixture: grep và gawk của Git for Windows bỏ `\r`, và kit checkout CRLF. 9ee8be3 đã sửa.
- **Vì sao còn:** lệnh PowerShell ở đoạn "Cập nhật kit" của docs/04 mục 12 (`git diff --no-index C:\tools\Agents-Team-coding\<file> <file>`, `git restore --source=HEAD --staged --worktree -- <file>`) chưa chạy trên PowerShell 5.1; CI chỉ chạy phần bash.
- **Xong khi:** một lần làm tay đoạn "Cập nhật kit" trên `C:\vnstock-trial`, kết quả ghi vào đây.

### 4.9 Chưa có cách ghim một file kit ở bản cũ
- **Vì sao:** installer coi file trùng một bản kit cũ là "dự án chưa sửa" và cập nhật nó. Dự án cố ý giữ bản cũ, hay `git revert` commit cập nhật kit, thì lần cài sau file lại lên bản mới. Hiện installer chỉ in tên file được cập nhật, và docs/04 dặn thêm một dòng comment riêng vào file để installer dừng ở file đó.
- **Xong khi:** có cách ghim chính thức (ví dụ mục `kit-pinned:` trong `.claude/agent-team-kit.txt` mà installer tôn trọng) kèm test; hoặc người dùng quyết định giữ cách dặn thêm comment, và xoá mục này.
