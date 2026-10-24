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
cwd="$(json_get "$input" cwd)"
cmd="$(json_get "$input" tool_input.command)"
# Không đọc được lệnh: so mẫu trên toàn bộ input thô (thà hỏi thừa).
[ -n "$cmd" ] || cmd="$input"
# Nối dòng: bash dùng \ cuối dòng, PowerShell dùng `. Ở tool kia, ký tự đó cuối dòng là thứ
# khác (C:\ trong PowerShell, dấu đóng `...` trong bash), còn \\ là dấu \ thật. grep so từng
# dòng, nên so trên nhiều dạng: nối theo tool (đích nằm ở dòng sau), giữ dòng nhưng bỏ dấu
# nối (lệnh ở dòng sau vẫn là đầu lệnh), nối cả hai kiểu (PowerShell lồng trong bash). Không
# rõ tool thì so thêm bản gốc. Kiểm tra push trên nhánh chính đọc từng dạng riêng ($forms).
nl=$'\n'
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
  if [ "$2" = ps ]; then re_pl='^([^"'"'"']+)(.*)$'; else re_pl='^([^"'"'"'\\]+)(.*)$'; fi
  while [ -n "$w" ]; do
    n=$((n + 1))
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
SHC='(^|[;&|(`{[:space:]"'"'"'/])(ba|da|z|k)?sh([[:space:]]+([-+]o[[:space:]]+[A-Za-z]+|--[A-Za-z-]+|-[A-Za-z]+))*[[:space:]]+-[A-Za-z]*c[A-Za-z]*([[:space:]]+--)?[[:space:]]+'
SHW='('"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*"|[^[:space:];&|"'"'"'\\]|\\.)+'
shc_unknown=""
decode_shell_c() {
  local i=0 m w budget=8192 count=0
  set -f
  IFS="$nl"
  while [ "$i" -lt "${#forms[@]}" ] && [ "${#forms[@]}" -lt 16 ]; do
    for m in $(printf '%s' "${forms[$i]}" | grep -Eo -- "$SHC$SHW"); do
      [[ $m =~ ($SHW)$ ]] || continue
      w="${BASH_REMATCH[1]}"
      # Chỉ cổng push cần đọc thân: thân không có chữ p, u, s, h theo thứ tự thì khỏi bỏ nháy (Git Bash chậm hơn Linux
      # nhiều lần). Không đòi bốn chữ liền nhau: nháy có thể xé đôi chữ (pu'\''sh'\'').
      case "$w" in *[Pp]*[Uu]*[Ss]*[Hh]*) ;; *) continue ;; esac
      budget=$((budget - ${#w}))
      count=$((count + 1))
      [ "$budget" -ge 0 ] && [ "$count" -le 256 ] || { shc_unknown=1; break 2; }
      [ "${#w}" -le 16384 ] || { shc_unknown=1; continue; }
      unquote_word "$w" bash 256
      case $? in
        0) [ "${#forms[@]}" -lt 16 ] && forms+=("$UQ") && cmd="$cmd$nl$UQ" ;;
        1) shc_unknown=1 ;;
      esac
    done
    i=$((i + 1))
  done
  IFS=$' \t\n'
  set +f
}

decode_shell_c

# Chữ lệnh bị nháy hay \ xé đôi (`git pu'sh'`, `r'm' -rf /`, `--for"ce"`, `--ha''rd`): bash bỏ nháy giữa từ rồi chạy y như
# bản không nháy, còn mọi luật so trên chữ liền nhau. So thêm một dạng (mọi luật và cổng push) đã bỏ nháy quanh đoạn không
# có khoảng trắng và \ trước chữ cái; đoạn nháy có khoảng trắng giữ nguyên để đường "a b" của -C hay cd không bị tách. Dạng
# này chỉ thêm chữ để khớp và thêm thư mục để xét: hỏi thừa (echo 'pu'sh) chứ không bỏ sót. sed chạy tuyến tính, không dùng
# ${x//a/b} (xem join_lines). Cổng push chỉ đọc thêm dạng này khi nháy chạm tới từ khoá thư mục (c'd', -'C'): mỗi dạng thêm
# một lượt cho mọi cd, 200 `cd "a b"'x'` từ 0,6 lên 1,1 giây (4.3).
dq=""
case "$cmd" in
  *[\"\'\\]*)
    dq="$(printf '%s\n' "$cmd" | LC_ALL=C sed -e "s/'\\([^'[:space:]]*\\)'/\\1/g" -e 's/"\([^"[:space:]]*\)"/\1/g' \
      -e 's/\\\([A-Za-z]\)/\1/g')"
    if [ "$dq" != "$cmd" ]; then
      KW='(cd|chdir|pushd|sl|set-location|push-location|-C|--chdir|--git-dir|--work-tree|git_dir|git_work_tree)'
      KW="(^|[^[:alnum:]_-])$KW([^[:alnum:]_-]|\$)"
      [ "$(printf '%s\n' "$cmd" | grep -Eio -- "$KW")" = "$(printf '%s\n' "$dq" | grep -Eio -- "$KW")" ] || forms+=("$dq")
      cmd="$cmd$nl$dq"
    fi
    ;;
esac

reason=""
rule() {
  if [ -z "$reason" ] && text_grep "$cmd" -Eiq -- "$1"; then
    reason="$2"
  fi
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
QW='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"'\\]|\\.)'
OA='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^-[:space:]"'"'"'][^[:space:]]*|([^-[:space:]"'"'"'\\]|\\.)([^[:space:]\\]|\\.)*\\?)'
OQ='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^-[:space:]"'"'"'\\]|\\.)'"$QW"'*\\?'
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

# Các hàm dưới ghi kết quả vào biến (RD, LA, UQ, EN, EO, SD) thay vì in ra: gọi qua $(...) là một lần fork cho mỗi
# cd ở mỗi cách đọc (4.3).
# resolve_dir <gốc> <đường dẫn>: đường dẫn tuyệt đối giữ nguyên, tương đối thì nối vào gốc. Kết quả trong RD.
resolve_dir() {
  local d="$2"
  d="${d#\"}"; d="${d%\"}"; d="${d#\'}"; d="${d%\'}"
  case "$d" in
    . | ./) RD="$1" ;; # cd . ở lại thư mục đó: không nối /. (1500 lần `cd .` thành 1500 thư mục khác chữ, 4.3)
    \~ | \~/*) RD="$HOME${d#\~}" ;;
    /* | [A-Za-z]:*) RD="$d" ;;
    *) RD="$1/$d" ;;
  esac
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
  d="${d#\"}"; d="${d%\"}"; d="${d#\'}"; d="${d%\'}"
  [ "$tool" = PowerShell ] || d="${d//\\ / }"
  subst_dir "$d" || return 1
  EO="$SD"
  # Đường quá PATH_MAX (4096) không cd được: khỏi đọc thêm (mỗi đoạn một lần chép phần còn lại của từ).
  [ "${#1}" -le 4096 ] || return 0
  unquote_word "$1" "$2"
  rc=$?
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
if [ -z "$reason" ] && { text_grep "$cmd" -Eiq -- "${G}push" || { [ -n "$shc_unknown" ] && text_grep "$cmd" -iq -- push; }; }; then
  base="${cwd:-.}"
  # cd của bash (kể cả trong bash -c '...', { }, if/then, có --, -P, -L), Set-Location/
  # Push-Location của PowerShell (kể cả -Path x, -Path:x, -PassThru).
  CDS='(cd|chdir|pushd|sl|set-location|push-location)'
  CDA='(^|[;&|(`"'"'"'{]|\$\(|(^|[[:space:]])(then|do|else|if|builtin|command|exec)[[:space:]])[[:space:]]*'
  # Thư mục gom vào mảng: nối chuỗi chép lại cả chuỗi mỗi lần, bậc hai theo số cd (4.3). Mảng không rỗng (bash < 4.4
  # với set -u báo lỗi khi mở rộng mảng rỗng).
  dl=("$base")
  unknown="$shc_unknown"
  # Duyệt dòng trong bộ nhớ (IFS là xuống dòng, set -f để đường dẫn không bị glob), không dùng
  # here-doc, cùng lý do text_grep (lib.sh) tránh <<<: here-doc lớn (và mọi here-doc trên bash
  # < 5.1) đi qua file tạm, đĩa đầy hay TMPDIR không ghi được thì vòng không chạy lần nào và push
  # lọt qua.
  set -f
  IFS="$nl"
  for a in "$ARG_BS" "$ARG_PS" "$ARG_BSQ" "$ARG_PSQ"; do
    um="bash"
    q=""
    [ "$a" = "$ARG_PS" ] && um="ps"
    [ "$a" = "$ARG_BSQ" ] && q=1
    [ "$a" = "$ARG_PSQ" ] && um="ps" && q=1
    CDRE="${CDS}((${S}+(--|-p|-l|-passthru))*)(${S}+-(literal)?path(:|${S}+)|${S}+)${a}"
    # Thư mục git chạy trong đó mà không cần cd.
    GDRE="(^|[[:space:];&|(])(-C${S}+|--chdir(=|${S}+)|--git-dir(=|${S}+)|--work-tree(=|${S}+)|GIT_DIR=|GIT_WORK_TREE=)${a}"
    for f in "${forms[@]}"; do
      # Không có nháy hay \ thì lượt từ ghép khớp đúng như lượt cũ: khỏi chạy lại (chuỗi dirs dài bậc hai theo số cd).
      if [ -n "$q" ]; then
        case "$f" in *[\"\'\\]*) ;; *) continue ;; esac
      fi
      cur="$base"
      cl=("$base")
      for m in $(printf '%s' "$f" | grep -Eio -- "${CDA}${CDRE}"); do
        [ -n "$m" ] || continue
        last_arg "$m" "$a"
        # Lượt từ ghép chỉ thêm thư mục: từ quá PATH_MAX (4096) thì bỏ, trước mọi phép cắt chuỗi (bậc hai theo độ dài).
        [ -n "$q" ] && [ "${#LA}" -gt 4096 ] && continue
        expand_dir "$LA" "$um" || { unknown=1; continue; }
        # Lượt ARG_BS/ARG_PS nối cd sau theo cách đọc cũ (gom đúng các thư mục như trước) và xét thêm cách mới; lượt từ
        # ghép thì ngược lại.
        t="$EO"
        x="$EN"
        [ -n "$q" ] && [ -n "$EN" ] && t="$EN" && x="$EO"
        if [ -n "$x" ] && [ "$x" != "$t" ]; then
          resolve_dir "$cur" "$x"
          dl+=("$RD")
        fi
        resolve_dir "$cur" "$t"
        cur="$RD"
        cl+=("$cur")
      done
      dl+=("${cl[@]}")
      for m in $(printf '%s' "$f" | grep -Eo -- "$GDRE"); do
        [ -n "$m" ] || continue
        last_arg "$m" "$a"
        [ -n "$q" ] && [ "${#LA}" -gt 4096 ] && continue
        expand_dir "$LA" "$um" || { unknown=1; continue; }
        for c in "${cl[@]}"; do
          [ -n "$c" ] || continue
          resolve_dir "$c" "$EO"
          dl+=("$RD")
          if [ -n "$EN" ] && [ "$EN" != "$EO" ]; then
            resolve_dir "$c" "$EN"
            dl+=("$RD")
          fi
        done
      done
    done
  done
  dirs="$(printf '%s\n' "${dl[@]}" | awk '!s[$0]++')"
  [ -n "$unknown" ] && reason="push vào thư mục chưa biết trước (biến hoặc lệnh lồng)"
  for d in $dirs; do
    [ -n "$d" ] || continue # cd "" ở lại thư mục của chính hook, không phải của lệnh
    # cd (trong $(...)) rồi mới gọi git, không dùng git -C: Git Bash không đổi đường /c/... có [ ] sang
    # đường Windows cho git.exe, git -C báo lỗi, không đọc được nhánh và push lọt qua. Đọc theo cả hai
    # cách đi đường: -P (vật lý, như git -C) và -L (logic, như cd của shell). Hai cách chỉ khác nhau
    # khi đường có .. đi lùi ra từ một symlink; cách nào ở nhánh chính cũng hỏi.
    for o in -P -L; do
      case "$o:$d" in -L:*..*) ;; -L:*) continue ;; esac
      branch="$(CDPATH='' cd "$o" -- "$d" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
      if text_grep "$branch" -Eqx -- "$MAIN"; then
        reason="push khi đang ở nhánh $branch"
        break 2
      fi
    done
  done
  IFS=$' \t\n'
  set +f
fi

if [ -n "$reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Hành động không đảo ngược được (%s). Cần người xác nhận, xem mục Quyền tự chủ trong CLAUDE.md."}}\n' "$reason"
fi
exit 0
