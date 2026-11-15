#!/usr/bin/env bash
# PreToolUse(Bash|PowerShell): buộc hỏi người trước hành động không đảo ngược được.
# Trên Windows, Claude Code chạy lệnh qua PowerShell tool là chính, nên matcher phải gồm cả PowerShell.
# Khớp mẫu thì in permissionDecision "ask". Không khớp thì im lặng cho qua.
# Khớp thừa chỉ tốn một câu hỏi, bỏ sót thì mất dữ liệu, nên các mẫu cố ý bắt rộng.
# Thêm mẫu: gọi thêm một dòng `rule '<regex ERE>' '<lý do>'` ở dưới, và thêm ca vào scripts/test-hooks.sh.
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

input="$(cat)"
# Trần RAW_MAX trên input thô, trước mọi bước đọc: đọc JSON, các dạng nối dòng và rule grep chạy trên cả lệnh, lệnh ~2 MB
# mất 14,8 giây với bash 3.2 ở UTF-8, quá timeout của hook, và Claude Code cho lệnh chạy mà không hỏi (4.3). Dài hơn thì
# hỏi luôn (hỏi thừa: lệnh dài hơn 256 KiB, hiếm). ${#input} đếm ký tự (≤ số byte); có thể vượt theo cận 6 byte mỗi ký
# tự (glibc đếm cả dãy 5–6 byte không hợp lệ là một ký tự; reviewer PR #85) thì đếm byte bằng wc, so bằng `[` (bỏ `\r` của wc.exe; số vẫn hỏng thì `[` lỗi, coi như quá trần như PUSH_CMD_MAX).
RAW_MAX=262144
raw_reason=""
if [ "${#input}" -gt "$RAW_MAX" ]; then
  raw_reason="lệnh quá dài để kiểm kịp: hơn $RAW_MAX byte"
elif [ $((6 * ${#input})) -gt "$RAW_MAX" ]; then
  rawb="$(printf '%s' "$input" | wc -c | tr -d ' \t\r')"
  [ "$rawb" -le "$RAW_MAX" ] 2>/dev/null || raw_reason="lệnh quá dài để kiểm kịp: hơn $RAW_MAX byte"
fi
if [ -n "$raw_reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Hành động không đảo ngược được (%s). Cần người xác nhận, xem mục Quyền tự chủ trong CLAUDE.md."}}\n' "$raw_reason"
  exit 0
fi
cwd="$(json_get "$input" cwd)"
cmd="$(json_get "$input" tool_input.command)"
# Không đọc được lệnh: so mẫu trên toàn bộ input thô (thà hỏi thừa).
[ -n "$cmd" ] || cmd="$input"
raw="$cmd" # lệnh như nhận, trước khi nối dòng: dạng dz bên dưới cần `\` + xuống dòng còn nguyên
# Nối dòng: bash dùng \ cuối dòng, PowerShell dùng `. Ở tool kia, ký tự đó cuối dòng là thứ
# khác (C:\ trong PowerShell, dấu đóng `...` trong bash), còn \\ là dấu \ thật. grep so từng
# dòng, nên so trên nhiều dạng: nối theo tool (đích nằm ở dòng sau), giữ dòng nhưng bỏ dấu
# nối (lệnh ở dòng sau vẫn là đầu lệnh), nối cả hai kiểu (PowerShell lồng trong bash). Không
# rõ tool thì so thêm bản gốc. Kiểm tra push trên nhánh chính đọc từng dạng riêng ($forms).
nl=$'\n'
soh=$'\001'
# Locale gốc và lớp byte ≥ 0x80: grep thân -c và grep của vòng cd chạy ở locale C (tuyến tính) khi dạng chỉ có byte ASCII,
# còn dạng có byte ≥ 0x80 thì chạy ở locale gốc như trước (khoảng trắng Unicode khớp [[:space:]], -i gập ſ và ı).
LC0="${LC_ALL-}"
HIB="$(printf '[\200-\377]')"
# grep_lc <chuỗi>: đặt GL thành locale cho grep trên chuỗi đó.
grep_lc() {
  GL=C
  LC_ALL=C text_grep "$1" -q -- "$HIB" && GL="$LC0"
  return 0
}
tool="$(json_get "$input" tool_name)"
# join_lines <lệnh> <dấu nối> <join|keep>: dòng có dòng sau mà kết thúc bằng dấu nối (xét lần lượt từng ký
# tự của <dấu nối>) thì bỏ dấu đó cùng xuống dòng, thay bằng dấu cách (join), hoặc chỉ bỏ dấu và giữ xuống
# dòng (keep, khi đó dấu kế tiếp cũng được bỏ). \\ là dấu \ thật, không phải dấu nối. Dùng awk, không dùng
# ${x//a/b}: bash 3.2 (macOS) thay chuỗi mất thời gian bậc hai, lệnh 15 KB tốn ~50 giây, quá timeout 10 giây
# của hook, và Claude Code cho lệnh chạy mà không hỏi.
join_lines() {
  # Dấu nối đi qua ENVIRON: -v xử lý escape, \ sẽ mất.
  printf '%s\n' "$1" | MARKS="$2" LC_ALL=C awk -v how="$3" '
    BEGIN { marks = ENVIRON["MARKS"] }
    function emit(line, more,   i, n, part, sep) {
      gsub(/\\\\/, "\001", line)
      sep = more ? "\n" : ""
      for (i = 1; more && i <= length(marks); i++) {
        if (substr(line, length(line), 1) != substr(marks, i, 1)) continue
        line = substr(line, 1, length(line) - 1)
        if (how == "join") { sep = " "; break }
      }
      n = split(line, part, /\001/)
      printf "%s", part[1]
      for (i = 2; i <= n; i++) printf "\\\\%s", part[i]
      printf "%s", sep
    }
    NR > 1 { emit(prev, 1) }
    { prev = $0 }
    END { emit(prev, 0) }'
}
kept="$cmd"
forms=("$cmd")
case "$cmd" in
  *"\\$nl"* | *"\`$nl"*)
    case "$tool" in
      Bash) marks='\' ;;
      PowerShell) marks='`' ;;
      *) marks='\`' ;;
    esac
    joined="$(join_lines "$cmd" "$marks" join)"
    kept="$(join_lines "$cmd" "$marks" keep)"
    both="$(join_lines "$cmd" '\`' join)"
    forms=("$kept" "$joined" "$both")
    case "$tool" in
      Bash | PowerShell) cmd="$joined$nl$kept$nl$both" ;;
      *) cmd="$joined$nl$kept$nl$both$nl$cmd" ;;
    esac
    ;;
esac

# unquote_word <từ> <bash|ps>: bỏ nháy như shell đọc một từ ghép nhiều đoạn ("a b"/'..' là a b/..), kết quả
# trong UQ. bash: \<ký tự> ngoài nháy là ký tự đó, trong nháy kép chỉ \\ \" \$ \` là escape ("C:\Users" giữ \);
# ps: \ là ký tự thường. Trả 1 khi quá <tối đa đoạn> (mặc định 64): guard hỏi. Trả 2 khi từ không đọc được (nháy lẻ): chỉ dùng cách
# đọc cũ. Không dùng ${x//a/b} (xem join_lines), mỗi đoạn một phép so regex.
unquote_word() {
  local w="$1" n=0 max="${3:-64}" re_pl re_dqe='^"(([^"\\]|\\.)*)"(.*)$' re_dq='^"([^"]*)"()(.*)$' re_sq="^'([^']*)'(.*)\$" re_bs='^\\(.)(.*)$' c rest
  local re_dqbs='^([^\\]*)\\(.?)(.*)$'
  UQ=""
  UQN=0
  if [ "$2" = ps ]; then re_pl='^([^"'"'"']+)(.*)$'; else re_pl='^([^"'"'"'\\]+)(.*)$'; fi
  while [ -n "$w" ]; do
    n=$((n + 1))
    UQN="$n"
    [ "$n" -le "$max" ] || return 1
    if [[ $w =~ $re_pl ]]; then
      UQ="$UQ${BASH_REMATCH[1]}"
    elif { [ "$2" != ps ] && [[ $w =~ $re_dqe ]]; } || [[ $w =~ $re_dq ]]; then
      # bash: nháy kép có \" bên trong; không khớp (nháy lẻ) thì đọc như PowerShell, tới " đầu tiên.
      c="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[3]}"
      # Trong nháy kép, \ chỉ thoát \ $ ` " (bash); \ trước ký tự khác giữ nguyên.
      while [ "$2" != ps ] && [[ $c =~ $re_dqbs ]]; do
        n=$((n + 1))
        UQN="$n"
        [ "$n" -le "$max" ] || return 1
        case "${BASH_REMATCH[2]}" in
          \\ | '$' | '`' | '"') UQ="$UQ${BASH_REMATCH[1]}${BASH_REMATCH[2]}" ;;
          *) UQ="$UQ${BASH_REMATCH[1]}\\${BASH_REMATCH[2]}" ;;
        esac
        c="${BASH_REMATCH[3]}"
      done
      UQ="$UQ$c"
      w="$rest"
      continue
    elif [[ $w =~ $re_sq ]]; then
      UQ="$UQ${BASH_REMATCH[1]}"
    elif [ "$w" = '\' ]; then
      UQ="$UQ\\"
      return 0
    elif [ "$2" != ps ] && [[ $w =~ $re_bs ]]; then
      UQ="$UQ${BASH_REMATCH[1]}"
    else
      return 2
    fi
    w="${BASH_REMATCH[2]}"
  done
  return 0
}

# Thân của bash -c / sh -c '…': shell con đọc lại chuỗi sau khi shell ngoài bỏ một lớp nháy ('…'\''…', "…\"…"),
# nên `bash -c 'git -C '\''M'\'' push'` không khớp mẫu nào trên văn bản gốc. Thân đã bỏ nháy được nối vào cmd (mọi
# luật) và thêm vào forms (cổng push). Chỉ giải thân có các chữ của push; thân lồng thì giải tiếp, tối đa 16 dạng. Mỗi đoạn
# chép phần còn lại của từ (60 KB, 330 đoạn mất 6,5 giây ở UTF-8; Git Bash chậm hơn nhiều lần), nên thân quá 16 KB
# hay 256 đoạn thì bỏ, tổng các thân quá 8 KB hay quá 256 thân thì dừng: lệnh có chữ push khi đó vào cổng push và
# không biết thư mục, tức hỏi. Thân nhiều dòng (grep đọc từng dòng) chưa được đọc.
# Tên shell (cả bash.exe, ash, mksh, bash5, fish), option trước -c (cả -O/+O và --rcfile có đối số), option sau -c (bash -c -x
# '…': bash vẫn đọc option rồi lấy từ đầu tiên không phải option làm thân).
SHN='((ba|da|z|k|a|mk|y)?sh|bash[0-9][0-9.]*|fish)(\.exe)?'
SHOPT='[-+]o[[:space:]]+[A-Za-z]+|[-+]O[[:space:]]+[A-Za-z_]+|--(rcfile|init-file)[[:space:]]+[^[:space:]]+|--[A-Za-z-]+|[-+][A-Za-z]+'
SHC='(^|[;&|(`{[:space:]"'"'"'/])'"$SHN"'([[:space:]]+('"$SHOPT"'))*[[:space:]]+-[A-Za-z]*c[A-Za-z]*([[:space:]]+(--|'"$SHOPT"'))*[[:space:]]+'
# Thân chưa trong nháy dừng ở ( và `: thân $(bash -c '…') thì shell ngoài chạy lệnh lồng trước, lượt khớp sau phải bắt đầu
# được ở (bash để giải shell con đó (reviewer PR #47).
SHW='('"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*"|[^[:space:];&|"'"'"'\\(`]|\\.)+'
shc_unknown=""
SHU_MAX=16384
# Khoảng trắng Unicode theo UTF-8 mà glibc xếp vào [[:space:]] (cộng các khoảng trắng không ngắt cho chắc): U+0085, U+00A0,
# U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000.
USP="$(printf '\302[\205\240]|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200')"
# Neo đầu chuỗi và dùng lớp phủ định: regex không neo [Pp].*[Uu].*[Ss].*[Hh] của glibc thử lại từ mọi chữ p, bậc hai (thân
# 40 KB toàn chữ p mất 11 giây).
PUSH_LETTERS='^[^Pp]*[Pp][^Uu]*[Uu][^Ss]*[Ss][^Hh]*[Hh]'
# decode_shell_c [chỉ số dạng đầu tiên]: giải thân trên forms từ chỉ số đó (mặc định 0). Thân giải được nối vào cmd, forms và
# shc_new (để dạng un, giải sau, đưa thân của nó vào src).
shc_new=""
decode_shell_c() {
  local i="${1:-0}" m w budget=8192 count=0
  set -f
  IFS="$nl"
  while [ "$i" -lt "${#forms[@]}" ] && [ "${#forms[@]}" -lt 16 ]; do
    # LC_ALL=C: ở locale UTF-8 grep không dùng DFA, chuỗi option nối nhau (`bash -o `×23000, ~184 KB) khớp tới cuối rồi hỏng,
    # thử lại từ mọi vị trí: bậc hai, quá 40 giây (reviewer PR #62 lần 8). Chỉ dạng toàn ASCII: dạng có byte ≥ 0x80 chạy ở
    # locale gốc như trước, vì ở locale C [[:space:]] không khớp khoảng trắng Unicode (`bash<U+3000>-c` của PowerShell;
    # reviewer PR #74). Lệnh dài có ký tự không phải ASCII vẫn chậm như trước.
    grep_lc "${forms[$i]}"
    # Dạng dài có byte ≥ 0x80 (một `é ` trước `bash -o `×23000, 184 KB) thì grep ở locale gốc cũng bậc hai: quá 60 giây với
    # bash 5, quá timeout thì push lên main chạy không hỏi (reviewer PR #85). Dạng dài hơn SHU_MAX ký tự thì grep ở locale C;
    # khoảng trắng Unicode (PowerShell `bash<U+3000>-c`) khi đó không khớp [[:space:]], nên dạng có khoảng trắng Unicode thì
    # thân là chưa biết (push hỏi). Bash chỉ tách từ ở khoảng trắng ASCII, nên với bash không mất gì.
    if [ "$GL" != C ] && [ "${#forms[$i]}" -gt "$SHU_MAX" ]; then
      GL=C
      LC_ALL=C text_grep "${forms[$i]}" -Eq -- "$USP" && shc_unknown=1
    fi
    for m in $(printf '%s' "${forms[$i]}" | LC_ALL="$GL" grep -Eo -- "$SHC$SHW"); do
      [[ $m =~ ($SHW)$ ]] || continue
      w="${BASH_REMATCH[1]}"
      # Chỉ cổng push cần đọc thân: thân không có chữ p, u, s, h theo thứ tự thì khỏi bỏ nháy (Git Bash chậm hơn Linux
      # nhiều lần). Không đòi bốn chữ liền nhau: nháy có thể xé đôi chữ (pu'\''sh'\''). Regex, không dùng glob
      # *[Pp]*[Uu]*[Ss]*[Hh]*: bash 3.2 khớp glob đó bậc bốn (thân 775 byte không có h mất 17 giây trên macOS).
      [[ $w =~ $PUSH_LETTERS ]] || continue
      budget=$((budget - ${#w}))
      count=$((count + 1))
      [ "$budget" -ge 0 ] && [ "$count" -le 256 ] || { shc_unknown=1; break 2; }
      [ "${#w}" -le 16384 ] || { shc_unknown=1; continue; }
      unquote_word "$w" bash 256
      case $? in
        # Hết chỗ cho dạng mới thì thân không được đọc: thư mục của push là chưa biết, không bỏ trong im lặng.
        0) if [ "${#forms[@]}" -lt 16 ]; then forms+=("$UQ"); cmd="$cmd$nl$UQ"; shc_new="$shc_new$nl$UQ"; else shc_unknown=1; fi ;;
        1) shc_unknown=1 ;;
      esac
    done
    i=$((i + 1))
  done
  [ "$i" -ge "${#forms[@]}" ] || shc_unknown=1
  IFS=$' \t\n'
  set +f
}

decode_shell_c
# Thân -c guard không giải được thì thư mục của push là chưa biết, tức hỏi (4.11 cũ): thân nhiều dòng (dòng mở thân bằng nháy
# mà không đóng; grep đọc từng dòng) và shell là biến ($SHELL -c, "${SHELL}" -lc, ${SHELL:-bash} -c). Chỉ một lần grep ở locale C mỗi dạng.
# Shell từ lệnh lồng ($(command -v bash) -c, `which bash` -c) cũng vậy.
SHV='(^|[;&|(`{[:space:]])"?([$][{]?[A-Za-z_][A-Za-z0-9_]*([:]?[-=?+][^}[:space:]]*)?[}]?|[$][(][^)]*[)]|`[^`]*`)"?([[:space:]]+('"$SHOPT"'))*[[:space:]]+-[A-Za-z]*c'
# Từ của thân đi qua các đoạn đã đóng ('…', "…", \x, chữ thường) rồi gặp nháy mở chưa đóng ở cuối dòng.
SHO='([^'"'"'"[:space:]\\]|\\.|'"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*")*('"'"'[^'"'"']*|"([^"\\]|\\.)*)$'
# Thân ANSI-C ($'…\n…') thì chưa giải: \n là xuống dòng thật trong thân. Thân lấy từ biến hay lệnh lồng ("$X", $X,
# "$(printf …)", `…`) thì guard không biết thân.
if LC_ALL=C text_grep "$cmd" -Eq -- "$SHC($SHO|\"?[$\`])" || LC_ALL=C text_grep "$cmd" -Eq -- "$SHV"; then
  shc_unknown=1
fi
# Bỏ dòng trùng (dạng nối cả hai kiểu thường y hệt dạng nối theo tool): mọi luật và các dạng dưới chạy trên cmd, chi phí theo
# độ dài của nó.
cmd="$(printf '%s\n' "$cmd" | LC_ALL=C awk '!s[$0]++')"

# PowerShell tách token ở mọi khoảng trắng Unicode (nhóm Zs, NBSP, U+0085), coi nháy cong là nháy và en/em dash là dấu -,
# còn luật chạy grep ở locale C (rule) nên [[:space:]] chỉ khớp khoảng trắng ASCII. Lệnh có byte ≥ 0x80 thì so thêm một
# dạng đã đổi các ký tự đó sang ASCII; dạng bỏ nháy dưới đây làm trên dạng này thay cho lệnh gốc (nó đã gồm lệnh gốc). Byte dựng bằng printf (BSD sed không
# hiểu \x), sed ở locale C chạy tuyến tính trên byte. ſ và ı đổi thành s và i: GNU grep ở locale UTF-8 gập chúng khi -i,
# nên trước khi luật chạy ở locale C, `git puſh -f` vẫn được hỏi. Bộ đọc JSON bằng sed (KIT_JSON_TOOL=sed) không giải
# \uXXXX, nên đổi cả các escape đó (lệnh thật có đúng chuỗi \u2003 thì chỉ bị hỏi thừa).
src="$cmd"
src_extra=0
if LC_ALL=C text_grep "$cmd" -q -- "$(printf '[\200-\377]')" || case "$cmd" in *'\u'*) true ;; *) false ;; esac; then
  uni="$(printf 's/\302[\205\240]/ /g;s/\341\232\200/ /g;s/\342\200[\200-\212\250\251\257]/ /g;s/\342\201\237/ /g;s/\343\200\200/ /g;s/\342\200[\223-\225]/-/g;s/\342\200[\230-\233]/'"'"'/g;s/\342\200[\234-\236]/"/g;s/\305\277/s/g;s/\304\261/i/g')"
  uesc='s/\\u00[aA]0/ /g;s/\\u0085/ /g;s/\\u1680/ /g;s/\\u200[0-9aA]/ /g;s/\\u202[89fF]/ /g;s/\\u205[fF]/ /g;s/\\u3000/ /g'
  uesc="$uesc;"'s/\\u201[3-5]/-/g;s/\\u201[89abAB]/'"'"'/g;s/\\u201[c-eC-E]/"/g;s/\\u017[fF]/s/g;s/\\u0131/i/g'
  un="$(printf '%s\n' "$cmd" | LC_ALL=C sed -e "$uni" -e "$uesc")"
  # Cổng push đọc cả dạng này: `git -C ‘M’ push`, `Push-Location<U+3000>M`, `Set-Location –Path M`.
  if [ "$un" != "$cmd" ]; then
    src="$un"; cmd="$cmd$nl$un"; forms+=("$un")
    # Thân -c sau khoảng trắng mà glibc không xếp vào [[:space:]] (PowerShell `bash<NBSP>-c '…'`, cả U+202F, U+2007, U+0085,
    # và \uXXXX khi đọc JSON bằng sed; reviewer PR #86): grep SHC trên dạng gốc không thấy `bash -c`, nên giải thân và kiểm
    # thân chưa biết (SHO, SHV) thêm một lần trên dạng này. Thân mới nối vào $src nhưng không tính vào trần 65536 của dq2,
    # dq3 (src_extra): phần lớn là bản chép của thân đã giải ở lượt đầu, tính vào thì lệnh ~55 KB có en dash mất dq2 mà
    # main vẫn có (reviewer PR #87). Độ dài thêm có trần là ngân sách của một lần decode_shell_c.
    shc_new=""
    decode_shell_c $((${#forms[@]} - 1))
    src="$src$shc_new"; src_extra=${#shc_new}
    if LC_ALL=C text_grep "$un" -Eq -- "$SHC($SHO|\"?[$\`])" || LC_ALL=C text_grep "$un" -Eq -- "$SHV"; then
      shc_unknown=1
    fi
  fi
fi

# Chữ lệnh bị nháy hay \ xé đôi (`git pu'sh'`, `r'm' -rf /`, `--for"ce"`, `--ha''rd`, `$'p'ush`): bash bỏ nháy giữa từ rồi
# chạy y như bản không nháy, còn mọi luật so trên chữ liền nhau. Mọi luật so thêm hai dạng:
# - dq: bỏ `$` trước nháy, nháy quanh đoạn không có khoảng trắng và \ trước ký tự không phải khoảng trắng;
# - dx: xoá hết ' " \ (sed ghép cặp nháy từ trái sang, không biết \' là nháy đã thoát: `echo \';r'm'` thành `rm'`).
# Hai dạng chỉ thêm chữ để khớp: hỏi thừa (echo 'pu'sh) chứ không bỏ sót những lệnh này. sed, tr chạy tuyến tính, không
# dùng ${x//a/b} (xem join_lines). Cổng push không đọc thư mục từ hai dạng này (dx tách đường "a b", dq ghép nhầm nháy).
# Thay vào đó, một token của lệnh gốc mà bỏ ' " \ $ thì thành từ khoá thư mục hay option của cd (c'd', -'C', '--', c\d,
# "cd", buil'ti'n, --git-dir'=', "GIT_DIR=) làm thư mục của push thành chưa biết, tức hỏi. Riêng tên lệnh cd, một nháy lẻ
# ở đầu hay cuối token ('cd, "cd của thân bash -c) không xé gì; token của option dừng ở `=` nên không có ngoại lệ đó. Xét
# từng token của chính lệnh, nên không có phép so hai dạng nào để biến đổi bù nhau (cd$'x'; c'd') vượt qua.
# kw_awk: in x khi một token (mỗi dòng một token) bỏ ' " \ $ thì thành từ khoá thư mục, option của cd hay tên shell; dùng
# cho token bị nháy xé (torn) và token bị xé theo cách của dạng dz (tk, bên dưới).
kw_awk='
  BEGIN { cd = "^(cd|chdir|pushd|sl|set-location|push-location)$"; q = "\047"
          kw = "^(builtin|command|-c|--chdir|--git-dir|--work-tree|git_dir|git_work_tree"
          kw = kw "|-p|-l|--|-passthru|-path|-literalpath|eval)$"
  cd = cd "|^((ba|da|z|k|a|mk|y)?sh|bash[0-9.]*|fish)(\\.exe)?$" }
  { s = $0; gsub(/["\047\\$]/, "", s); s = tolower(s)
    if (s ~ kw || (s ~ cd && $0 != q s && $0 != s q && $0 != "\"" s && $0 != s "\"")) { print "x"; exit } }'
case "$src" in
  *[\"\'\\]*)
    dq="$(printf '%s\n' "$src" | LC_ALL=C sed -e "s/\\$\\(['\"]\\)/\\1/g" -e "s/'\\([^'[:space:]]*\\)'/\\1/g" \
      -e 's/"\([^"[:space:]]*\)"/\1/g' -e 's/\\\([^[:space:]\\]\)/\1/g')"
    dx="$(printf '%s\n' "$src" | LC_ALL=C tr -d "\"'\\\\")"
    torn="$(printf '%s\n' "$cmd" | grep -Eo -- "[[:alnum:]_'\"\\\\\$-]+" | grep -E -- "[\"'\\\\\$]" | LC_ALL=C awk "$kw_awk")"
    [ -z "$torn" ] || shc_unknown=1
    cmd="$cmd$nl$dq$nl$dx"
    # dq ghép cặp nháy từ trái sang: `"\"a b\""` thành `\a b\`, giá trị option bị tách đôi nên `"push"` sau nó không còn là
    # lệnh con (`git -c user.name="\"a b\"" "push" -f`, reviewer PR #75). Dạng dq2 thay `\"` bằng \002 trước khi ghép: giá trị
    # thành `"\002a b\002"` (một từ có nháy, OA/OQ khớp), `"push"` thành push. Lệnh có `\\"` thêm dạng dq3: `\\` (một `\`
    # đã thoát trong nháy kép) thay bằng \003 trước, để `"\"a b\\"` không thành `\` + \002 nuốt nháy đóng (reviewer PR #78).
    # dq3 thêm bên cạnh dq2, không thay: trong nháy đơn `\\` là hai ký tự thường, `'x\\"'"y z"` chỉ dq2 bắt được (reviewer
    # PR #79). $src quá 65536 ký tự (đếm ký tự, sau khi gom các dạng joined/kept/`bash -c`) thì bỏ (luật chạy trên cả $cmd,
    # mỗi dạng thêm một lượt).
    case "$src" in
      *'\"'*)
        if [ $((${#src} - src_extra)) -le 65536 ]; then
          dqs="s/\\$\\(['\"]\\)/\\1/g;s/'\\([^'[:space:]]*\\)'/\\1/g;"'s/"\([^"[:space:]]*\)"/\1/g;s/\\\([^[:space:]\\]\)/\1/g'
          dq2="$(printf '%s\n' "$src" | LC_ALL=C sed -e "s/\\\\\"/$(printf '\002')/g" -e "$dqs")"
          cmd="$cmd$nl$dq2"
          case "$src" in
            *'\\"'*)
              dq3="$(printf '%s\n' "$src" | LC_ALL=C sed -e "s/\\\\\\\\/$(printf '\003')/g" -e "s/\\\\\"/$(printf '\002')/g" -e "$dqs")"
              cmd="$cmd$nl$dq3"
              ;;
          esac
        fi
        ;;
    esac
    # `;&|` trong nháy không ngắt lệnh, mà luật dừng ở chúng (`push[^;&|]*--force`): `git push origin "x;y" --force`,
    # `git push -o 'a|b' --force`. Thêm một dạng thay chúng bằng _ trong đoạn nháy không có khoảng trắng (chỉ thêm chữ để
    # khớp, lệnh gốc vẫn được so). Đoạn có khoảng trắng thường là thân lệnh (`bash -c "git push … && gh pr create --base
    # main"`, `ssh h 'a; b'`): nối các lệnh trong đó lại thì luật khớp xuyên qua chúng (reviewer PR #53). Dòng quá 16 KB
    # bỏ qua: substr của onetrue-awk 2 chép cả dòng, vòng match bậc hai theo độ dài.
    if LC_ALL=C text_grep "$src" -Eq -- '"[^"[:space:]]*[;&|][^"[:space:]]*"|'"'"'[^'"'"'[:space:]]*[;&|][^'"'"'[:space:]]*'"'"''; then
      qm="$(printf '%s\n' "$src" | LC_ALL=C awk 'length($0) > 16384 { print ""; next }
        { s = $0; out = ""
          while (match(s, /"[^" \t\\]*"|\047[^\047 \t]*\047/)) {
            seg = substr(s, RSTART, RLENGTH); gsub(/[;&|]/, "_", seg)
            out = out substr(s, 1, RSTART - 1) seg; s = substr(s, RSTART + RLENGTH) }
          print out s }')"
      cmd="$cmd$nl$qm"
    fi
    ;;
esac

# Chữ lệnh bị xé theo cách khác (4.10, reviewer thử bằng bash thật): `\` nối dòng giữa chữ (`git pu\` ⏎ `sh`: bash bỏ cả `\`
# lẫn xuống dòng, còn join_lines chèn dấu cách), mở rộng rỗng (`pu$()sh`, ``pu``sh``, `pu${X}sh`), ANSI-C (`$'\x70'ush`,
# `$'pu\163h'`), ngoặc nhọn (`git {push,}`, `r{m,} -rf`), backtick thoát của PowerShell (``pu`sh``). Mọi luật so thêm dạng dz:
# nối các dòng đó không chèn gì, bỏ $(…), ${…}, cặp backtick, lấy nhánh đầu của {a,b}, giải \xHH và \NNN trong $'…', rồi xoá
# ' " \ `. Chỉ thêm chữ để khớp: hỏi thừa chứ không bỏ sót. awk, sed, tr tuyến tính; bước $'…' bỏ qua dòng quá 16 KB
# (substr của onetrue-awk 2 chép cả dòng). Cổng push không đọc thư mục từ dạng này; ngoặc nhọn, hay thân -c dùng tham số vị
# trí (`bash -c 'cd M && git "$@"' _ push`), thì thư mục của push là chưa biết, tức hỏi.
# Chỉ `\` dính chữ trước nó (`pu\`) mới nối không chèn gì: ` \` cuối dòng là nối dòng thường, dạng nối của join_lines đã đủ,
# và nối cả lệnh dài (long-uni, long-colon của test-hooks) thành thêm một dòng ~230 KB làm luật chậm gấp đôi (macOS quá 10 giây).
# lex_awk: cho đường thay-trước-khi-tách của tk. Trong '…' và $'…' (kể cả trải nhiều dòng), ` $ ( ) { } thành _ (trong '…'
# cả \): chữ, không mở gì, nên `echo '`'; cd`:` M` không ghép backtick trong nháy với backtick thật. \` và \$ ngoài nháy
# đơn thành \_; comment (# đầu từ ngoài nháy) bỏ tới hết dòng. Ký tự lấy bằng split(s, a, ""): substr từng ký tự là bậc
# hai trên awk BWK. Thân here-doc (<<W, <<-W, <<'W', cả nhiều here-doc một dòng) tới dòng đúng bằng W: ` $ ( ) { } \
# thành _, không đổi trạng thái nháy (nháy đơn trong `don't` không mở nháy).
# $( mở tầng mới (nháy trong đó tính riêng, `"$(echo "it's")"`), ) cùng tầng đóng; trong backtick chỉ tìm backtick đóng.
# Không nhận here-doc ở <<< hay trong ((…)) hay $[…] (`1<<2`; (( tắt khi ) đưa độ sâu ngoặc về mức lúc mở, (( trong ${…} không tính; $[ tắt ở ] khớp, đếm [ ]), dấu phân cách quá 256 ký tự; $' chỉ khi $
# chưa thoát, không thuộc $$; # sau ) mở comment, trừ ) đóng $(…) (`$(x)#y` là một từ) và trong ${…}. Bộ đọc này vẫn có thể đọc sai, nên tk chạy thêm một lượt không qua nó.
lex_awk='BEGIN { hh = 1 }
{
  if (hh <= nh) {
    l = $0; if (ht[hh]) sub(/^\t+/, "", l)
    if (l == hq[hh]) { hh++; print; next }
    gsub(/[`$(){}\\]/, "_"); print; next
  }
  nh = 0; hh = 1; pd = 0; bd = 0; pp = 0
  n = split($0, ch, "")
  if (st == 4) st = 0
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (st == 1) { if (c == "\047") st = 0; else if (index("`$(){}\\", c)) c = "_" }
    else if (st == 3) {
      if (c == "\\" && i < n) { i++; d = ch[i]; if (index("`$(){}", d)) d = "_"; c = c d }
      else if (c == "\047") st = 0
      else if (index("`$(){}", c)) c = "_"
    }
    else if (c == "\\" && i < n) { i++; d = ch[i]; if (d == "`" || d == "$") d = "_"; else if (dm && st == 2 && d == "\"") d = "\002"; c = c d }
    else if (st == 5) { if (c == "`") st = bq }
    else if (c == "$" && ch[i + 1] == "(") {
      sp++; sk[sp] = st; pc[sp] = 0; if (!ov) { sv[sp] = sb; bv[sp] = bd; sb = 0; bd = 0 }; st = 0; if (ch[i + 2] == "(" && !ar) { ar = 1; ad = gd }; gd++
      printf "%s", "$("; i++; continue
    }
    else if (c == "`") { bq = st; st = 5 }
    else if (st == 2) { if (c == "\"") st = 0 }
    else if (c == "$") {
      pd = (pd && pd == i - 1) ? 0 : i
      if ((pd || ov) && ch[i + 1] == "{") bd++
      else if ((pd || ov) && ch[i + 1] == "[") { sb++; printf "%s", "$["; i++; continue }
    }
    else if (c == "[" && sb) sb++
    else if (c == "]" && sb) sb--
    else if (c == "\047") st = (pd && pd == i - 1) ? 3 : 1
    else if (c == "\"") st = 2
    else if (c == "}" && bd) bd--
    else if (c == "(") { if (ch[i + 1] == "(" && !ar && !bd) { ar = 1; ad = gd }; gd++; if (sp) pc[sp]++ }
    else if (c == ")") { if (gd > 0) gd--; if (ar && gd <= ad) ar = 0; if (sp && pc[sp]) pc[sp]--; else if (sp) { st = sk[sp]; if (!ov) { sb = sv[sp]; bd = bv[sp] }; sp--; pp = i } }
    else if (c == "#" && !bd && pp != i - 1 && (i == 1 || index(" \t;&|()", ch[i - 1]))) { st = 4; break }
    else if (c == "<" && !ar && !sb && i + 1 < n && ch[i + 1] == "<" && ch[i + 2] != "<" && (i == 1 || ch[i - 1] != "<")) {
      j = i + 2; t = 0; w = ""
      if (ch[j] == "-") { t = 1; j++ }
      while (j <= n && (ch[j] == " " || ch[j] == "\t")) j++
      for (; j <= n && !index(" \t;&|\074\076()", ch[j]); j++) if (!index("\047\"\\", ch[j]) && length(w) <= 256) w = w ch[j]
      if (w != "" && length(w) <= 256) { nh++; hq[nh] = w; ht[nh] = t }
      for (; i < j; i++) printf "%s", ch[i]
      i--; continue
    }
    printf "%s", c
  }
  print ""
}'
# tb_awk: bỏ backtick đơn ở cuối token (`` `mkdir -p` `` trong commit message), trừ khi phần còn lại là từ khoá thư mục:
# `` `echo cd` M ``, `` git `echo -C` M push `` là cd, -C do lệnh con sinh ra.
tb_awk='/^[^`]*`$/ { s = substr($0, 1, length($0) - 1); t = tolower(s)
    if (s != "-C" && t !~ /^(cd|chdir|pushd|sl|set-location|push-location|--chdir|--git-dir|--work-tree|git_dir|git_work_tree|eval|builtin|command)$/) $0 = s }
  { print }'
# dec_awk: giải $'…' của từng dòng như bash (dùng cho dạng dz và cho token bị xé, tk).
# Cắt theo \ và theo nháy rồi in từng mảnh: đọc từng ký tự bằng length/substr hay ghép chuỗi dần là bậc hai
# (awk BWK của macOS: 17 dòng \x41 ×4090 mất 21 giây).
# \xH hay \xHH, \N tới \NNN lấy 8 bit thấp; \uHHHH, \UHHHHHHHH dưới 128 ra ký tự đó, còn lại thành _ (không là chữ
# của luật nào). Mỗi dòng in hai lần: m = 0 như bash ($'…' thật: \0 cắt phần còn lại,
# ; & | xuống dòng giải ra ngắt lệnh trong bash -c, eval), m = 1 cho khi bộ tách nhận nhầm '$' thường là mở $'…'
# (\0 chỉ bỏ ký tự đó, ; & | xuống dòng thành _ để không ngắt luật). Không dùng match với ? liền nhau (mawk 1.3.4
# cho \101 thành \10 rồi 1). Dòng m = 1 chỉ in khi khác dòng m = 0 (gặp \0 hay dấu ngắt giải ra: f).
dec_awk='
        function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
        function dec(t, m,   p, n, k, v, i, l, mx) {
          n = split(t, p, "\\")
          printf "%s", p[1]
          for (k = 2; k <= n; k++) {
            if (p[k] ~ /^x[0-9A-Fa-f]/) {
              l = p[k] ~ /^x[0-9A-Fa-f][0-9A-Fa-f]/ ? 3 : 2
              v = 0; for (i = 2; i <= l; i++) v = v * 16 + hv(substr(p[k], i, 1)) }
            else if (p[k] ~ /^[uU][0-9A-Fa-f]/) {
              mx = p[k] ~ /^u/ ? 5 : 9; l = 2
              while (l < mx && substr(p[k], l + 1, 1) ~ /[0-9A-Fa-f]/) l++
              v = 0; for (i = 2; i <= l; i++) v = v * 16 + hv(substr(p[k], i, 1))
              if (v >= 128) v = 95 }
            else if (p[k] ~ /^[0-7]/) {
              l = p[k] ~ /^[0-7][0-7][0-7]/ ? 3 : p[k] ~ /^[0-7][0-7]/ ? 2 : 1
              v = 0; for (i = 1; i <= l; i++) v = v * 8 + substr(p[k], i, 1); v %= 256 }
            else { printf "\\%s", p[k]; continue }
            if (v == 0 || v == 10 || v == 13 || v == 38 || v == 59 || v == 124) f = 1
            if (v == 0 && !m) return
            if (v == 0) { printf "%s", substr(p[k], l + 1); continue }
            if (m && (v == 10 || v == 13 || v == 38 || v == 59 || v == 124)) v = 95
            printf "%c%s", v, substr(p[k], l + 1) } }
        length($0) > 16384 { print; next }
        { n = split($0, q, "\047"); f = 0
          for (m = 0; m < 1 + f; m++) {
            k = 1
            while (k <= n) {
              if (k < n - 1 && q[k] ~ /[$]$/) { printf "%s", substr(q[k], 1, length(q[k]) - 1); dec(q[k + 1], m); k += 2; continue }
              printf "%s%s", q[k], (k < n ? "\047" : ""); k++ }
            print "" } }'
case "$raw" in
  *[!\ \	\\]"\\$nl"* | *'$('* | *'`'* | *'${'* | *"\$'"* | *'{'* | *'$@'* | *'$*'* | *'$'[0-9]* | *'$'[A-Za-z_]* | *'$!'*)
    # Chỉ giữ dòng được nối hay có dấu xé ($(, ${, $', `, {a,b}): dòng khác đã có ở các dạng sẵn có, chép lại chỉ làm luật chậm.
    dz="$(printf '%s\n' "$raw" | LC_ALL=C awk '
        $0 ~ /[^ \t\\]\\$/ { printf "%s", substr($0, 1, length($0) - 1); j = 1; next }
        j || /[$][({\047]|`|[{][^{}]*,/ { print; j = 0 }' |
      LC_ALL=C sed -e 's/[$](\([^()]*\))//g' -e 's/[$]{[^{}]*}//g' -e 's/``//g' \
        -e 's/{\([^,{}[:space:]]*\),[^{}[:space:]]*}/\1/g' |
      LC_ALL=C awk "$dec_awk")"
    dzp="$dz"
    dz="$(printf '%s\n' "$dz" | LC_ALL=C tr -d "\"'\\\\\`")"
    cmd="$cmd$nl$dz"
    # dz2 (4.10, Luật): như dz, thêm dòng chỉ có \ sau dòng nối (`git pu\` ⏎ `\` ⏎ `sh`), $(…) và ${…} lồng (8 lượt:
    # `pu$(echo $(true))sh`, `pu${X:-${Y}}sh`), backtick có nội dung (``pu`true`sh``), biến (`pu$@sh`, `pu$9sh`, `pu$!sh`,
    # `pu$X''sh`), ngoặc nhọn lồng (nhánh đầu, 4 lượt) và một dòng mở ngoặc nhọn như bash, mỗi nhánh một từ có kèm tiền tố, hậu tố
    # (`git {,push}` thành `git push`, `rm -rf {,~}` thành `rm -rf ~`, `{/,}src` thành `/src src`; 8 lượt, trong cùng trước).
    # dz giữ nguyên (backtick có nội dung có thể ghép nhầm với backtick trong nháy), dz2 chỉ thêm dòng.
    # Biến chỉ bỏ khi dính sau chữ (`pu$X''sh`); `rm -rf "$dir"/*`, `$OUT/*` giữ nguyên như main. Dòng mở ngoặc nhọn bỏ qua dòng
    # quá 4 KB, dừng khi dòng ra quá 4 lần dòng vào cộng 256 (`{a,…×3000}{b,…×3000}` là 9 triệu từ) và ngừng mở khi
    # tổng đã ra quá 64 KB (950 dòng ngắn làm $cmd thành 7,5 MB, bash 3.2 quét lại quá 10 giây), biên từ tìm bằng match bắt đầu ở khoảng trắng (substr từng ký tự,
    # hay match kết bằng $ không neo, là bậc hai trên awk BWK và mawk; reviewer PR #64).
    xz='s/[$](\([^()]*\))//g;s/[$]{[^{}]*}//g;s/`[^`]*`//g'
    bz='s/{\([^,{}[:space:]]*\),[^{}[:space:]]*}/\1/g'
    vz='s/\([[:alnum:]_]\)[$][@*0-9!]/\1/g;s/\([[:alnum:]_]\)[$][A-Za-z_][A-Za-z0-9_]*/\1/g'
    dz2="$(printf '%s\n' "$raw" | LC_ALL=C awk '
        $0 ~ /[^ \t\\]\\$/ || (j && $0 == "\\") { printf "%s", substr($0, 1, length($0) - 1); j = 1; next }
        j || /[$][({\047@*!0-9A-Za-z_]|`|[{][^{}]*,/ { print; j = 0 }' |
      LC_ALL=C sed -e "$vz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$vz")"
    dz2="$(printf '%s\n' "$dz2" | LC_ALL=C sed -e "$bz" -e "$bz" -e "$bz" -e "$bz"
      printf '%s\n' "$dz2" | LC_ALL=C awk 'tot <= 65536 && length($0) <= 4096 && /[{][^{}]*,/ {
        l = $0; cap = 4 * length($0) + 256
        for (it = 0; it < 8 && match(l, /[{][^{}[:space:]]*,[^{}[:space:]]*[}]/); it++) {
          st = RSTART; ln = RLENGTH; h = substr(l, 1, st - 1); t = substr(l, st + ln)
          a = match(h, /[[:space:]][^[:space:]]*$/) ? RSTART + 1 : 1; pre = substr(h, a)
          match(t, /^[^[:space:]]*/); suf = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1)
          n = split(substr(l, st + 1, ln - 2), br, ","); out = ""
          for (k = 1; k <= n && length(out) <= cap; k++) out = out (k > 1 ? " " : "") pre br[k] suf
          l = substr(h, 1, a - 1) out t
          if (length(l) > cap) break }
        tot += length(l); print l }')"
    dz2="$(printf '%s\n' "$dz2" | LC_ALL=C awk "$dec_awk")"
    dzp="$(printf '%s\n' "$dzp" "$dz2" | LC_ALL=C awk '!s[$0]++')"
    dz2="$(printf '%s\n' "$dz2" | LC_ALL=C tr -d "\"'\\\\\`")"
    cmd="$cmd$nl$dz2"
    # dz, dz2 xoá hết nháy nên giá trị option có dấu cách trong nháy hay sau `\` bị tách đôi: `git -C "x y" pu``sh -f`,
    # `user.name='a b'`, `a\ b`, `user.name="\"a b\""` thành `x y push`, `b` là lệnh con (verifier PR #87, reviewer PR #88;
    # dq, dq2 không ghép `pu``sh`). Dạng dzq: các dòng của dz, dz2 trước khi xoá nháy, đọc như dq2 (và dq3 khi có `\\"`),
    # để giá trị thành một từ có nháy và `push` đứng sau nó. `$'a b'` vẫn lọt: dec_awk đã bỏ nháy của nó.
    # Chỉ các dòng có dấu xé (bỏ dòng trùng giữa dz và dz2), cùng trần 65536 ký tự như dq2.
    dzq_add() {
      case "$1" in
        *[\"\'\\]*)
          if [ "${#1}" -le 65536 ]; then
            dzs="s/\\$\\(['\"]\\)/\\1/g;s/'\\([^'[:space:]]*\\)'/\\1/g;"'s/"\([^"[:space:]]*\)"/\1/g;s/\\\([^[:space:]\\]\)/\1/g'
            dzq="$(printf '%s\n' "$1" | LC_ALL=C sed -e "s/\\\\\"/$(printf '\002')/g" -e "$dzs")"
            cmd="$cmd$nl$dzq"
            case "$1" in
              *'\\"'*)
                dzq="$(printf '%s\n' "$1" | LC_ALL=C sed -e "s/\\\\\\\\/$(printf '\003')/g" -e "s/\\\\\"/$(printf '\002')/g" -e "$dzs")"
                cmd="$cmd$nl$dzq"
                ;;
            esac
          fi
          ;;
      esac
    }
    dzq_add "$dzp"
    # Nối dòng thường (` \` cuối dòng) rồi dòng sau có chữ xé (`git \` ⏎ `pu``sh -f`, `npm \` ⏎ `pub``lish`, reviewer PR #88):
    # awk của dz, dz2 chỉ nối khi `\` dính chữ, dạng nối của join_lines không bỏ mở rộng rỗng. Dạng dzc: mỗi chuỗi nối có ít
    # nhất một ` \` (cả `\` dính chữ và dòng chỉ có `\` trong chuỗi) nối thành một dòng, chỉ giữ chuỗi có dấu xé, rồi đọc như
    # dz, dz2 (bỏ mở rộng rỗng, nhánh đầu của ngoặc nhọn, giải $'…', xoá nháy) và dzq. Chỉ thêm dòng: dz, dz2, dzq ở trên
    # giữ nguyên như trước, vì gộp thay cho dòng cũ làm `timeout 60 \` ⏎ `r``m -rf ~` mất `rm` ở đầu dòng (reviewer PR #89).
    # Chuỗi dài hơn 4096 ký tự bỏ qua (dec_awk và bước mở ngoặc nhọn bỏ dòng dài), tổng dừng ở 65536.
    # `\` dính chữ cũng mở hay nối tiếp chuỗi và tự là dấu xé (`git \` ⏎ `pu\` ⏎ `sh -f`, `git pu\` ⏎ `sh \` ⏎ `-f`: dz, dz2
    # chỉ ghép nửa từ; reviewer PR #89 lần 2). Chuỗi chưa đóng ở cuối lệnh cũng in (bộ đọc JSON cắt xuống dòng cuối).
    cj="$(printf '%s\n' "$raw" | LC_ALL=C awk '
        function pr(l) { if (o && length(l) <= 4096 && tot <= 65536 && (s || l ~ /[$][({\047@*!0-9A-Za-z_]|`|[{][^{}]*,/)) {
            tot += length(l); print l } }
        { l = $0
          if (l ~ /[ \t]\\$/ || l ~ /[^ \t\\]\\$/ || (c && l ~ /\\$/)) {
            if (l ~ /[ \t]\\$/) o = 1; if (l ~ /[^ \t\\]\\$/) s = 1
            c = 1; if (length(b) <= 4096) b = b substr(l, 1, length(l) - 1); next }
          if (c) pr(b l)
          b = ""; c = 0; o = 0; s = 0 }
        END { if (c) pr(b) }')"
    if [ -n "$cj" ]; then
      dzc="$(printf '%s\n' "$cj" | LC_ALL=C sed -e 's/[$](\([^()]*\))//g' -e 's/[$]{[^{}]*}//g' -e 's/``//g' -e "$bz" |
        LC_ALL=C awk "$dec_awk")"
      dzc2="$(printf '%s\n' "$cj" | LC_ALL=C sed -e "$vz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" -e "$xz" \
        -e "$vz" -e "$bz" -e "$bz" -e "$bz" -e "$bz" | LC_ALL=C awk "$dec_awk")"
      dzcp="$(printf '%s\n' "$dzc" "$dzc2" | LC_ALL=C awk '!s[$0]++')"
      cmd="$cmd$nl$(printf '%s\n' "$dzcp" | LC_ALL=C tr -d "\"'\\\\\`")"
      # Riêng từng dạng: gộp dzc với dzc2 thì trần 65536 của dzq_add đầy ở ~35 KB chuỗi nối (reviewer PR #89 lần 2).
      dzq_add "$dzc"
      dzq_add "$dzc2"
    fi
    # Cổng push không đọc dz. Một token của lệnh có dấu xé ($(, ${, $', backtick, {, hay \ nối dòng dính chữ) mà xé xong
    # thành từ khoá thư mục (`c$()d M`, ``c``d M``, `$'\x63'd M`, `git -$'\x43' M push`, `c\` ⏎ `d M`, `c{d..d} M`) làm thư
    # mục của push thành chưa biết, tức hỏi. Nối dòng (kể cả dòng chỉ có \ sau nó), $(…), ${…}, cặp backtick và $@ $* $0-9
    # được thay bằng \001 TRƯỚC khi tách token: nội dung của chúng (`c$(: x)d`, `c${X:-}d`, ``c` `d``) không cắt đôi token,
    # và token vẫn mang dấu xé. Token không có dấu xé (cd thường) không qua bước này.
    # Thay trước khi tách không biết nháy: dấu mở trong nháy hay đã thoát (`echo '`'; c``d M`) ghép với dấu thật phía sau và
    # nuốt token xé ở giữa. Nên chạy thêm đường cũ (tách token trước, rồi bỏ phần mở rộng trong token), đường nào ra từ khoá
    # cũng hỏi; đường cũ bỏ backtick đơn ở đầu token (mở lệnh con, `echo "`command -v git`"`) và token là trọn một lệnh con
    # (``bash`` trong commit message), xoá $X $@ $1 $!. Đường mới qua lex_awk (nháy, here-doc, comment) rồi mới ghép cặp
    # (``c`echo \`:\``d``, `echo '`'; cd`:` M`), và thêm một lượt không qua lex_awk (chỉ \` thành \001, như trước) để lex đọc
# sai không làm lọt thứ đã bắt; đường cũ bỏ cả backtick đơn ở cuối token trừ từ khoá thư mục (tb_awk); $(…) ${…} `…` thay 8 lượt cho
    # dạng lồng (`c$($(true))d`, `c${X:-${Y}}d`); $X, $! thành \001 (`c$X'd'`, `c$!d`); dãy có bước (`c{d..d..1}`, `..+1`). Còn lọt: lồng quá
    # 8 tầng, ngoặc trong $(…) (`c$( (:) )d`), $(…) hay backtick trải nhiều dòng (4.10 của docs/viec-can-lam.md).
    jn="$(printf '%s\n' "$raw" | LC_ALL=C awk '$0 ~ /[^ \t\\]\\$/ || (j && $0 == "\\") {
          printf "%s\001", substr($0, 1, length($0) - 1); j = 1; next }
        { j = 0; print }')"
    ex="s/[$](\([^()]*\))/$soh/g;s/[$]{[^{}]*}/$soh/g;s/\`[^\`]*\`/$soh/g"
    # lex_awk chạy hai lần: bản mới, và bản ov = 1 đọc $$, $( như main (không lưu/xoá sb, bd ở $(; $$[, $${ vẫn mở $[, ${).
    # Bộ đếm ngoặc không biết ) trong ${…} (`$(echo ${x:-) #})`), nên mỗi bản đọc sai một kiểu; đường nào ra từ khoá cũng hỏi.
    for lx in "$lex_awk" "BEGIN { ov = 1 }$lex_awk" '{ gsub(/\\`/, "\001"); print }'; do
    tk="$(printf '%s\n' "$jn" | LC_ALL=C awk "$lx" |
      LC_ALL=C sed -e "$ex" -e "$ex" -e "$ex" -e "$ex" -e "$ex" -e "$ex" -e "$ex" -e "$ex" \
        -e "s/[$][@*0-9!]/$soh/g" -e "s/[$][A-Za-z_][A-Za-z0-9_]*/$soh/g" |
      LC_ALL=C grep -Eo -- "[[:alnum:]_'\"\\\\\$(){}\`,.+$soh-]+" | LC_ALL=C grep -E -- "[\$][({']|\`|[{]|$soh" |
      LC_ALL=C sed -e 's/{\([^,{}[:space:]]*\),[^{}[:space:]]*}/\1/g' -e 's/{\([[:alpha:]]\)[.][.]\1}/\1/g' \
        -e 's/{\([[:alpha:]]\)[.][.]\1[.][.][-+]*[0-9][0-9]*}/\1/g' |
      LC_ALL=C awk "$dec_awk" | LC_ALL=C tr -d "\"'\\\\\`$soh" | LC_ALL=C awk "$kw_awk")"
    [ -z "$tk" ] || shc_unknown=1
    done
    tk="$(printf '%s\n' "$jn" | LC_ALL=C grep -Eo -- "[[:alnum:]_'\"\\\\\$(){}\`,.+@*!$soh-]+" |
      LC_ALL=C sed -e 's/^`\([^`]*\)$/\1/' -e '/^["'"'"']*`[^`]*`["'"'"']*$/d' | LC_ALL=C awk "$tb_awk" | LC_ALL=C grep -E -- "[\$][({'A-Za-z_@*0-9!]|\`|[{]|$soh" |
      LC_ALL=C sed -e 's/[$](\([^()]*\))//g' -e 's/[$]{[^{}]*}//g' -e 's/[$][A-Za-z_][A-Za-z0-9_]*//g' -e 's/[$][@*0-9!]//g' \
        -e 's/``//g' \
        -e 's/{\([^,{}[:space:]]*\),[^{}[:space:]]*}/\1/g' -e 's/{\([[:alpha:]]\)[.][.]\1}/\1/g' \
        -e 's/{\([[:alpha:]]\)[.][.]\1[.][.][-+]*[0-9][0-9]*}/\1/g' |
      LC_ALL=C awk "$dec_awk" | LC_ALL=C tr -d "\"'\\\\\`$soh" | LC_ALL=C awk "$kw_awk")"
    [ -z "$tk" ] || shc_unknown=1
    # Tên shell rồi một từ do lệnh con sinh ra (`bash `echo -c` 'cd M && git push'`, `sh $(echo -c) …`): cờ và thân là chưa
    # biết, thư mục của push cũng vậy. Có thể có cờ xen giữa (`bash -e`, `bash -o errexit`) hay nháy kép (`bash "$(…)"`); đọc
    # trên $cmd để thấy dạng đã nối dòng (`bash \⏎`…``).
    # Đọc mọi dạng của $cmd (cả dx, dz đã bỏ hết nháy): bỏ dạng nào cũng làm lọt lệnh main vẫn hỏi (đường dẫn shell có
    # khoảng trắng trong nháy, đối số --rcfile có nháy lẻ, cờ xé cả nháy lẫn $(…); reviewer PR #63), nên chịu hỏi thừa
    # `--title "fix zsh" --body "$(…)"`.
    if LC_ALL=C text_grep "$cmd" -Eiq -- '(^|[^[:alnum:]_.-])((ba|da|z|k|a|mk|y)?sh|bash[0-9.]*|fish)(\.exe)?([[:space:]]+([-+][oO][[:space:]]+[[:alnum:]_]+|[-+][^[:space:]`$"]*))*[[:space:]]+"?(`|[$][(])'; then
      shc_unknown=1
    fi
    # Ngoặc nhọn ra từ khoá thư mục (`{cd,} M`, `git {-C,} M push`), hay ở đối số của chúng (`cd {M,}`, `git -C {M,} push`):
    # thư mục chưa biết. `mkdir -p src/{a,b}` thì không.
    if LC_ALL=C text_grep "$raw" -Eiq -- '[{](cd|chdir|pushd|sl|set-location|push-location|builtin|command|-C|--chdir|--git-dir|--work-tree|git_dir|git_work_tree)[=,]|(^|[^[:alnum:]_-])(cd|chdir|pushd|sl|set-location|push-location|-C|--chdir|--git-dir|--work-tree|git_dir|git_work_tree)([[:space:]=]+-[^[:space:]]*)*[[:space:]=]+[^[:space:];&|]*[{][^}]*,'; then
      shc_unknown=1
    fi
    ;;
esac
case "$raw" in
  *'$@'* | *'$*'* | *'${@'* | *'${*'* | *'$'[0-9]* | *'${'[0-9]*)
    if LC_ALL=C text_grep "$cmd" -Eq -- "$SHC"; then
      shc_unknown=1
    fi
    ;;
esac

reason=""
# rule <mẫu> <lý do>: gom luật; sau luật cuối, một lần grep với mọi mẫu lấy dòng khớp đầu tiên, rồi mới xét từng luật theo
# thứ tự trên dòng đó (cmd gồm nhiều dạng của lệnh, 24 lần quét cả cmd từng mất vài giây với lệnh dài). LC_ALL=C: mọi mẫu là
# ASCII, và grep -Ei ở locale UTF-8 chậm bậc hai trên dòng nối rất dài (luật refspec `:` trên 253 KB mất 10 giây).
rule_e=()
rule_re=()
rule_why=()
rule() {
  rule_e+=(-e "$1")
  rule_re+=("$1")
  rule_why+=("$2")
}

S='[[:space:]]'
# Kết thúc một từ: khoảng trắng, dấu nối lệnh, dấu nháy hoặc hết chuỗi.
# shellcheck disable=SC1003  # dấu \ trong bracket là ký tự cần khớp
E='([[:space:];&|)"\'"'"']|$)'
# Option chen giữa tên tool và subcommand: git -C dir, kubectl -n prod, terraform -chdir=infra...
# Giá trị option có thể nằm trong nháy và chứa dấu cách: git -C "C:/my repo" push.
# Giá trị không nháy: đọc theo cả hai cách, \ là ký tự thường (PowerShell: C:\x\) hoặc là escape
# (bash: my\ repo). Regex được chọn cách nào khớp, nên hỏi thừa chứ không bỏ sót.
# Một từ của shell có thể ghép nhiều đoạn nháy ("a b"/'x', --git-dir="a b/".git): QW là một đoạn. Option và giá
# trị của nó đọc thêm theo cách đó (hợp với cách cũ), để giá trị có nhiều dấu cách trong nháy không chặn regex.
# Đoạn nháy kép đọc thêm theo bash (DQE: `\"` không đóng nháy, `git -C "\"main repo\"" push`; reviewer PR #73), hợp với
# cách cũ `"[^"]*"` (đóng ở `\"`): regex chỉ khớp nhiều hơn.
DQE='"([^"\\]|\\.)*"'
QW='("[^"]*"|'"$DQE"'|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"'\\]|\\.)'
OA='("[^"]*"|'"$DQE"'|'"'"'[^'"'"']*'"'"'|[^-[:space:]"'"'"'][^[:space:]]*|([^-[:space:]"'"'"'\\]|\\.)([^[:space:]\\]|\\.)*\\?)'
OQ='("[^"]*"|'"$DQE"'|'"'"'[^'"'"']*'"'"'|[^-[:space:]"'"'"'\\]|\\.)'"$QW"'*\\?'
O='([[:space:]]+-([^[:space:]"'"'"']|"[^"]*"|'"'"'[^'"'"']*'"'"'|["'"'"'])+([[:space:]]+('"$OA|$OQ"'))?)*'
# Vị trí bắt đầu một lệnh (để `git rm` không bị coi là `rm`).
B='(^|[;&|(`"'"'"'{]|\$\(|(^|[[:space:]])(then|do|else|time|xargs|exec|nohup|env)[[:space:]])[[:space:]]*((sudo|doas|wsl)[[:space:]]+)?'
G="git${O}${S}+"
MAIN='(main|master|trunk|production|release)'
# shellcheck disable=SC2016  # $HOME ở đây là ký tự cần khớp, không phải biến
RMT='"?(/|/\*|~/?|~/\*|\$HOME/?|\$\{HOME\}/?|\.|\./|\.\.|\.\./|\*|\./\*)"?'

rule "${G}push[^;&|]*${S}(-f|--force|--force-with-lease|--force-if-includes|--mirror|--delete|-d)${E}" "force-push hoặc xoá nhánh remote"
rule "${G}push[^;&|]*${S}\+[^[:space:]]" "force-push bằng refspec +"
rule "${G}push[^;&|]*${S}:[^[:space:]]" "xoá nhánh remote bằng refspec :nhánh"
rule "${G}push[^;&|]*([[:space:]:]|refs/heads/)${MAIN}${E}" "push thẳng lên nhánh chính"
rule "${G}reset[^;&|]*${S}--hard" "git reset --hard làm mất thay đổi chưa commit"
rule "${G}clean[^;&|]*${S}(-[a-z]*f[a-z]*|--force)${E}" "git clean -f xoá file chưa track"
rule "${B}rm${S}+[^;&|]*(-[a-z]*r[a-z]*|--recursive)[^;&|]*${S}${RMT}${E}" "rm -r trên thư mục rộng"
# PowerShell/cmd: Remove-Item và alias (cả qua `cmd /c`), cờ -r(ecurse) hoặc /s, đích là ổ đĩa,
# gốc ổ hiện tại, thư mục nhà, . .. * (kể cả \* và *.*), trong nháy đơn hoặc kép.
# Dấu \ là dấu phân cách đường dẫn ở đây nên không coi là hết từ (.\dist không phải .).
PSE='([[:space:];&|)"'"'"']|$)'
Q='["'"'"']?'
W='(\*(\.\*)?)?'
PST="${Q}"'([a-z]:[\\/]?'"$W"'|[\\/]'"$W"'|~[\\/]?\*?|\$home[\\/]?\*?|\$\{?env:(userprofile|home|homedrive|systemdrive)\}?[\\/]?\*?|%(userprofile|homepath|homedrive|systemdrive)%[\\/]?\*?|\.\.?[\\/]?\*?|\*(\.\*)?)'"${Q}"
PSF='(-r[a-z]*(:\$true)?|/s)'
PSC="(${B}|cmd(\.exe)?(${S}+/[a-z])*${S}+/[ck]${S}+)(rm|ri|del|erase|rd|rmdir|remove-item)${S}+([^;&|]*${S})?"
rule "${PSC}(${PSF}${S}+([^;&|]*${S})?${PST}|${PST}${S}+([^;&|]*${S})?${PSF})${PSE}" "xoá đệ quy thư mục rộng (PowerShell/cmd)"
rule "(psql|mysql|mariadb|sqlite3|sqlcmd|duckdb|clickhouse)[^|&]*(drop${S}+(table|database|schema)|truncate${S})" "lệnh SQL xoá dữ liệu"
rule "${B}dropdb${S}|prisma${S}+migrate${S}+reset|db:(drop|reset)${E}" "xoá hoặc reset database"
rule "(npm|pnpm|yarn|bun|cargo)${O}${S}+publish" "publish package"
rule "twine${S}+upload|docker${O}${S}+push" "đẩy artifact lên registry"
rule "terraform${O}${S}+(apply|destroy)|kubectl${O}${S}+(apply|delete|replace|rollout|scale|drain)|helm${O}${S}+(install|upgrade|uninstall|delete|rollback)" "thay đổi hạ tầng"
rule "(vercel|netlify)[^;&|]*--prod|fly(ctl)?${O}${S}+deploy|${B}((npm|pnpm|yarn|bun)${S}+(run${S}+)?deploy|make${S}+deploy)${E}" "deploy"
rule "gh${O}${S}+pr${S}+merge|gh${O}${S}+release${S}+create" "merge PR hoặc tạo release (quyết định của người)"
# Chỉ lấy dòng khớp đầu tiên (-m 1): xét thứ tự luật trên mọi dòng khớp từng chậm gấp đôi main khi mọi dòng chỉ khớp luật
# cuối. Lý do có thể khác bản cũ ở lệnh nhiều dòng, nhưng vẫn hỏi; không luật nào khớp riêng dòng đó thì vẫn hỏi.
hits="$(LC_ALL=C text_grep "$cmd" -Ei -m 1 "${rule_e[@]}")"
if [ -n "$hits" ]; then
  reason="lệnh khớp một mẫu hành động không đảo ngược được"
  i=0
  while [ "$i" -lt "${#rule_re[@]}" ]; do
    if LC_ALL=C text_grep "$hits" -Eiq -- "${rule_re[$i]}"; then
      reason="${rule_why[$i]}"
      break
    fi
    i=$((i + 1))
  done
fi

# Các hàm dưới ghi kết quả vào biến (RD, LA, UQ, EN, EO, SD) thay vì in ra: gọi qua $(...) là một lần fork cho mỗi
# cd ở mỗi cách đọc (4.3).
# gone <đường>: đường tuyệt đối (POSIX hay C:/…), không có .. hay \, mà không phải thư mục (lúc này cd tới đó lỗi). [ -d ]
# là builtin, không fork. Dạng C:/… là cwd mà Python của Windows nhận khi Git Bash đổi đường POSIX: không kết luận được thì
# mỗi cd vào thư mục chưa có tốn một subshell (PR #55). Trên Linux đường đó vốn không cd được. Đường có .. (cd -L khác -P),
# có \ hay chỉ `C:` thì không kết luận: coi như có. Hệ nào bỏ `..` theo
# chữ (/nope/.. vào được) thì cd ../M sau cd /nope vẫn tới được M: cũng coi như có.
gone() {
  case "$1" in
    *..* | *\\*) return 1 ;;
    /* | [A-Za-z]:/*) [ ! -d "$1" ] && [ ! -d "$1/.." ] ;;
    *) return 1 ;;
  esac
}
# strip_q <từ>: bỏ một " ở đầu, một " ở cuối, rồi một ' ở đầu, một ' ở cuối, như ${d#\"} ${d%\"} ${d#\'} ${d%\'}, kết quả
# trong SQ. Xét ký tự đầu/cuối bằng case rồi mới cắt một ký tự: ${d#\"} trên từ dài mà không khớp chậm bậc hai
# (~180 KB: 2,6 giây cho bốn phép, reviewer PR #70).
strip_q() {
  SQ="$1"
  case "$SQ" in \"*) SQ="${SQ#?}" ;; esac
  case "$SQ" in *\") SQ="${SQ%?}" ;; esac
  case "$SQ" in \'*) SQ="${SQ#?}" ;; esac
  case "$SQ" in *\') SQ="${SQ%?}" ;; esac
}
# resolve_dir <gốc> <đường dẫn>: đường dẫn tuyệt đối giữ nguyên, tương đối thì nối vào gốc. Kết quả trong RD.
resolve_dir() {
  local d="$2"
  # Đường đã đọc theo bash (EN của expand_dir, đối số thứ ba là n) thì không bỏ nháy lần nữa: thư mục tên có nháy kép
  # (`cd "\"main repo\""` tới `"main repo"`) từng bị đọc thành `main repo` (verifier PR #71).
  if [ "${3:-}" != n ]; then
    strip_q "$d"
    d="$SQ"
  fi
  case "$d" in
    . | ./) RD="$1" ;; # cd . ở lại thư mục đó: không nối /. (1500 lần `cd .` thành 1500 thư mục khác chữ, 4.3)
    \~ | \~/*) RD="$HOME${d#\~}" ;;
    /* | [A-Za-z]:*) RD="$d" ;;
    *) RD="$1/$d" ;;
  esac
}
# nb_add: cộng độ dài RD (byte) vào nb (tổng độ dài các đường đã gom); quá BYTE_MAX thì đặt reason, trả 1 để người gọi thôi duyệt.
nb_add() {
  # Cận trên số byte, không phụ thuộc locale: tên toàn ký tự 4 byte có số byte gấp 4 số ký tự (reviewer PR #69), mà
  # LC_ALL=C không giúp được trên Git Bash (Cygwin coi locale C là UTF-8, ${#RD} vẫn đếm ký tự: CI Windows PR #70).
  # Đường có ký tự ngoài ASCII thì tính 4 byte mỗi ký tự (UTF-8 dài nhất).
  local b="${#RD}"
  case "$RD" in
    *[![:ascii:]]*) b=$((4 * b)) ;;
  esac
  nb=$((nb + b))
  # Công ghép (resolve_dir, nối mảng) cũng tính vào ngân sách UQW_MAX, ~2 µs mỗi ký tự với bash 3.2: lệnh gộp nhiều trần
  # (cd nhiều đoạn nháy, nhiều `cd .`, -C đường dài) dưới mọi trần từng mất 6,5 giây (reviewer PR #83). Theo ký tự, không
  # theo cận byte: nhân 4 thì đường tiếng Việt bị hỏi thừa (reviewer PR #84).
  uqw=$((uqw + 2 * ${#RD}))
  if [ "$nb" -gt "$BYTE_MAX" ]; then
    reason="push sau cd qua đường nối dồn quá dài: hơn $BYTE_MAX byte"
    return 1
  fi
  [ "$uqw" -le "$UQW_MAX" ] && return 0
  uqw_reason
  return 1
}
# uqw_reason: lý do khi vượt ngân sách công UQW_MAX, như nhau dù chỗ nào (nb_add hay bước kiểm sau expand_dir) làm vượt
# trước: thứ tự đó tuỳ độ dài các đường, tức tuỳ cwd (CI macOS PR #84). Các đường đã gom quá PART_MAX thành phần thì nói
# thêm (như sau vòng lặp, trên các đường đã bỏ trùng: cl nằm cả trong dl, RD có thể là đường đã gom; reviewer PR #84):
# một lần awk, chỉ khi vượt ngân sách.
uqw_reason() {
  local np
  reason="push sau cd hay git -C qua đường nối dồn quá dài hay quá nhiều đoạn nháy: không đọc hết các thư mục"
  np="$(printf '%s\n' "${dl[@]}" "${cl[@]}" "$RD" | awk '!s[$0]++ { n += gsub("/", "/") } END { print n + 0 }')"
  [ "$np" -gt "$PART_MAX" ] && reason="push sau cd qua đường nối dồn quá dài: hơn $PART_MAX thành phần"
}
# Đối số: trong nháy, hoặc chuỗi không có khoảng trắng. ARG_BS cho \<ký tự> là escape (bash:
# main\ repo); ARG_PS coi \ là ký tự thường (PowerShell: C:\vnstock\; git push). Xét cả hai.
ARG_BS='("[^"]*"|'"'"'[^'"'"']*'"'"'|([^[:space:];&|\\]|\\.)+\\?|\\)'
ARG_PS='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)'
# Từ ghép nhiều đoạn nháy ("a b"/'..', "a b/"x, "x/"\.\.) là một đường với bash. Đọc thành lượt RIÊNG, thêm vào hai
# lượt trên: nháy đóng của một chuỗi đứng trước (echo "cd x"; cd M) làm cách đọc này nuốt cả cd thật phía sau, nên
# không được thay cách đọc cũ.
ARG_BSQ='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|"'"'"'\\]|\\.)+\\?'
ARG_PSQ='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|"'"'"'])+'
# Lượt từ ghép thứ ba: trong nháy kép của bash, \" không đóng nháy (`cd "\"main repo\""` tới thư mục `"main repo"`). Lượt
# RIÊNG, không thay ARG_BSQ: nháy kép đứng trong nháy đơn (`echo 'cd "x\"'; cd M`) thì cách đọc này nuốt cd thật phía sau,
# còn ARG_BSQ đóng nháy ở `\"` nên vẫn bắt (reviewer PR #73). Chỉ chạy trên dạng có `\"`.
ARG_BSQE='("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|"'"'"'\\]|\\.)+\\?'

# last_arg <đoạn khớp> <regex đối số>: đối số cuối của đoạn, bỏ tiền tố -Path:, --git-dir=, GIT_DIR=... Kết quả trong LA.
last_arg() {
  local t="" re="$2"
  [[ $1 =~ ($re)$ ]] && t="${BASH_REMATCH[1]}"
  shopt -s nocasematch
  [[ $t =~ ^(-(literal)?path:|--chdir=|--git-dir=|--work-tree=|git_dir=|git_work_tree=)(.+)$ ]] && t="${BASH_REMATCH[3]}"
  shopt -u nocasematch
  LA="$t"
}


# expand_dir <đích> <bash|ps>: bỏ nháy, thay $HOME, $PWD, $CLAUDE_PROJECT_DIR, $env:USERPROFILE, %USERPROFILE%.
# Còn biến, lệnh lồng hay %VAR% thì không biết thư mục: trả mã 1. EO: đường theo cách cũ (chỉ bỏ nháy hai đầu,
# `\ ` là dấu cách); EN: đường đọc theo unquote_word, rỗng khi từ không đọc được (nháy lẻ). Cả hai đều được xét.
expand_dir() {
  local d="$1" rc
  EN=""
  # Công ước lượng (xem UQW_MAX): mỗi lần đọc tốn theo độ dài từ, unquote_word thêm mỗi đoạn một lần chép phần còn lại.
  uqw=$((uqw + 12 * ${#1}))
  strip_q "$d"
  d="$SQ"
  # `\ ` thành dấu cách. ${d//\\ / } trên từ dài chậm bậc hai trở lên với bash 3.2 (4000 `a\ b/..`, 28 KB: ~22 giây ở
  # UTF-8, reviewer PR #69): từ dài thì thay bằng awk (một fork, tuyến tính). RS là \001 để giữ nguyên xuống dòng, chữ x
  # cuối để $(...) không bỏ xuống dòng cuối; từ có \001 thì vẫn thay bằng bash.
  if [ "$tool" != PowerShell ]; then
    case "$d" in
      *'\ '*)
        if [ "${#d}" -gt 1024 ] && case "$d" in *$'\001'*) false ;; *) true ;; esac; then
          d="$(printf '%s' "$d" | LC_ALL=C awk 'BEGIN { RS = "\001" } { gsub(/\\ /, " "); printf "%s", $0 }'; printf x)"
          d="${d%x}"
        else
          d="${d//\\ / }"
        fi
        ;;
    esac
  fi
  subst_dir "$d" || return 1
  EO="$SD"
  # Đường quá PATH_MAX (4096) không cd được: khỏi đọc thêm (mỗi đoạn một lần chép phần còn lại của từ).
  [ "${#1}" -le 4096 ] || return 0
  unquote_word "$1" "$2"
  rc=$?
  uqw=$((uqw + UQN * (${#1} + 64) / 2))
  [ "$rc" = 1 ] && return 1
  if [ "$rc" = 0 ]; then
    subst_dir "$UQ" || return 1
    EN="$SD"
  fi
  return 0
}

# subst_dir <đường>: thay biến đã biết ở đầu đường (xem expand_dir), kết quả trong SD; còn biến thì trả 1.
subst_dir() {
  local d="$1"
  d="${d/#\$HOME/$HOME}"
  d="${d/#\$\{HOME\}/$HOME}"
  d="${d/#\$PWD/${cwd:-.}}"
  d="${d/#\$\{PWD\}/${cwd:-.}}"
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && d="${d/#\$CLAUDE_PROJECT_DIR/$CLAUDE_PROJECT_DIR}"
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && d="${d/#\$\{CLAUDE_PROJECT_DIR\}/$CLAUDE_PROJECT_DIR}"
  d="${d/#%USERPROFILE%/${USERPROFILE:-$HOME}}"
  shopt -s nocasematch
  [[ $d =~ ^\$\{?env:(userprofile|home)\}?(.*)$ ]] && d="${USERPROFILE:-$HOME}${BASH_REMATCH[2]}"
  shopt -u nocasematch
  case "$d" in *'$'* | *'`'* | *%*%*) return 1 ;; esac
  SD="$d"
}

# Push khi có dính tới nhánh chính thì hỏi. Không đoán refspec hay lệnh nào chạy ở đâu (redirect,
# option, đường dẫn chứa chữ git/push, nhiều lệnh push, popd... đều làm việc đoán sai), mà gom
# MỌI thư mục lệnh có thể chạm tới: thư mục của phiên, đích của mọi cd/pushd/Set-Location (nối
# tiếp nhau), đích của mọi -C, --git-dir, --work-tree, GIT_DIR= (tính từ từng thư mục trên).
# Có một thư mục ở nhánh chính là hỏi; đích là biến hay lệnh lồng (không biết trước) cũng hỏi.
# LC_ALL=C như rule(): cmd gồm các dạng bỏ nháy, mà grep -Ei ở locale UTF-8 chậm bậc hai trên dòng dài có nhiều chữ git
# (`g\it -x` ×6000 thành `git -x git -x …` mất 11 giây). Mẫu là ASCII, dạng đã đổi Unicode sang ASCII nằm trong cmd.
if [ -z "$reason" ] && { LC_ALL=C text_grep "$cmd" -Eiq -- "${G}push" ||
  { [ -n "$shc_unknown" ] && LC_ALL=C text_grep "$cmd" -iq -- push; }; }; then
  base="${cwd:-.}"
  # Lệnh push quá dài thì hỏi ngay, khỏi gom thư mục: mọi bước đã tuyến tính (PR #68–#71) nhưng lệnh ~490 KB vẫn mất
  # ~14 giây với bash 3.2 ở UTF-8 (reviewer PR #71), quá timeout thì push chạy không hỏi. Lệnh push thật không dài
  # tới vậy; các ca ~190 KiB của test-hooks vẫn đi hết đường phân tích (dưới trần).
  PUSH_CMD_MAX=200000
  # Đo lệnh như nhận (raw): cmd đã nối thêm các dạng đọc khác nên dài gấp mấy lần. Đếm byte (việc phân tích tốn theo
  # byte; reviewer PR #72): ${#raw} đếm ký tự ở UTF-8, nên lệnh có ký tự ngoài ASCII mà cận 4 byte mỗi ký tự vượt trần
  # thì đếm byte thật bằng wc (một pipe, không file tạm).
  if [ "${#raw}" -gt "$PUSH_CMD_MAX" ]; then
    reason="push trong lệnh quá dài: hơn $PUSH_CMD_MAX byte"
  else
    case "$raw" in
      *[![:ascii:]]*)
        if [ $((4 * ${#raw})) -gt "$PUSH_CMD_MAX" ]; then
          rawb="$(printf '%s' "$raw" | LC_ALL=C wc -c)"
          # So bằng [ (nhận dấu cách đầu của BSD wc), không bằng $((...)): output lạ (số kèm \r của wc.exe) làm
          # $((...)) lỗi cú pháp và bash bỏ cả khối cổng push (reviewer PR #72). [ lỗi thì coi như quá trần.
          [ "$rawb" -le "$PUSH_CMD_MAX" ] 2>/dev/null || reason="push trong lệnh quá dài: hơn $PUSH_CMD_MAX byte"
        fi ;;
    esac
  fi
  # cd của bash (kể cả trong bash -c '...', { }, if/then, có --, -P, -L), Set-Location/
  # Push-Location của PowerShell (kể cả -Path x, -Path:x, -PassThru).
  CDS='(cd|chdir|pushd|sl|set-location|push-location)'
  CD_MAX=300 # số cd tối đa được đọc trong một cách đọc của lệnh push (4.3)
  # Số lần ghép (git -C × thư mục cd đã gom) tối đa của cả lệnh, và số subshell đọc nhánh tối đa: 299 cd và 250 git -C từng
  # mất 15 giây (bash 3.2 quá 60), mỗi thư mục có `..` tốn tới hai subshell chạy git (reviewer PR #55). Quá thì hỏi.
  GC_MAX=10000
  # Số -C (cả --git-dir, --work-tree…) tối đa được đọc (last_arg + expand_dir) của cả lệnh: GC_MAX chỉ đếm lần ghép, mà mỗi
  # -C tốn một lần đọc dù không ghép, nên `git -C q status; `×5000 rồi push (ngay dưới GC_MAX) mất 7,3 giây với bash 3.2
  # ở UTF-8, Git Bash quá timeout (4.3). Đếm ở mỗi cách đọc (2 lượt với -C không nháy, 4 với -C có nháy, thêm lượt khi
  # lệnh nối dòng hay có \"). Chỉ đếm số -C, không đếm công mỗi -C: đối số nhiều đoạn nháy (`"a"'b'…`) vẫn quá timeout
  # dưới trần (còn lại của 4.3). Không hạ dưới ~2400: 600 `git -C xN/..` sau một cd phải tới được DIR_MAX. Quá thì hỏi.
  GCX_MAX=3000
  # Ngân sách công của mọi lần đọc đường (expand_dir) trong vòng cd và vòng -C: CD_MAX và GCX_MAX đếm số lần, mà một lần
  # đọc từ 60 đoạn nháy tốn ~8 ms với bash 3.2 ở UTF-8 (đường 1 đoạn ~1 ms): 740 `git -C "a"'b'…(60 đoạn)` rồi push từng
  # mất 25 giây, 299 cd như vậy 10,6 giây (reviewer PR #82). Đơn vị xấp xỉ µs với bash 3.2 ở UTF-8 (đo trong guard):
  # 12 mỗi ký tự của từ (last_arg, strip_q, subst_dir, regex), cộng mỗi đoạn (độ dài + 64)/2. Quá ~2 giây thì hỏi. Chỉ
  # tính expand_dir và nb_add (2 mỗi ký tự ghép): trước đó gộp nhiều trần (cd nhiều đoạn, cd ., -C đường dài ghép tới gần
  # BYTE_MAX) dưới mọi trần từng mất 6,5 giây (4.3).
  UQW_MAX=2000000
  # Tổng độ dài các đường gom được: mỗi cd nối vào đường trước (cur), nên chuỗi cd dài nối dồn (3 cd `a/..`×1000 rồi 289
  # `cd ..`) là ~3,5 MB mỗi cách đọc, 13,5 giây với bash ở UTF-8 (verifier PR #68). Quá thì hỏi.
  BYTE_MAX=2000000
  SUB_MAX=64
  PART_MAX=60000 # tổng thành phần (dấu /) của các đường cần cd: 299 `cd ..` từ thư mục sâu 8 là ~46000
  DIR_MAX=512 # số đường (chưa bỏ trùng thư mục thật) tối đa được cd để đọc lại: mỗi cd là một lần stat trên Git Bash
  # Trước cd: dấu tách, từ khoá (cả time, !, while/until, elif, eval) và phép gán đứng trước lệnh (x=1 cd M).
  # CDCUT cắt phần trước cd của mỗi kết quả grep, tuyến tính: last_arg chạy regex ($re)$ bậc hai theo độ dài từ không có
  # dấu cách, nên phép gán dài trước cd (x=<190 KB> cd M) từng quá timeout (reviewer 4.10). Kết quả bắt đầu bằng N khi cd
  # chỉ khớp nhờ tiền tố mới (phép gán, time, !, while, until, elif, eval), O khi không.
  CDCUT='{ s = $0; n = length(s); p = 1; nw = 0
    while (p <= n) {
      c = substr(s, p, 1)
      if (index(";&|(`\"\047{$ \t", c)) { p++; continue }
      q = p
      while (q <= n && (c = substr(s, q, 1)) != " " && c != "\t") q++
      t = tolower(substr(s, p, q - p))
      if (t ~ /^(then|do|else|if|builtin|command|exec)$/) { p = q; continue }
      if (t ~ /^(elif|while|until|time|eval|!)$/ || t ~ /^[a-z_][a-z0-9_]*=/) { nw = 1; p = q; continue }
      break
    }
    print (nw ? "N" : "O") substr(s, p) }'
  CDA='(^|[;&|(`"'"'"'{]|\$\(|(^|[[:space:]])(then|do|else|elif|if|while|until|time|eval|builtin|command|exec|!)[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*'
  # Thư mục gom vào mảng: nối chuỗi chép lại cả chuỗi mỗi lần, bậc hai theo số cd (4.3). Mảng không rỗng (bash < 4.4
  # với set -u báo lỗi khi mở rộng mảng rỗng).
  dl=("$base")
  unknown="$shc_unknown"
  longw=""
  # Thư mục của phiên ở nhánh chính thì hỏi ngay, khỏi duyệt mọi cd: lệnh có rất nhiều cd có thể quá timeout (4.3), và
  # mỗi dạng thêm (nháy xé từ khoá thư mục, thân bash -c) là thêm một lượt duyệt.
  branch="$(CDPATH='' cd -P -- "$base" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  text_grep "$branch" -Eqx -- "$MAIN" && reason="push khi đang ở nhánh $branch"
  # Duyệt dòng trong bộ nhớ (IFS là xuống dòng, set -f để đường dẫn không bị glob), không dùng
  # here-doc, cùng lý do text_grep (lib.sh) tránh <<<: here-doc lớn (và mọi here-doc trên bash
  # < 5.1) đi qua file tạm, đĩa đầy hay TMPDIR không ghi được thì vòng không chạy lần nào và push
  # lọt qua.
  set -f
  IFS="$nl"
  ngc=0
  ngx=0
  uqw=0
  RD="" # uqw_reason đọc RD, có thể trước lần resolve_dir đầu tiên (set -u)
  nb=0
  # Dạng che `\"` trong nháy kép (lex_awk với dm = 1: `\"` thành `\<002>`, đọc nháy như bash): `echo "x\" cd q"; cd M` thì mọi
  # lượt trên dạng gốc đều thấy `cd q"; cd "…` (ARG_BSQ đóng chuỗi ở `\"`, ARG_BSQE bắt đầu khớp ở `"` thứ hai) và nuốt cd
  # thật phía sau (4.3). Thêm cho vòng cd, không thay dạng gốc; chỉ dạng có `\"` trong nháy kép, và chỉ ở lượt ARG_BSQ (dạng che
  # đã đọc nháy như bash). Mỗi dạng che là một lượt grep trên cả lệnh: `echo "\""` trước long-uquote hay long-xassign từng
  # đẩy bash 3.2 quá 10 giây (main ~7, reviewer PR #76), nên dạng dài hơn DQM_MAX mà có `\"` trong nháy kép thì hỏi.
  DQM_MAX=65536
  DQM_CD=32
  nf="${#forms[@]}"
  cforms=("${forms[@]}")
  # Đã chắc hỏi (thư mục của phiên ở main, quá PUSH_CMD_MAX) thì vòng cd không chạy: khỏi dựng dạng che (lệnh ~440 KB có
  # `\"` từng quá 10 giây với bash 3.2, reviewer PR #76 lần 4). Chỉ tính dạng che khi awk thật sự che `\"` trong nháy kép
  # (có \002): lex_awk còn đổi `$` trong nháy đơn, bỏ comment, mà các đổi đó không cần đọc lại.
  stx="$(printf '\002')"
  [ -n "$reason$unknown" ] || case "$cmd" in
    *'\"'*)
      for f in "${forms[@]}"; do
        case "$f" in *'\"'*) ;; *) continue ;; esac
        mf="$(printf '%s\n' "$f" | LC_ALL=C awk "BEGIN { dm = 1 }$lex_awk")"
        case "$mf" in *"$stx"*) ;; *) continue ;; esac
        # Cận byte như nb_add: dạng có ký tự ngoài ASCII giữ locale UTF-8 cho grep (chậm hơn), `ệ`×56000 (56000 ký tự,
        # 168 KB) từng quá 10 giây với bash 3.2 khi trần đếm ký tự (reviewer PR #76 lần 3).
        fl="${#f}"
        case "$f" in *[![:ascii:]]*) fl=$((4 * fl)) ;; esac
        if [ "$fl" -gt "$DQM_MAX" ]; then
          reason="push trong lệnh dài hơn $DQM_MAX byte có \\\" trong nháy kép: không đọc được nháy như bash"
          break
        fi
        # Dạng che trùng nhau (joined và both khi tool là Bash) chỉ đọc một lần.
        dup=""
        for g in "${cforms[@]}"; do [ "$g" = "$mf" ] && { dup=1; break; }; done
        [ -n "$dup" ] || cforms+=("$mf")
      done
      ;;
  esac
  # Locale cho grep của vòng cd theo từng dạng, tính một lần cho mọi lượt. Locale gốc chỉ khi dạng có khoảng trắng Unicode
  # (USP: PowerShell `Set-Location<U+3000>M`) hay ſ, ı (grep -i gập thành s, i: `ſl M`, `Set-Locatıon M`): chỉ ở đó UTF-8
  # khớp khác C. Còn lại locale C (byte ≥ 0x80 vẫn là ký tự không phải khoảng trắng): tiền tố gán biến của CDA bậc hai ở
  # UTF-8, `echo é; ` rồi `x= `×60000 và cd từng mất 14 giây với bash 5 (4.3, reviewer PR #86). Chỉ cần locale gốc khi dạng
  # còn có từ khoá cd (CDS, cả bản viết bằng ſ, ı) theo sau là khoảng trắng hay USP, lọc ở locale C: không có thì grep ở UTF-8
  # cũng không khớp gì, nên thông điệp commit dài có ı hay U+3000 không bị hỏi thừa. Dạng cần locale gốc mà dài hơn CDU_MAX
  # thì hỏi: chi phí bậc hai theo độ dài và theo mật độ ký tự ngoài ASCII, `echo "\"ı" \` ⏎ (`x=` + ı×20 + ` `)×173 rồi cd
  # (4 K ký tự) mất 11,5 giây với bash 3.2, `x='' `×3200 nối dòng (16 K) 12 giây với bash 5. Không ghi đè lý do đã có;
  # locale gốc là C thì grep đã nhanh, khỏi hỏi.
  CDU="$USP|$(printf '\305\277|\304\261')"
  CDK_I="(i|$(printf '\304\261'))"
  CDK_S="(s|$(printf '\305\277'))"
  CDK="(cd|chd${CDK_I}r|pu${CDK_S}hd|${CDK_S}l|${CDK_S}et-locat${CDK_I}on|pu${CDK_S}h-locat${CDK_I}on)([[:space:]]|$USP)"
  CDU_MAX=1024
  flc=()
  for f in "${cforms[@]}"; do
    GL=C
    if LC_ALL=C text_grep "$f" -Eq -- "$CDU" && LC_ALL=C text_grep "$f" -Eiq -- "$CDK"; then
      case "$LC0" in
        C | POSIX) ;;
        *)
          if [ "${#f}" -le "$CDU_MAX" ]; then
            GL="$LC0"
          elif [ -z "$reason" ]; then
            reason="push sau cd trong lệnh dài hơn $CDU_MAX ký tự có ſ, ı hay khoảng trắng Unicode: không kịp đọc thư mục"
          fi
          ;;
      esac
    fi
    flc+=("$GL")
  done
  for a in "$ARG_BS" "$ARG_PS" "$ARG_BSQ" "$ARG_PSQ" "$ARG_BSQE"; do
    # Đã hỏi chắc (thư mục của phiên ở nhánh chính, hay thư mục chưa biết): khỏi duyệt cd.
    [ -n "$reason$unknown" ] && break
    um="bash"
    q=""
    [ "$a" = "$ARG_PS" ] && um="ps"
    [ "$a" = "$ARG_BSQ" ] && q=1
    [ "$a" = "$ARG_PSQ" ] && um="ps" && q=1
    [ "$a" = "$ARG_BSQE" ] && q=e
    CDRE="${CDS}((${S}+(--|-p|-l|-e|-@|-passthru))*)(${S}+-(literal)?path(:|${S}+)|${S}+)${a}"
    # Thư mục git chạy trong đó mà không cần cd.
    GDRE="(^|[[:space:];&|(])(-C${S}+|--chdir(=|${S}+)|--git-dir(=|${S}+)|--work-tree(=|${S}+)|GIT_DIR=|GIT_WORK_TREE=)${a}"
    for fx in "${!cforms[@]}"; do
      f="${cforms[$fx]}"
      [ "$fx" -ge "$nf" ] && [ "$a" != "$ARG_BSQ" ] && continue
      # Không có nháy hay \ thì lượt từ ghép khớp đúng như lượt cũ: khỏi chạy lại (chuỗi dirs dài bậc hai theo số cd).
      if [ -n "$q" ]; then
        case "$f" in *[\"\'\\]*) ;; *) continue ;; esac
      fi
      if [ "$q" = e ]; then
        case "$f" in *'\"'*) ;; *) continue ;; esac
      fi
      cur="$base"
      cl=("$base")
      ncd=0
      # Locale theo flc (ở trên): tiền tố gán biến của CDA (`x= `×66000) bậc hai ở locale UTF-8. Dạng có khoảng trắng Unicode
      # hay ſ, ı giữ locale gốc: dạng đổi sang ASCII (un) đổi cả chữ trong tên thư mục (en dash, nháy cong), nên dạng gốc vẫn
      # phải khớp `Set-Location<U+3000>'proj–x'` hay `ſl 'proj–x'` (reviewer PR #74).
      for m in $(printf '%s' "$f" | LC_ALL="${flc[$fx]}" grep -Eio -- "${CDA}${CDRE}" | LC_ALL=C awk "$CDCUT"); do
        # Mỗi cd tốn một lượt thông dịch bash (không fork), Git Bash chậm gấp đôi Linux: 1500 cd từng mất ~7 giây trên runner
        # Windows, 6000 quá timeout trên Linux (4.3). Quá CD_MAX cd thì thôi đọc và hỏi: lệnh thật ít khi cd nhiều như vậy.
        ncd=$((ncd + 1))
        if [ "$ncd" -gt "$CD_MAX" ]; then
          reason="push sau hơn $CD_MAX lần cd: không đọc hết các thư mục"
          break 2
        fi
        # Lượt che (dạng che `\"` ở ARG_BSQ) là lượt thêm so với main, tốn theo số cd chứ không theo byte: 230 cd nhiều đoạn
        # nháy sau `echo "\""` (43 KB) từng quá 10 giây với bash 3.2 (main ~7,8, reviewer PR #76 lần 5). Trần riêng, quá thì hỏi.
        if [ "$fx" -ge "$nf" ] && [ "$ncd" -gt "$DQM_CD" ]; then
          reason="push sau hơn $DQM_CD lần cd trong lệnh có \\\" trong nháy kép: không đọc hết các thư mục"
          break 2
        fi
        nw=""
        case "$m" in N*) nw=1 ;; esac
        m="${m#?}"
        [ -n "$m" ] || continue
        last_arg "$m" "$a"
        # Lượt từ ghép: từ quá PATH_MAX (4096) thì không đọc (trước mọi phép cắt chuỗi, bậc hai theo độ dài) mà hỏi: cd -L
        # rút `..` theo chữ trước khi chdir nên bash vẫn tới được (`cd "a b"/../`×700 rồi `main\ repo`, 4.3 (2)).
        [ -n "$q" ] && [ "${#LA}" -gt 4096 ] && { longw=1; continue; }
        # Đã unknown thì chắc hỏi: thôi đọc. continue thì từ hơn 64 đoạn (unquote_word trả 1 ở đoạn 65, lần đọc đắt nhất)
        # bỏ qua ngân sách bên dưới: 740 `git -C ("a"'b')×33` rồi push từng mất 10,9 giây với bash 3.2 (reviewer PR #83).
        expand_dir "$LA" "$um" || { unknown=1; break 2; }
        if [ "$uqw" -gt "$UQW_MAX" ]; then
          uqw_reason
          break 2
        fi
        # Lượt ARG_BS/ARG_PS nối cd sau theo cách đọc cũ (gom đúng các thư mục như trước) và xét thêm cách mới; lượt từ
        # ghép thì ngược lại.
        t="$EO"
        x="$EN"
        tn=""
        xn=n
        [ -n "$q" ] && [ -n "$EN" ] && t="$EN" && x="$EO" && tn=n && xn=""
        if [ -n "$x" ] && [ "$x" != "$t" ]; then
          resolve_dir "$cur" "$x" "$xn"
          nb_add || break 2
          gone "$RD" || dl+=("$RD")
        fi
        resolve_dir "$cur" "$t" "$tn"
        nb_add || break 2
        # cd chỉ khớp nhờ tiền tố mới (time, x=1, ...) có thể là chữ trong chuỗi (echo "x=1 cd W"): chỉ thêm thư mục,
        # không đổi chỗ đứng cho các cd sau, nên cd thật phía sau vẫn được đọc như trước (reviewer 4.10).
        if [ -n "$nw" ]; then
          gone "$RD" || dl+=("$RD")
          continue
        fi
        # cd tới thư mục không có thì lỗi và shell ở lại chỗ cũ, như bash: không nối các cd sau vào nó (đường dài dần,
        # bậc hai theo số cd, 4.3), và `cd nope; cd sub` được đọc đúng là <chỗ cũ>/sub. Thư mục lệnh tạo trước khi cd
        # (mkdir a && cd a && cd ../m) thì lúc hook chạy cd -L/-P qua nó cũng lỗi, nên nối vào cũng không hỏi thêm được.
        gone "$RD" && continue
        cur="$RD"
        cl+=("$cur")
      done
      dl+=("${cl[@]}")
      # Dạng che không giúp vòng -C (GDRE nhận -C sau mọi khoảng trắng, `echo "x\" -C q"` vẫn nuốt), mà tiêu chung GC_MAX:
      # `git -C . status; `×1800 sau `echo "\""` từng hỏi thừa sau 9,4 giây (reviewer PR #76 lần 5). Bỏ qua.
      [ "$fx" -ge "$nf" ] && continue
      for m in $(printf '%s' "$f" | grep -Eo -- "$GDRE"); do
        [ -n "$m" ] || continue
        ngx=$((ngx + 1))
        if [ "$ngx" -gt "$GCX_MAX" ]; then
          reason="push sau quá nhiều git -C: không đọc hết các thư mục"
          break 3
        fi
        last_arg "$m" "$a"
        [ -n "$q" ] && [ "${#LA}" -gt 4096 ] && { longw=1; continue; }
        expand_dir "$LA" "$um" || { unknown=1; break 3; }
        if [ "$uqw" -gt "$UQW_MAX" ]; then
          uqw_reason
          break 3
        fi
        for c in "${cl[@]}"; do
          [ -n "$c" ] || continue
          ngc=$((ngc + 1))
          if [ "$ngc" -gt "$GC_MAX" ]; then
            reason="push sau quá nhiều git -C và cd: không đọc hết các thư mục"
            break 4
          fi
          resolve_dir "$c" "$EO"
          nb_add || break 4
          dl+=("$RD")
          # EN trùng chữ EO vẫn phải đọc khi EO có nháy hay \: resolve_dir ở trên bỏ nháy EO lần nữa (`git -C '"main repo"'`
          # cho EO = EN = `"main repo"`, dòng trên đọc thành `main repo`; reviewer PR #73).
          xq=""
          case "$EO" in *[\"\'\\]*) xq=1 ;; esac
          if [ -n "$EN" ] && { [ "$EN" != "$EO" ] || [ -n "$xq" ]; }; then
            # Lần đọc thêm cũng tính vào GC_MAX: bash 3.2 nối mảng bậc hai, `git -C '"q"' status; `×8200 từng mất ~12,7 giây.
            ngc=$((ngc + 1))
            if [ "$ngc" -gt "$GC_MAX" ]; then
              reason="push sau quá nhiều git -C và cd: không đọc hết các thư mục"
              break 4
            fi
            resolve_dir "$c" "$EN" n
            nb_add || break 4
            dl+=("$RD")
          fi
        done
      done
    done
  done
  dirs="$(printf '%s\n' "${dl[@]}" | awk '!s[$0]++')"
  [ -n "$unknown" ] && reason="push vào thư mục chưa biết trước (biến hoặc lệnh lồng)"
  [ -n "$longw" ] && [ -z "$reason" ] && reason="push sau cd qua từ có nháy hay dấu thoát dài hơn 4096 ký tự: không đọc được thư mục"
  # Đọc nhánh theo thư mục THẬT, không theo cách viết: 299 `cd ..` là 299 đường khác chữ mà chỉ vài thư mục thật, mỗi đường
  # có `..` từng tốn hai subshell chạy git (tới SUB_MAX: ~10 giây trên Git Bash, ca long-manydotdot đỏ chập chờn). Một
  # subshell cd lần lượt tới mọi đường (builtin, không fork) theo cả hai cách: -P (vật lý, như git -C) và -L (logic, như cd
  # của shell; chỉ khác -P khi đường có .. đi lùi ra từ một symlink), in pwd -P, bỏ trùng; rồi mới chạy git, mỗi thư mục
  # thật một lần (git chạy ở đó thấy đúng repo như sau cd). Thư mục `gone` (cd tới đó lỗi) không tính, không cd.
  # Mỗi thành phần của đường là một lần stat khi cd (-P và -L), đường nối dồn (`cd a/..` dài rồi 289 `cd ..`) thành hàng
  # triệu thành phần: quá timeout (reviewer PR #68). Đếm `/` của mọi đường bằng một lần awk (tuyến tính), quá thì hỏi;
  # đếm trước vòng gone bên dưới (vòng đó cũng tuyến tính theo độ dài các đường).
  if [ -z "$reason" ] && [ -n "$dirs" ]; then
    np="$(printf '%s\n' "$dirs" | awk '{ n += gsub("/", "/") } END { print n + 0 }')"
    [ "$np" -gt "$PART_MAX" ] && reason="push sau cd qua đường quá dài: hơn $PART_MAX thành phần"
  fi
  nd=0
  [ -n "$reason" ] || for d in $dirs; do
    [ -n "$d" ] || continue # cd "" ở lại thư mục của chính hook, không phải của lệnh
    gone "$d" || nd=$((nd + 1))
  done
  if [ -z "$reason" ] && [ "$nd" -gt "$DIR_MAX" ]; then
    reason="push sau quá nhiều thư mục cần đọc nhánh: hơn $DIR_MAX đường"
  fi
  phys=""
  if [ -z "$reason" ] && [ "$nd" -gt 0 ]; then
    # Mỗi đường tính từ chỗ đứng của hook: cd về đó sau mỗi lần; không về được thì in dòng không bắt đầu bằng / và thôi.
    phys="$(here="$PWD"
      for d in $dirs; do
        [ -n "$d" ] || continue
        gone "$d" && continue
        for o in -P -L; do
          # Mẫu có `(` mở: bash 3.2 đọc `)` của mẫu case trong $(...) là dấu đóng $(...) (lỗi cú pháp, hook exit 1).
          case "$o:$d" in (-L:*..*) ;; (-L:*) continue ;; esac
          # Đường thật có xuống dòng (qua symlink) bị vòng đọc theo dòng cắt đôi (reviewer PR #68): in ? để hỏi. cd -P .
          # đặt PWD thành đường vật lý, không fork như $(pwd -P).
          if CDPATH='' cd "$o" -- "$d" 2>/dev/null && CDPATH='' cd -P . 2>/dev/null; then
            case "$PWD" in (*"$nl"*) echo '?' ;; (*) printf '%s\n' "$PWD" ;; esac
          fi
          CDPATH='' cd -- "$here" 2>/dev/null || { echo '?'; exit 0; }
        done
      done | awk '!s[$0]++')"
  fi
  nsub=0
  for p in $phys; do
    [ -n "$reason" ] && break
    case "$p" in
      /*) ;;
      *) reason="push sau cd mà guard không đọc lại được thư mục"; break ;;
    esac
    nsub=$((nsub + 1))
    if [ "$nsub" -gt "$SUB_MAX" ]; then
      reason="push sau quá nhiều thư mục cần đọc nhánh: hơn $SUB_MAX lần"
      break
    fi
    # cd (trong $(...)) rồi mới gọi git, không dùng git -C: Git Bash không đổi đường /c/... có [ ] sang
    # đường Windows cho git.exe, git -C báo lỗi, không đọc được nhánh và push lọt qua.
    branch="$(CDPATH='' cd -P -- "$p" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if text_grep "$branch" -Eqx -- "$MAIN"; then
      reason="push khi đang ở nhánh $branch"
      break
    fi
  done
  IFS=$' \t\n'
  set +f
fi

if [ -n "$reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Hành động không đảo ngược được (%s). Cần người xác nhận, xem mục Quyền tự chủ trong CLAUDE.md."}}\n' "$reason"
fi
exit 0
