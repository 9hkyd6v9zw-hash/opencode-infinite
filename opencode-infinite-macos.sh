#!/bin/zsh
# ============================================================
#  OpenCode Infinite for macOS  (macos-1.0.0)
#  Multi-egress (WARP / TOR / free HTTP) + dependency bootstrap
#  + auto-resume, ported from the Windows launcher.
#
#  What it does
#  - Finds opencode (PATH, ~/.opencode/bin, Homebrew, npm) and runs it.
#  - Egress for OpenCode only:
#      [1] WARP   Cloudflare WARP proxy mode on 127.0.0.1:40000
#      [2] TOR    local tor + its own HTTPTunnelPort (no Privoxy)
#      [3] PROXY  free HTTP proxies from the ProxyScrape list
#      [4] NONE   direct
#  - When the free limit stops the chat: new IP, same chat resumed.
#  - IP hunt (country / prefix), optional probe, crash retry.
#  - Renew session, deep reset / restore, settings, themes,
#    languages, update check, support report, commands.
#
#  Nothing here moves, renames or deletes your chats except the
#  Deep reset / Restore option, which asks first and archives first.
#  The proxy applies to the OpenCode process tree only.
#  No sudo, no password prompt, no system proxy changes.
# ============================================================
emulate -L zsh
setopt null_glob

VERSION="macos-1.0.0"
REPO="https://gitlab.com/jekooo/opencode-infinite"
REPO_RAW="$REPO/-/raw/main"

# Homebrew first: the script re-execs children from here.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.opencode/bin:$HOME/.local/bin:$PATH"

STATE_DIR="${OCI_STATE:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode-infinite}"
CONF="$STATE_DIR/config.env"
LOG="$STATE_DIR/launcher.log"
APP_DIR="$STATE_DIR/app"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
BIN_DIR="$HOME/.local/bin"
OC_PIDS="$STATE_DIR/oc.pids"
LIMIT_FLAG="$STATE_DIR/limit.flag"
ASK_FLAG="$STATE_DIR/ask.flag"
ASK_LAST="$STATE_DIR/ask.last"
ROT_LOG="$STATE_DIR/rotations.log"
PATTERNS="$STATE_DIR/patterns.conf"
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
ARGS=("$@")
PROXY_URL=""
mkdir -p "$STATE_DIR" 2>/dev/null

# v1.0: limit lines that rotate, ask first, or never rotate
PAT_ROTATE_DEF='usage limit|out of usage|insufficient credits|payment required|ip (is )?blocked|blocked ip|403.*region|region.*403'
PAT_ASK_DEF='rate limit|rate_limit_exceeded|too many requests|status(Code)?[=: ]*429|HTTP 429'
PAT_NOOP_DEF='compaction|context length exceeded|context_length_exceeded|maximum context|model not found|invalid model|ProviderModelNotFound|content filter|content policy|content_policy'

# ---------------------------------------------------------------- settings table
# name|group|type|default|label|help|options  (enum a,b / num min:max / bool,text,key empty)
SETDEF=(
'OC_EGRESS_DEFAULT|Connection|enum|ASK|Egress|ASK = pick at each start. WARP, TOR, PROXY or NONE = used for OpenCode. System traffic stays direct.|ASK,WARP,TOR,PROXY,NONE'
'OC_MODE_DEFAULT|Connection|enum|CLI|Run mode|CLI = OpenCode in this terminal. DESKTOP = the OpenCode app, restarted on every new IP.|CLI,DESKTOP'
'OC_APP|Connection|text||Desktop app path|Empty = /Applications/OpenCode.app, then OpenCode on the PATH. Type - to clear.|'
'PROXY_PORT|Connection|num|40000|WARP proxy port|Local port of the WARP proxy.|1:65535'
'WARP_WAIT|Connection|num|6|WARP wait (s)|Seconds to wait after (re)connecting WARP.|1:120'
'WARP_CALL_TIMEOUT|Connection|num|15|warp-cli timeout (s)|Seconds a single warp-cli call may take.|5:300'
'TOR_SOCKS_PORT|Tor|num|9050|Tor SOCKS port|SOCKS port of the Tor the launcher starts. A Tor already on this port is reused.|1:65535'
'TOR_HTTP_PORT|Tor|num|8118|Tor HTTP port|HTTPTunnelPort of that Tor. OpenCode speaks HTTP, not SOCKS5.|1:65535'
'TOR_AUTO_INSTALL|Tor|bool|1|Offer to install Tor|Offer brew install tor when it is missing.|'
'TOR_BOOTSTRAP_WAIT|Tor|num|120|Tor bootstrap wait (s)|Seconds to wait for Tor to finish bootstrapping.|30:900'
'PROXY_LIST_URL|Proxy list|text|https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text|Proxy list source|URL or local file, any format. ip:port entries are picked out. Type - to clear.|'
'PROXY_LIST_MIN_BYTES|Proxy list|num|20|Minimum list size (bytes)|A downloaded list smaller than this is rejected. 0 = off.|0:100000000'
'PROXY_TRY_MAX|Proxy list|num|40|Proxies tried per pick|How many proxies to test before giving up.|1:500'
'PROXY_PROBE_TIMEOUT|Proxy list|num|8|Proxy test timeout (s)|Seconds a single proxy test may take.|1:120'
'PROXY_ROT_MAX|Proxy list|num|10|Burned proxies before Tor offer|Burned proxies in one hunt before PROXY mode offers Tor.|1:200'
'PROXY_FIXED|Proxy list|text||Your own proxy|host:port or http://host:port. Empty = use the list. Type - to clear.|'
'AUTO_ROTATE|Rotation|bool|1|Automatic rotation|On: a limit gets a new IP and the chat resumes. Off: the menu decides.|'
'ROTATE_TRIES_MAX|Rotation|num|4|Rotation attempts|Attempts per round when the route is not up.|1:20'
'ROTATE_COOLDOWN|Rotation|num|10|Cooldown between attempts (s)|Seconds between rotation tries. Cloudflare throttles rapid registrations.|0:300'
'IP_FIND_MAX|Rotation|num|0|Burned IPs allowed|IPs the probe may reject before giving up. 0 = no limit.|0:10000'
'TARGET_COUNTRY|Rotation|text||Target country|Keep asking for IPs until one is in this country, e.g. DE. Empty = any. Type - to clear.|'
'TARGET_PREFIX|Rotation|text||Target IP prefix|Keep asking until the IP starts with this, e.g. 104.28. Empty = not used. Type - to clear.|'
'TARGET_TRIES|Rotation|num|5|Max attempts per hunt|New IPs requested in one hunt.|1:100'
'TARGET_MINUTES|Rotation|num|15|Max minutes per hunt|The hunt stops after this many minutes.|1:240'
'TARGET_INTERVAL|Rotation|num|15|Seconds between attempts|Pause between two attempts.|0:300'
'ON_CLOSE|Rotation|enum|ask|After OpenCode closes|ask = R, M or Q. quit = leave the launcher at once.|ask,quit'
'WATCH|Watcher|bool|0|Watch the log|Rotate when a fatal limit line appears while OpenCode runs.|'
'RESUME_MSG|Watcher|text|continue|Resume message|Sent automatically after a rotation.|'
'RESUME_AUTO|Watcher|bool|1|Unattended resume|The resume auto-approves tool permissions (--auto).|'
'RESUME_TIMEOUT|Watcher|num|90|Resume timeout (s)|Seconds before a silent resume counts as a dead IP.|10:900'
'RESUME_IDLE|Watcher|num|60|Resume idle timeout (s)|Kill the resume only after this many seconds with no new output.|10:900'
'RESUME_MODE|Watcher|enum|continue|Resume mode|continue = the resume message. custom = the custom text below.|continue,custom'
'RESUME_TEXT|Watcher|text||Custom resume text|Text sent when the resume mode is custom.|'
'PROBE|Probe|bool|0|Test every new IP|Send one cheap message through each candidate IP. Off by default: each probe uses the free quota.|'
'PROBE_MODEL|Probe|text||Probe model|Model used by the IP probe. Empty = the chat model.|'
'PROBE_BROKEN_MAX|Probe|num|3|Probe failures tolerated|Non-limit probe failures before the hunt stops.|1:50'
'UPDATE_CHECK|Updates|bool|0|Launcher self-update|Check GitLab for a newer launcher at every start. The macOS build is published separately.|'
'UPDATE_ASK|Updates|enum|ask|Update prompts|ask = offer newer versions at start. never = no checks and no prompts.|ask,never'
'OC_API_BASE|Updates|text|https://opencode.ai/update/api/latest|Release metadata URL|Where the newest opencode version is read from.|'
'OCUI_THEME|Appearance|enum|ocean|Color theme|Accent colors of the menus.|ocean,forest,sunset,mono,rainbow'
'OCUI_COLOR|Appearance|enum|auto|Colors|auto follows the terminal and NO_COLOR. on or off forces it.|auto,on,off'
'OCUI_ICONS|Appearance|enum|auto|Borders|auto = UTF-8 borders when the locale is UTF-8. unicode or emoji = UTF-8. ascii = plain.|auto,emoji,unicode,ascii'
'OCUI_LANG|Appearance|enum|auto|Language|Language of the menus. auto follows LANG. Only the chosen file is downloaded.|auto,en,de,es,fr,it,pt,tr,ru'
'KEY_ROTATE|Shortcuts|key|R|Rotate key|Closed-OpenCode prompt: new IP and resume the chat. One letter.|'
'KEY_MENU|Shortcuts|key|M|Menu key|Closed-OpenCode prompt: open the menu. One letter.|'
'KEY_QUIT|Shortcuts|key|Q|Quit key|Closed-OpenCode prompt: quit. Ctrl+C always quits too. One letter.|'
'LOG_ENABLED|Logs|bool|1|Activity log|Record what the launcher does in launcher.log.|'
'LOG_MAX_KB|Logs|num|1024|Log size limit (KB)|The log is cut to its newest part when it grows past this.|64:10240'
'LOG_MASK_IP|Logs|bool|1|Hide IPs in reports|Public IP addresses are masked in the support report.|'
)

SK=(); SG=(); ST=(); SD=(); SL=(); SH=(); SO=()
for row in "${SETDEF[@]}"; do
  k=""; g=""; t=""; d=""; l=""; h=""; o=""
  IFS='|' read -r k g t d l h o <<< "$row"
  SK+=("$k"); SG+=("$g"); ST+=("$t"); SD+=("$d"); SL+=("$l"); SH+=("$h"); SO+=("${o:-}")
done

# ---------------------------------------------------------------- helpers
fsize(){ stat -f%z "$1" 2>/dev/null || print 0; }
fmtime(){ stat -f%m "$1" 2>/dev/null || print 0; }
timeout_cmd(){
  local t=$1; shift
  if have perl; then perl -e 'alarm shift; exec @ARGV' "$t" "$@" 2>/dev/null
  else "$@"; fi
}
now(){ date +%s; }
port_open(){ nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1; }
have(){ command -v "$1" >/dev/null 2>&1; }

log(){
  [[ "$LOG_ENABLED" == 1 ]] || return 0
  print -r -- "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
  local sz; sz=$(fsize "$LOG")
  if (( sz > LOG_MAX_KB * 1024 )); then
    tail -c $(( LOG_MAX_KB * 512 )) "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

cfg_get(){
  local k=$1 d=$2 v=""
  if [[ -f "$CONF" ]] && grep -q "^$k=" "$CONF" 2>/dev/null; then
    v=$(sed -n "s/^$k=//p" "$CONF" | tail -n1)
  else
    v="$d"
  fi
  print -r -- "$v"
}
cfg_set(){
  local k=$1 v=$2
  touch "$CONF"
  { grep -v "^$k=" "$CONF" 2>/dev/null; print -r -- "$k=$v"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

load_cfg(){
  local i k v
  for (( i = 1; i <= ${#SK[@]}; i++ )); do
    k=${SK[i]}
    v=$(cfg_get "$k" "${SD[i]}")
    if [[ ${ST[i]} == num || ${ST[i]} == bool ]]; then
      [[ $v =~ ^[0-9]+$ ]] || v=${SD[i]}
    fi
    typeset -g "$k=$v"
  done
  OC_CMD=$(cfg_get OC_CMD "")
  SETUP_DONE=$(cfg_get SETUP_DONE 0)
  [[ "$OC_EGRESS_DEFAULT" == (ASK|WARP|TOR|PROXY|NONE) ]] || OC_EGRESS_DEFAULT=ASK
  # a live run keeps the egress it picked; only the first load takes the default
  EGRESS=${EGRESS:-$OC_EGRESS_DEFAULT}
  [[ $EGRESS == ASK ]] && EGRESS=NONE
  load_patterns
  load_themes
}

load_patterns(){
  PAT_ROTATE=$PAT_ROTATE_DEF; PAT_ASK=$PAT_ASK_DEF; PAT_NOOP=$PAT_NOOP_DEF
  if [[ -f "$PATTERNS" ]]; then
    local v
    v=$(sed -n 's/^rotate=//p' "$PATTERNS" | tail -n1)
    [[ -n $v ]] && PAT_ROTATE=$v
    v=$(sed -n 's/^ask=//p' "$PATTERNS" | tail -n1)
    [[ -n $v ]] && PAT_ASK=$v
    v=$(sed -n 's/^noop=//p' "$PATTERNS" | tail -n1)
    [[ -n $v ]] && PAT_NOOP=$v
  fi
  OC_PAT="level=ERROR.*($PAT_ROTATE)"
}

# ---------------------------------------------------------------- language
typeset -A TRMAP
tx(){ print -r -- "${TRMAP[$1]:-$1}"; }
load_lang(){
  TRMAP=()
  local code=$OCUI_LANG f k v
  [[ $code == auto ]] && code=${LANG%%[_.@]*}
  case $code in de|es|fr|it|pt|tr|ru|en) ;; *) return 0;; esac
  [[ $code == en ]] && return 0
  have jq || return 0
  f="$STATE_DIR/langs/$code.json"
  if [[ ! -s "$f" ]]; then
    mkdir -p "$STATE_DIR/langs"
    curl -fsSL -m 20 "$REPO_RAW/langs/$code.json" -o "$f.tmp" 2>/dev/null
    [[ -s "$f.tmp" ]] && (( $(fsize "$f.tmp") > 1000 )) && mv "$f.tmp" "$f"
    rm -f "$f.tmp"
  fi
  [[ -s "$f" ]] || return 0
  while IFS=$'\t' read -r k v; do TRMAP["$k"]=$v; done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$f" 2>/dev/null)
}

# ---------------------------------------------------------------- theme and drawing
typeset -A TH
typeset -A THEME_EXTRA
THEMES_VER=1
THEME_BUILTIN="ocean forest sunset mono rainbow"
THEME_SGR_RE='^[0-9;]{1,20}$'

load_themes(){
  local f="$STATE_DIR/themes/themes.txt" n t a b s r cnt=0 names=""
  if [[ ! -s "$f" || "$(cat "$f.ver" 2>/dev/null)" != "$THEMES_VER" ]]; then
    mkdir -p "$STATE_DIR/themes"
    curl -fsSL -m 8 "$REPO_RAW/themes/themes.txt" -o "$f.tmp" 2>/dev/null
    if [[ -s "$f.tmp" ]] && grep -Eq '^[a-z][a-z0-9_-]{1,19}[|][0-9;]{1,20}[|][0-9;]{1,20}[|][0-9;]{1,20}[|][0-9;]{1,20}[|][01][[:space:]]*$' "$f.tmp"; then
      mv "$f.tmp" "$f"; print -r -- "$THEMES_VER" > "$f.ver"; log 'themes downloaded'
    else
      rm -f "$f.tmp"
    fi
  fi
  THEME_EXTRA=()
  if [[ -s "$f" ]]; then
    while IFS='|' read -r n t a b s r; do
      r=${r%$'\r'}
      [[ $n =~ ^[a-z][a-z0-9_-]{1,19}$ ]] || continue
      case " $THEME_BUILTIN " in *" $n "*) continue;; esac
      [[ $t =~ $THEME_SGR_RE && $a =~ $THEME_SGR_RE && $b =~ $THEME_SGR_RE && $s =~ $THEME_SGR_RE && $r =~ ^[01]$ ]] || continue
      THEME_EXTRA[$n]="$t|$a|$b|$s|$r"; names+=" $n"; (( cnt++ ))
      (( cnt >= 30 )) && break
    done < "$f"
  fi
  names=$(print -r -- ${(z)names} | sort | paste -sd, -)
  local i
  for (( i = 1; i <= ${#SK[@]}; i++ )); do
    [[ ${SK[i]} == OCUI_THEME ]] && SO[i]="ocean,forest,sunset,mono,rainbow${names:+,$names}"
  done
}

set_theme(){
  local t a b s r
  OCUI_THEME=$1
  case $OCUI_THEME in
    forest)  TH=(title '1;92' acc '32' border '32' sel '30;42' warn '33' ok '32' err '31' dim '90');;
    sunset)  TH=(title '1;95' acc '35' border '35' sel '30;45' warn '33' ok '32' err '31' dim '90');;
    mono)    TH=(title '1' acc '0' border '0' sel '7' warn '0' ok '0' err '0' dim '2');;
    rainbow) TH=(title 'rain' acc 'rain' border 'rain' sel '' warn '33' ok '32' err '31' dim '90');;
    *)
      if [[ -n ${THEME_EXTRA[$OCUI_THEME]:-} ]]; then
        IFS='|' read -r t a b s r <<< "${THEME_EXTRA[$OCUI_THEME]}"
        TH=(title "$t" acc "$a" border "$b" sel "$s" warn '33' ok '32' err '31' dim '90')
      else
        OCUI_THEME=ocean; TH=(title '1;96' acc '36' border '34' sel '30;46' warn '33' ok '32' err '31' dim '90')
      fi;;
  esac
  RAIN=0
  [[ $OCUI_THEME == rainbow ]] && RAIN=1
  if [[ ${r:-0} == 1 ]]; then
    RAIN=1; TH=(title 'rain' acc 'rain' border 'rain' sel '' warn '33' ok '32' err '31' dim '90')
  fi
  COLOR=1
  [[ -n ${NO_COLOR:-} ]] && COLOR=0
  case $OCUI_COLOR in on) COLOR=1;; off) COLOR=0;; esac
  if [[ $OCUI_ICONS == ascii ]] || { [[ $OCUI_ICONS == auto ]] && [[ ${LANG:-} != *UTF-8* && ${LANG:-} != *utf8* ]]; }; then
    BOX_TL='+'; BOX_TR='+'; BOX_BL='+'; BOX_BR='+'; BOX_H='-'; BOX_V='|'
  else
    BOX_TL='╭'; BOX_TR='╮'; BOX_BL='╰'; BOX_BR='╯'; BOX_H='─'; BOX_V='│'
  fi
}

ESC=$'\e'
hue_rgb(){
  local h=$(( ($1 % 360 + 360) % 360 )) s f q
  s=$(( h / 60 )); f=$(( 255 * (h % 60) / 60 )); q=$(( 255 - f ))
  case $s in
    0) RGB="255;$f;0";; 1) RGB="$q;255;0";; 2) RGB="0;255;$f";;
    3) RGB="0;$q;255";; 4) RGB="$f;0;255";; *) RGB="255;0;$q";;
  esac
}
code_of(){
  case $1 in
    sel) if [[ $RAIN == 1 ]]; then hue_rgb $(( RAIN_PH * 8 + 180 )); CODE="30;48;2;$RGB"; else CODE=${TH[sel]}; fi;;
    border) if [[ $RAIN == 1 ]]; then hue_rgb $(( RAIN_PH * 8 )); CODE="38;2;$RGB"; else CODE=${TH[border]}; fi;;
    *) CODE=${TH[$1]};;
  esac
}
rep(){ printf -v REP "%*s" "$2" ""; REP=${REP// /$1}; }
FRAME=""; RAIN_PH=0
pt(){
  [[ $COLOR != 1 || -z $1 ]] && { FRAME+="$2"; return; }
  if [[ $1 != rain ]]; then FRAME+="$ESC[$1m$2$ESC[0m"; return; fi
  local s=$2 i=0 k ch out=""
  for (( k = 1; k <= ${#s}; k++ )); do
    ch=${s[k]}
    if [[ $ch == ' ' ]]; then out+=" "; continue; fi
    hue_rgb $(( RAIN_PH * 8 + i * 28 )); out+="$ESC[38;2;${RGB}m$ch"; (( i++ ))
  done
  FRAME+="$out$ESC[0m"
}
eol(){ FRAME+="$ESC[K"$'\n'; }
margin(){ FRAME+="$MARG"; }
banner(){
  local art=(
    ' ___   ____   _____  _   _   ____  ___   ____   _____   '
    '/ _ \ |  _ \ | ____|| \ | | / ___|/ _ \ |  _ \ | ____|  '
    '| | | || |_) ||  _|  |  \| || |    | | | || | | ||  _|  '
    '| |_| ||  __/ | |___ | |\  || |___ | |_| || |_| || |___ '
    ' \___/ |_|    |_____||_| \_| \____| \___/ |____/ |_____|'
    ' ___  _   _  _____  ___  _   _  ___  _____  _____       '
    '|_ _|| \ | ||  ___||_ _|| \ | ||_ _||_   _|| ____|      '
    ' | | |  \| || |_    | | |  \| | | |   | |  |  _|        '
    ' | | | |\  ||  _|   | | | |\  | | |   | |  | |___       '
    '|___||_| \_||_|    |___||_| \_||___|  |_|  |_____|      ')
  local r c
  for (( r = 1; r <= ${#art[@]}; r++ )); do
    margin
    if [[ $RAIN == 1 ]]; then c=rain; elif (( r <= 5 )); then c=${TH[title]}; else c=${TH[acc]}; fi
    pt "$c" "${art[r]}"; eol
  done
  margin; pt "${TH[acc]}" "$REPO"; eol; margin; eol
}
boxline(){
  local inner=$(( W - 4 )) text=$2; text=${text[1,inner]}
  code_of border; local bc=$CODE
  margin; pt "$bc" "$BOX_V "; pt "$1" "$(printf "%-*s" "$inner" "$text")"; pt "$bc" " $BOX_V"; eol
}
boxtop(){
  local t=" $1 " fill
  t=${t[1,W-4]}
  fill=$(( W - 3 - ${#t} )); (( fill < 0 )) && fill=0; rep "$BOX_H" "$fill"
  code_of border; local bc=$CODE; code_of title; local tc=$CODE
  margin; pt "$bc" "$BOX_TL$BOX_H"; pt "$tc" "$t"; pt "$bc" "$REP$BOX_TR"; eol
}
boxbot(){ rep "$BOX_H" $(( W - 2 )); code_of border; margin; pt "$CODE" "$BOX_BL$REP$BOX_BR"; eol; }

ML=(); MV=(); MH=(); MD=(); MVS=(); HEAD=()
reset_items(){ ML=(); MV=(); MH=(); MD=(); MVS=(); HEAD=(); }
item(){ ML+=("$1"); MV+=("${2:-}"); MH+=("${3:-}"); MD+=("${4:-}"); MVS+=("${5:-acc}"); }

draw(){
  local title=$1 foot=$2 n=${#ML[@]} i lab val gap room help h
  FRAME=""
  local cols=${COLUMNS:-$(tput cols 2>/dev/null || print 80)}
  W=$(( cols - 2 )); (( W > 74 )) && W=74; (( W < 56 )) && W=56
  local M=$(( (cols - W) / 2 )); (( M < 0 )) && M=0
  printf -v MARG "%*s" "$M" ""
  [[ $SHOW_BANNER == 1 ]] && banner
  for h in "${HEAD[@]}"; do margin; pt "${h%%|*}" "${h#*|}"; eol; done
  (( ${#HEAD[@]} > 0 )) && { margin; eol; }
  boxtop "$title"
  for (( i = 1; i <= n; i++ )); do
    lab=${ML[i]}; val=${MV[i]}
    room=$(( W - 10 - ${#lab} )); (( room < 4 )) && room=4
    (( ${#val} > room )) && val="${val[1,room-2]}.."
    gap=$(( W - 9 - ${#lab} - ${#val} )); (( gap < 1 )) && gap=1
    printf -v gap "%*s" "$gap" ""
    if (( i == SEL )); then
      code_of sel; local sc=$CODE
      code_of border; local bc=$CODE
      margin; pt "$bc" "$BOX_V "; pt "$sc" "> $(( i )). $lab$gap$val"; pt "$bc" " $BOX_V"; eol
    else
      code_of border; local bc=$CODE
      local dc=""; [[ -n ${MD[i]} ]] && dc=${TH[dim]}
      code_of "${MVS[i]}"; local vc=$CODE
      margin; pt "$bc" "$BOX_V   "; pt "$dc" "$i. $lab"; pt "" "$gap"; pt "$vc" "$val"; pt "$bc" " $BOX_V"; eol
    fi
  done
  boxbot
  help="${MH[SEL]}"
  if [[ -n ${MV[SEL]} ]] && (( ${#MV[SEL]} > W - 4 )); then help="Value: ${MV[SEL]}  $help"; fi
  local lines=() ww=$(( W - 4 )) cur="" word q
  for word in ${(z)help}; do
    if [[ -z $cur ]]; then cur=$word
    elif (( ${#cur} + 1 + ${#word} <= ww )); then cur+=" $word"
    else lines+=("$cur"); cur=$word; fi
  done
  [[ -n $cur ]] && lines+=("$cur")
  for (( q = 0; q < 3; q++ )); do
    margin
    if (( q < ${#lines[@]} )); then
      if (( q == 0 )); then pt "${TH[acc]}" "i ${lines[q+1]}"; else pt "${TH[acc]}" "  ${lines[q+1]}"; fi
    fi
    eol
  done
  margin; pt "${TH[dim]}" "arrows move   Enter select   Esc back   1-9 jump"; eol
  [[ -n $foot ]] && { margin; pt "${TH[dim]}" "$foot"; eol; }
  print -rn -- "$ESC[H$FRAME$ESC[J"
}

# getkey <seconds>: sets KEY, returns 1 on timeout
getkey(){
  local k rest
  KEY=""
  if ! read -k 1 -t "$1" k 2>/dev/null; then KEY=__timeout; return 1; fi
  if [[ $k == $'\e' ]]; then
    read -k 2 -t 0.05 rest 2>/dev/null
    case $rest in
      '[A'|'OA') KEY=Up;; '[B'|'OB') KEY=Down;;
      '[H'|'OH') KEY=Home;; '[F'|'OF') KEY=End;;
      '') KEY=Esc;; *) KEY=Other;;
    esac
  elif [[ -z $k || $k == $'\n' || $k == $'\r' ]]; then KEY=Enter
  elif [[ $k == $'\x7f' || $k == $'\x08' ]]; then KEY=Esc
  else KEY=$k
  fi
  return 0
}

menu(){
  local title=$1 foot=${2:-} n=${#ML[@]} idx
  tty_on
  (( SEL < 1 || SEL > n )) && SEL=1
  while true; do
    draw "$title" "$foot"
    if [[ $RAIN == 1 ]]; then
      if ! getkey 0.09; then (( RAIN_PH++ )); continue; fi
    else
      getkey 3600 || { MRES=-1; return 0; }
    fi
    case $KEY in
      Up) SEL=$(( (SEL - 2 + n) % n + 1 ));;
      Down) SEL=$(( SEL % n + 1 ));;
      Home) SEL=1;;
      End) SEL=$n;;
      Enter) [[ -z ${MD[SEL]} ]] && { MRES=$SEL; return 0; };;
      Esc) MRES=-1; return 0;;
      [1-9]) idx=${KEY}; if (( idx <= n )) && [[ -z ${MD[idx]} ]]; then MRES=$idx; return 0; fi;;
    esac
  done
}

ask(){
  local prompt=$1 def=$2
  print -rn -- "$ESC[H$ESC[J"$'\n'"$MARG$ESC[${TH[acc]}m$prompt$ESC[0m [$def]: "
  stty echo icanon 2>/dev/null
  ANSWER=""
  read -r ANSWER || { stty -echo -icanon 2>/dev/null; return 1; }
  stty -echo -icanon 2>/dev/null
  [[ -z $ANSWER ]] && ANSWER=$def
  return 0
}
say(){ local kind=$1; shift; print -r -- ""$'\n'"$MARG$ESC[${TH[$kind]}m$*$ESC[0m"; }
pause(){ tty_on; print -rn -- ""$'\n'"$MARG""Press any key to continue..."; read -k 1 -s _ 2>/dev/null; stty -echo -icanon 2>/dev/null; }
confirm(){
  local q=$1 old=$SHOW_BANNER
  reset_items; HEAD=("${TH[warn]}|$q" ""); SHOW_BANNER=0
  item "$(tx 'No, cancel')" '' 'Go back. Nothing is changed.'
  item "$(tx 'Yes, continue')" '' 'Do it now.' '' warn
  SEL=1; menu 'Confirm'
  SHOW_BANNER=$old
  (( MRES == 2 ))
}

desk_dir(){ local d="$HOME/Desktop"; mkdir -p "$d"; print -r -- "$d"; }

# ---------------------------------------------------------------- settings UI
show_val(){
  local i=$1 k=${SK[$1]} v
  v=${(P)k}
  case ${ST[i]} in
    bool) [[ $v == 1 ]] && print -r -- on || print -r -- off;;
    *) [[ -n $v ]] && print -r -- "$v" || print -r -- "(empty)";;
  esac
}
valid_val(){
  local i=$1 v=$2 o lo hi x
  case ${ST[i]} in
    bool) [[ $v == 0 || $v == 1 ]];;
    num) IFS=: read -r lo hi <<< "${SO[i]}"; [[ $v =~ ^[0-9]+$ ]] && (( v >= lo && v <= hi ));;
    enum) for x in ${(s:,:)SO[i]}; do [[ $x == $v ]] && return 0; done; return 1;;
    key) [[ $v =~ ^[A-Za-z]$ ]];;
    *) [[ ${SK[i]} != TARGET_COUNTRY ]] || [[ -z $v || $v =~ ^[A-Za-z]{2}$ ]];;
  esac
}
edit_setting(){
  local i=$1 k=${SK[$1]} v o n nx=1 j
  v=${(P)k}
  case ${ST[i]} in
    bool) cfg_set "$k" $(( 1 - v ));;
    enum) o=(${(s:,:)SO[i]}); n=${#o[@]}
          for (( j = 1; j <= n; j++ )); do [[ ${o[j]} == $v ]] && nx=$(( j % n + 1 )); done
          cfg_set "$k" "${o[nx]}";;
    *) ask "$(tx "${SL[i]}")" "$v" || return 0
       [[ $ANSWER == - ]] && ANSWER=""
       [[ $k == TARGET_COUNTRY ]] && ANSWER=${ANSWER:u}
       if valid_val "$i" "$ANSWER"; then cfg_set "$k" "$ANSWER"
       else say err "not allowed: ${SO[i]:-$( [[ ${ST[i]} == key ]] && print 'one letter' || print 'two letters or empty' )}"; pause; fi;;
  esac
}
group_menu(){
  local g=$1 i n idx
  while true; do
    idx=()
    reset_items; SHOW_BANNER=0
    for (( i = 1; i <= ${#SK[@]}; i++ )); do
      [[ ${SG[i]} == "$g" ]] || continue
      idx+=("$i"); item "$(tx "${SL[i]}")" "$(show_val "$i")" "$(tx "${SH[i]}")"
    done
    n=${#idx[@]}; item "$(tx 'Back')" '' 'Return to the settings.'
    menu "$(tx "$g")"
    (( MRES >= 1 && MRES <= n )) || return 0
    edit_setting "${idx[MRES]}"
    load_cfg; set_theme "$OCUI_THEME"; load_lang
  done
}
export_settings(){
  local f; f="$(desk_dir)/opencode-infinite-settings.env"
  grep -v -i 'token\|password' "$CONF" > "$f" 2>/dev/null || : > "$f"
  say ok "settings saved to $f"; pause
}
import_settings(){
  local k v i n=0 bad=0
  ask 'Settings file to import' "$(desk_dir)/opencode-infinite-settings.env" || return 0
  [[ -f $ANSWER ]] || { say err "not a file: $ANSWER"; pause; return 0; }
  while IFS='=' read -r k v; do
    for (( i = 1; i <= ${#SK[@]}; i++ )); do
      [[ ${SK[i]} == "$k" ]] || continue
      if valid_val "$i" "$v"; then cfg_set "$k" "$v"; (( n++ )); else (( bad++ )); fi
    done
  done < "$ANSWER"
  say ok "imported $n setting(s), skipped $bad invalid line(s)."; pause
}
reset_settings(){
  confirm 'Set every setting back to its default? Chats are not touched.' || return 0
  local pat i; pat=""
  for (( i = 1; i <= ${#SK[@]}; i++ )); do pat+="${pat:+|}^${SK[i]}="; done
  touch "$CONF"; grep -v -E "$pat" "$CONF" > "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
  say ok 'settings are back to their defaults.'; pause
}
support_menu(){
  local act
  while true; do
    reset_items; SHOW_BANNER=0
    item "$(tx 'Export settings')" '' 'Save the settings to a file on the Desktop.'
    item "$(tx 'Import settings')" '' 'Load a settings file. Unknown or invalid lines are skipped.'
    item "$(tx 'Reset settings')" '' 'Set every setting back to its default. Chats are not touched.'
    item "$(tx 'Desktop shortcut')" '' 'Create the OpenCode Infinite launcher icon on the Desktop.'
    item "$(tx 'Check for updates')" '' 'Look for a newer launcher and a newer opencode now.'
    item "$(tx 'Support report')" '' 'Write one text file with versions, settings and the log, for help.'
    item "$(tx 'Back')" '' 'Return to the settings.'
    menu "$(tx 'Support')"
    case $MRES in
      1) export_settings;;
      2) import_settings;;
      3) reset_settings;;
      4) make_shortcut; pause;;
      5) check_updates 1; pause;;
      6) support_report; pause;;
      *) return 0;;
    esac
    load_cfg; set_theme "$OCUI_THEME"; load_lang
  done
}
settings(){
  local groups=(Connection Tor 'Proxy list' Rotation Watcher Probe Updates Appearance Shortcuts Logs)
  local help=('Egress, WARP ports and timeouts.' 'Tor ports, bootstrap and install.' 'Free proxy list source and tests.' 'Rotation, IP target and the hunt.' 'Watching OpenCode and resuming.' 'The IP probe.' 'Update prompts.' 'Theme, colors, icons and language.' 'Keys for the closed-OpenCode prompt.' 'Activity log and report privacy.')
  local g i
  while true; do
    reset_items; SHOW_BANNER=0
    for (( i = 1; i <= ${#groups[@]}; i++ )); do item "$(tx "${groups[i]}")" '' "${help[i]}"; done
    item "$(tx 'Support')" '' 'Export, import, reset settings, shortcut, updates and the support report.'
    item "$(tx 'Back')" '' 'Return to the home screen.'
    menu "$(tx 'Settings')"
    if (( MRES >= 1 && MRES <= ${#groups[@]} )); then group_menu "${groups[MRES]}"
    elif (( MRES == ${#groups[@]} + 1 )); then support_menu
    else return 0; fi
  done
}

# ---------------------------------------------------------------- egress: WARP
warp_wc(){ timeout_cmd "$WARP_CALL_TIMEOUT" warp-cli --accept-tos "$@" >>"$STATE_DIR/wcli.log" 2>&1; }
warp_check(){
  local out
  out=$(curl -s -m 15 -x "http://127.0.0.1:$PROXY_PORT" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  print -r -- "$out" | grep -qE '^warp=(on|plus)' || return 1
  print -r -- "$out" | sed -n 's/^ip=//p'
}
warp_up(){
  have warp-cli || { log 'warp-cli missing'; return 1; }
  warp_wc registration show >/dev/null 2>&1 || warp_wc registration new
  warp_wc mode proxy; warp_wc proxy port "$PROXY_PORT"; warp_wc connect
  local i
  for (( i = 1; i <= WARP_WAIT; i++ )); do
    warp-cli --accept-tos status 2>/dev/null | grep -q 'Connected' && break
    sleep 1
  done
  warp_check >/dev/null
}
warp_rotate(){
  have warp-cli || return 1
  warp_wc registration delete; warp_wc registration new || return 1
  warp_up
}

# ---------------------------------------------------------------- egress: TOR
tor_running(){ port_open "$TOR_SOCKS_PORT"; }
tor_start(){
  if ! have tor; then
    if [[ $TOR_AUTO_INSTALL == 1 ]] && have brew; then
      say warn "$(tx 'Tor is missing.')"
      if confirm "Install tor with Homebrew now?"; then
        with_tty brew install tor >>"$STATE_DIR/install.log" 2>&1 || { say err "$(tx 'brew install tor failed.')"; return 1; }
      else return 1; fi
    else
      say err "$(tx 'Tor is missing. Install it with: brew install tor')"; return 1
    fi
  fi
  if ! tor_running; then
    : > "$STATE_DIR/tor.log"
    tor --SocksPort "$TOR_SOCKS_PORT" --HTTPTunnelPort "$TOR_HTTP_PORT" \
        --DataDirectory "$STATE_DIR/tor" --Log "notice file $STATE_DIR/tor.log" \
        --ClientOnly 1 >/dev/null 2>&1 &
    print -r -- $! > "$STATE_DIR/tor.pid"
    OURTOR=1
    local i
    for (( i = 1; i <= TOR_BOOTSTRAP_WAIT; i++ )); do
      grep -q 'Bootstrapped 100%' "$STATE_DIR/tor.log" 2>/dev/null && break
      port_open "$TOR_HTTP_PORT" && break
      sleep 1
    done
  fi
  port_open "$TOR_HTTP_PORT" || { log 'tor http tunnel port is not up'; return 1; }
  # a port that answers is not enough: it must route through Tor
  curl -s -m 30 -x "http://127.0.0.1:$TOR_HTTP_PORT" https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true' && return 0
  log "tor on $TOR_HTTP_PORT does not route through tor"
  return 1
}
tor_stop(){
  local tp
  tp=$(cat "$STATE_DIR/tor.pid" 2>/dev/null)
  if [[ -n $tp ]] && ps -p "$tp" -o command= 2>/dev/null | grep -q "DataDirectory $STATE_DIR/tor"; then
    kill "$tp" 2>/dev/null
  fi
  pkill -f "DataDirectory $STATE_DIR/tor" 2>/dev/null
  rm -f "$STATE_DIR/tor.pid"
}
tor_check(){
  local out
  out=$(curl -s -m 30 --socks5-hostname "127.0.0.1:$TOR_SOCKS_PORT" https://check.torproject.org/api/ip 2>/dev/null)
  print -r -- "$out" | grep -q '"IsTor":true' || return 1
  print -r -- "$out" | sed -n 's/.*"IP":"\([^"]*\)".*/\1/p'
}
tor_rotate(){
  tor_stop
  local i; for (( i = 1; i <= 5; i++ )); do port_open "$TOR_SOCKS_PORT" || break; sleep 1; done
  tor_start && tor_check >/dev/null
}

# ---------------------------------------------------------------- egress: PROXY list
shuffle_lines(){ awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -n | cut -f2-; }
proxy_pick(){
  local raw list p code tries=0
  PROXY_URL=""
  if [[ -n ${PROXY_FIXED:-} ]]; then
    p=$PROXY_FIXED
    [[ $p == http://* || $p == https://* ]] || p="http://$p"
    curl -s -m "$PROXY_PROBE_TIMEOUT" -x "$p" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^ip=' || return 1
    PROXY_URL=$p; return 0
  fi
  if [[ -f $PROXY_LIST_URL ]]; then raw=$(cat "$PROXY_LIST_URL"); else raw=$(curl -s -m 20 "$PROXY_LIST_URL"); fi
  if (( PROXY_LIST_MIN_BYTES > 0 )) && (( $(print -rn -- "$raw" | wc -c) < PROXY_LIST_MIN_BYTES )); then
    log 'proxy list smaller than PROXY_LIST_MIN_BYTES'; return 1
  fi
  list=$(print -r -- "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{2,5}' | sort -u | shuffle_lines | head -n 200)
  [[ -n $list ]] || { log 'proxy list empty'; return 1; }
  while IFS= read -r p; do
    (( tries++ )); (( tries > PROXY_TRY_MAX )) && break
    curl -s -m "$PROXY_PROBE_TIMEOUT" -x "http://$p" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^ip=' || continue
    PROXY_URL="http://$p"; return 0
  done <<< "$list"
  return 1
}

# ---------------------------------------------------------------- egress control
method_installed(){
  case $1 in
    WARP) have warp-cli;;
    TOR) have tor;;
    PROXY) have curl;;
    *) return 1;;
  esac
}
trace_get(){
  local args=()
  [[ -n ${PROXY_URL:-} ]] && args=(-x "$PROXY_URL")
  curl -s -m 15 "${args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null
}
current_ip(){ trace_get | sed -n 's/^ip=//p'; }
route_ok(){
  if [[ $EGRESS == WARP ]]; then print -r -- "$1" | grep -Eq '^warp=(on|plus)' || return 1; fi
  return 0
}
egress_up(){
  PROXY_URL=""
  case $EGRESS in
    WARP) warp_up && PROXY_URL="http://127.0.0.1:$PROXY_PORT";;
    TOR) tor_start && PROXY_URL="http://127.0.0.1:$TOR_HTTP_PORT";;
    PROXY) proxy_pick;;
    *) return 0;;
  esac
  [[ -n $PROXY_URL ]]
}
egress_rotate(){
  case $EGRESS in
    WARP) warp_rotate && PROXY_URL="http://127.0.0.1:$PROXY_PORT";;
    TOR) tor_rotate && PROXY_URL="http://127.0.0.1:$TOR_HTTP_PORT";;
    PROXY) proxy_pick;;
    *) return 1;;
  esac
}
export_proxy(){
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
  if [[ -n ${PROXY_URL:-} ]]; then
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
  else
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
  fi
}
target_match(){
  [[ -z $TARGET_COUNTRY ]] || [[ ${2:u} == ${TARGET_COUNTRY:u} ]] || return 1
  [[ -z $TARGET_PREFIX ]] || [[ $1 == "$TARGET_PREFIX"* ]] || return 1
  return 0
}

# ---------------------------------------------------------------- OpenCode
oc_find(){
  local c
  for c in "$(command -v opencode 2>/dev/null)" "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode; do
    [[ -n $c && -x $c ]] && { print -r -- "$c"; return 0; }
  done
  return 1
}
oc_version(){ timeout_cmd 20 "$1" --version 2>/dev/null | head -n1; }
oc_runner(){
  case $OC_REAL in
    *.js|*.mjs|*.cjs) RUNNER=(node "$OC_REAL");;
    *) RUNNER=("$OC_REAL");;
  esac
}
oc_install(){
  say warn "$(tx 'opencode was not found.')"
  if confirm "Install opencode with the official installer now?"; then
    curl -fsSL https://opencode.ai/install 2>/dev/null | bash >>"$STATE_DIR/install.log" 2>&1
    hash -r 2>/dev/null
    local c; c=$(oc_find) && { OC_REAL=$c; OC_CMD=$c; return 0; }
  fi
  if have npm; then
    if confirm "Try npm instead (npm i -g opencode-ai)?"; then
      npm i -g opencode-ai >>"$STATE_DIR/install.log" 2>&1
      hash -r 2>/dev/null
      local c; c=$(oc_find) && { OC_REAL=$c; OC_CMD=$c; return 0; }
    fi
  fi
  say err "$(tx 'opencode is still not installed.')"
  say dim "Get it by hand: https://opencode.ai/install"
  return 1
}
oc_ensure(){
  local c
  c=$(oc_find) || { oc_install || return 1; c=$OC_REAL; }
  OC_REAL=$c
  OC_CMD=$c
  OC_VER=$(oc_version "$c")
  return 0
}
app_find(){
  local p
  for p in "$OC_APP" /Applications/OpenCode.app "$(command -v OpenCode 2>/dev/null)"; do
    [[ -n $p && -d $p ]] && { print -r -- "$p"; return 0; }
    [[ -n $p && -x $p ]] && { print -r -- "$p"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- probe
probe_ip(){
  [[ $PROBE == 1 ]] || return 0
  local out rc sid pm=()
  oc_runner
  export_proxy
  [[ -n $PROBE_MODEL ]] && pm=(--model "$PROBE_MODEL")
  "${RUNNER[@]}" run --help 2>&1 | grep -q -- '--standalone' && pm+=(--standalone)
  out=$(cd "$HOME" && timeout_cmd 120 "${RUNNER[@]}" run --format json "${pm[@]}" "reply with the word ok" 2>&1); rc=$?
  sid=$(print -r -- "$out" | grep -o 'ses_[A-Za-z0-9]*' | head -n1)
  [[ -n $sid ]] && "${RUNNER[@]}" session delete "$sid" >/dev/null 2>&1
  if print -r -- "$out" | grep -Eiq "$OC_PAT|usage limit|rate limit|out of usage|insufficient credits|payment required|free usage"; then return 1; fi
  (( rc == 0 )) && return 0
  return 2
}
same_ip(){ [[ -n $1 && -n $2 && $1 == $2 ]]; }

hunt_new(){
  local tries interval goal=0 i ip gl burned=0 broken=0 start p prev="" seen="" same=0 end t r0
  [[ $EGRESS == NONE ]] && { say warn "$(tx 'Egress is NONE - nothing to rotate.')"; return 1; }
  if [[ -n $TARGET_COUNTRY$TARGET_PREFIX ]]; then
    goal=1; tries=$TARGET_TRIES; interval=$TARGET_INTERVAL
  else
    tries=$ROTATE_TRIES_MAX; interval=$ROTATE_COOLDOWN
  fi
  start=$(now)
  [[ -n ${PROXY_URL:-} ]] && prev=$(current_ip)
  seen=$prev
  for (( i = 1; i <= tries; i++ )); do
    if (( goal == 1 )) && (( $(now) - start > TARGET_MINUTES * 60 )); then say warn "$(tx 'target hunt: time is up.')"; return 1; fi
    print -r -- ""$'\n'"$MARG  [$i/$tries] rotating..."
    r0=$(now)
    if ! egress_rotate; then say warn '  rotation failed'; sleep "$interval"; continue; fi
    end=$(( $(now) + WARP_WAIT ))
    while true; do
      t=$(trace_get)
      ip=$(print -r -- "$t" | sed -n 's/^ip=//p')
      gl=$(print -r -- "$t" | sed -n 's/^loc=//p')
      [[ -n $ip ]] && route_ok "$t" && break
      (( $(now) >= end )) && break
      sleep 1
    done
    if [[ -z $ip ]] || ! route_ok "$t"; then say warn '  route not answering'; sleep "$interval"; continue; fi
    log "rotate new=$ip country=$gl try=$i/$tries"
    say ok "  exit IP $ip (country $gl)"
    if same_ip "$ip" "$seen"; then
      (( same++ )); say warn "  same IP as before ($same of $ROTATE_TRIES_MAX), trying again"
      if (( same >= ROTATE_TRIES_MAX )); then say err "$(tx 'the rotation keeps returning the same IP.')"; return 1; fi
      sleep "$ROTATE_COOLDOWN"; continue
    fi
    same=0; seen=$ip
    if ! target_match "$ip" "$gl"; then sleep "$interval"; continue; fi
    probe_ip; p=$?
    case $p in
      0) return 0;;
      1) (( burned++ )); say warn '  IP already burned, rotating again...'
         if (( IP_FIND_MAX > 0 && burned >= IP_FIND_MAX )); then say err "$(tx 'burned IP limit reached.')"; return 1; fi
         if [[ $EGRESS == PROXY ]] && (( burned >= PROXY_ROT_MAX )); then
           burned=0
           if confirm 'Too many burned proxies. Switch this hunt to Tor?'; then EGRESS=TOR; say ok 'switched to Tor for this run.'; fi
         fi;;
      *) (( broken++ )); say err "  probe failed for a reason that is not a limit ($broken of $PROBE_BROKEN_MAX)"
         if (( broken >= PROBE_BROKEN_MAX )); then say err 'the probe looks broken. Check Probe model in Settings > Probe.'; return 1; fi;;
    esac
    sleep "$interval"
  done
  return 1
}

# ---------------------------------------------------------------- tokens, crash
token_guard(){
  local auth="$DATA_DIR/auth.json" snap="$STATE_DIR/auth_snapshot/auth.json"
  if [[ -e $auth ]]; then
    (( $(fsize "$auth") >= 3 )) || return 0
    mkdir -p "$STATE_DIR/auth_snapshot" && cp -f "$auth" "$snap" 2>/dev/null
  elif [[ -s $snap ]]; then
    mkdir -p "$DATA_DIR" && cp -f "$snap" "$auth" || return 0
    log 'tokens: auth.json was missing, restored from the launcher snapshot'
    say warn "auth.json had disappeared; it was restored from the launcher copy. No login needed."
  fi
}
drop_snapshot(){ rm -f "$STATE_DIR/auth_snapshot/auth.json"; }
CRASH_STREAK=0; CRASH_LAST=0
crash_retry(){
  local now wait
  now=$(now)
  (( now - CRASH_LAST > 600 )) && CRASH_STREAK=0
  CRASH_LAST=$now; (( CRASH_STREAK++ ))
  log "opencode crashed: code $1 streak $CRASH_STREAK egress=$EGRESS"
  if (( CRASH_STREAK > 2 )); then
    say err "OpenCode crashed $CRASH_STREAK times in 10 minutes. Stopped so it is not restarted in a loop. Details in launcher.log."
    return 1
  fi
  [[ $EGRESS == NONE ]] && return 2
  wait=$(( CRASH_STREAK * 2 ))
  say warn "OpenCode stopped with code $1. Retry $CRASH_STREAK of 2 on the same connection in ${wait} s; the chat resumes."
  sleep "$wait"
  return 0
}

# ---------------------------------------------------------------- run OpenCode
stop_opencode(){
  local p
  [[ -s $OC_PIDS ]] || return 0
  while read -r p; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    kill -TERM "$p" 2>/dev/null
  done < "$OC_PIDS"
  sleep 1
  while read -r p; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    kill -KILL "$p" 2>/dev/null
  done < "$OC_PIDS"
  : > "$OC_PIDS"
}
app_run(){
  local exe="$1/Contents/MacOS/OpenCode" pid out="$STATE_DIR/desktop.log"
  [[ -x $exe ]] || exe="$1"
  mv -f "$out" "$out.1" 2>/dev/null
  ( cd "$FOLDER" && exec "$exe" ) </dev/null >"$out" 2>&1 &
  pid=$!
  print -r -- "$pid" > "$OC_PIDS"
  log "desktop: started pid $pid: $exe"
  say ok "$(tx 'The OpenCode app is running. Close it to come back here.')"
  wait "$pid"
}

line_class(){
  if print -r -- "$1" | grep -Eiq "$PAT_NOOP"; then print noop
  elif print -r -- "$1" | grep -Eiq "$PAT_ROTATE"; then print rotate
  elif print -r -- "$1" | grep -Eiq "$PAT_ASK"; then print ask; fi
}
limit_hit(){
  local l c act ask=1 ts last
  while IFS= read -r l; do
    ts=$(print -r -- "$l" | sed -nE 's/.*timestamp=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p')
    [[ -n $ts && -n ${LIMIT_T0:-} && $ts < $LIMIT_T0 ]] && continue
    c=$(line_class "$l"); [[ -n $c ]] || continue
    case $c in
      rotate) act=rotate;;
      ask) last=$(cat "$ASK_LAST" 2>/dev/null)
           [[ $last =~ ^[0-9]+$ ]] || last=0
           if (( $(now) - last >= 600 )); then act=ask; ask=0; else act=ignore-cooldown; fi;;
      *) act=ignore;;
    esac
    log "watch: category=$c action=$act line=${l[1,160]}"
    [[ $act == rotate ]] && return 0
  done < <(print -r -- "$1" | grep -Ei 'level=ERROR')
  (( ask == 0 )) && return 2
  return 1
}
watch_log(){
  local start=$1 cur="" pos=0 f size hit
  typeset -A base
  for f in "$DATA_DIR"/log/*.log; do base[$f]=$(fsize "$f"); done
  LIMIT_T0=$(date '+%Y-%m-%dT%H:%M:%S')
  while true; do
    sleep 2
    f=$(ls -t "$DATA_DIR"/log/*.log 2>/dev/null | head -n1)
    [[ -n $f ]] || continue
    if [[ $f != $cur ]]; then
      cur=$f
      if (( $(fmtime "$f") >= start )); then pos=${base[$f]:-0}; else pos=$(fsize "$f"); fi
    fi
    size=$(fsize "$f")
    if (( size > pos )); then
      limit_hit "$(tail -c +$(( pos + 1 )) "$f")"; hit=$?
      if (( hit == 0 )); then
        : > "$LIMIT_FLAG"; stop_opencode; exit 0
      elif (( hit == 2 )); then
        date +%s > "$ASK_LAST"; : > "$ASK_FLAG"; stop_opencode; exit 0
      fi
      pos=$size
    fi
  done
}
resume_chat(){
  local msg="$RESUME_MSG" out rc
  [[ $RESUME_MODE == custom && -n $RESUME_TEXT ]] && msg=$RESUME_TEXT
  oc_runner
  export_proxy
  local args=(run)
  [[ $RESUME_AUTO == 1 ]] && args+=(--auto)
  "${RUNNER[@]}" run --help 2>&1 | grep -q -- '--continue' && args+=(--continue)
  [[ -n ${OC_SESSION:-} ]] && args+=(--session "$OC_SESSION")
  log "resume: msg=$msg args=${args[*]} ip=$(current_ip)"
  say ok "  sending \"$msg\" so the chat picks up where it stopped..."
  out=$(cd "$FOLDER" && timeout_cmd "$RESUME_TIMEOUT" "${RUNNER[@]}" "${args[@]}" "$msg" 2>&1); rc=$?
  print -r -- "$out" > "$STATE_DIR/resume.log"
  if print -r -- "$out" | grep -Eiq "$OC_PAT"; then say warn '  the resume itself hit a limit.'; return 2; fi
  (( rc == 0 )) && { say ok '  chat resumed on the new IP.'; return 0; }
  say warn "  no answer in ${RESUME_TIMEOUT}s - this exit IP is dead."
  print -r -- "$out" | tail -n 6 | sed "s/^/$MARG  /"
  return 1
}
ask_rotate(){
  local ans=""
  print -rn -- ""$'\n'"$MARG$(tx 'Rate limit detected. Rotate the IP now? [y/N] ')"
  stty echo icanon 2>/dev/null
  read -r -t 60 ans
  stty -echo -icanon 2>/dev/null
  print -r -- ""
  log "rate limit: asked, answer='${ans:-timeout/empty}'"
  [[ ${ans:l} == (y|yes|s|si|sí) ]]
}
on_close_prompt(){
  local k
  tty_on
  say ok "OpenCode closed."
  say dim "  $KEY_ROTATE = new IP and resume the chat   $KEY_MENU = menu   $KEY_QUIT = quit (Ctrl+C also quits)"
  while true; do
    read -k 1 -t 3600 k 2>/dev/null || return 2
    k=${k:u}
    [[ $k == ${KEY_ROTATE:u} ]] && return 0
    [[ $k == ${KEY_MENU:u} ]] && return 1
    [[ $k == ${KEY_QUIT:u} ]] && return 2
  done
}

# ---------------------------------------------------------------- deep reset / restore
archive_dir(){ local d; d="$(desk_dir)/opencode_chats_archiviate/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d"; print -r -- "$d"; }
move_storage(){
  local dest=$1 f moved=0
  for f in "$DATA_DIR"/opencode.db "$DATA_DIR"/opencode.db-wal "$DATA_DIR"/opencode.db-shm "$DATA_DIR"/storage "$DATA_DIR"/project "$DATA_DIR"/snapshot; do
    [[ -e $f ]] || continue
    mv "$f" "$dest/" 2>/dev/null || cp -R "$f" "$dest/" 2>/dev/null && { [[ -e $f ]] && rm -rf "$f"; }
    (( moved++ ))
  done
  (( moved > 0 ))
}
deep_reset(){
  confirm 'Move the chats to the Desktop and start a fresh session?' || return 0
  stop_opencode
  local dest bak
  dest=$(archive_dir)
  bak="$STATE_DIR/backup/auth/$(date +%Y%m%d-%H%M%S)"
  say ok "  archiving chats to: $dest"
  if move_storage "$dest"; then say ok '  archived.'; else say warn '  nothing to archive.'; fi
  mkdir -p "$bak"
  [[ -f "$DATA_DIR/auth.json" ]] && cp -f "$DATA_DIR/auth.json" "$bak/" 2>/dev/null && rm -f "$DATA_DIR/auth.json"
  drop_snapshot
  rm -rf "$DATA_DIR/cache" 2>/dev/null
  say ok '  cache and tokens cleared.'
  egress_rotate
  start_open
}
restore_chats(){
  local root="$(desk_dir)/opencode_chats_archiviate" i n=0 dirs=()
  [[ -d $root ]] || { say warn '  nothing to restore.'; pause; return 0; }
  while IFS= read -r d; do dirs+=("$d"); (( n++ )); done < <(ls -1dt "$root"/*/ 2>/dev/null)
  (( n > 0 )) || { say warn '  nothing to restore.'; pause; return 0; }
  reset_items; SHOW_BANNER=0
  for (( i = 1; i <= n; i++ )); do item "${dirs[i]:t}" '' "Restore this archive: ${dirs[i]}"; done
  item 'Back' '' 'Return without changing anything.'
  menu 'Restore chats'
  (( MRES >= 1 && MRES <= n )) || return 0
  local src=${dirs[MRES]} aside="$(desk_dir)/opencode_chats_before_restore/$(date +%Y%m%d-%H%M%S)"
  stop_opencode
  mkdir -p "$aside" "$DATA_DIR"
  say ok "  moving the chats in place now to: $aside"
  move_storage "$aside" >/dev/null 2>&1
  local f
  for f in "$src"/opencode.db "$src"/opencode.db-wal "$src"/opencode.db-shm "$src"/storage "$src"/project "$src"/snapshot; do
    [[ -e $f ]] && cp -R "$f" "$DATA_DIR/" 2>/dev/null
  done
  say ok '  Chats restored. The previous ones are in:'
  say dim "  $aside"
  pause
}
renew_session(){
  confirm 'Close OpenCode, back up and clear the tokens, then get a new IP?' || return 0
  stop_opencode
  local bak="$STATE_DIR/backup/auth/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bak"
  if [[ -f "$DATA_DIR/auth.json" ]]; then
    cp -f "$DATA_DIR/auth.json" "$bak/" 2>/dev/null && say ok "  auth.json archived in $bak"
  fi
  rm -f "$DATA_DIR/auth.json"
  drop_snapshot
  rm -rf "$DATA_DIR/cache" 2>/dev/null
  say ok '  cache and tokens cleared.'
  egress_rotate && say ok '  new route is up.'
  pause
}

# ---------------------------------------------------------------- commands, shortcut, report, updates
make_shortcut(){
  local f; f="$(desk_dir)/OpenCode Infinite.command"
  print -r -- "#!/bin/zsh" > "$f"
  print -r -- "exec /bin/zsh \"$SELF\"" >> "$f"
  chmod +x "$f"
  say ok "  shortcut created: $f"
}
install_commands(){
  local target="$APP_DIR/opencode-infinite-macos.sh" rcfile="$HOME/.zshrc"
  mkdir -p "$APP_DIR" "$BIN_DIR"
  if [[ $SELF != "$target" ]]; then
    cp -f "$SELF" "$target" || { say err '  could not copy the launcher into its app folder.'; return 1; }
  fi
  chmod +x "$target"
  for c in opencodeinf opencode-auto; do
    local extra=""
    [[ $c == opencode-auto ]] && extra=' --auto'
    print -r -- "#!/bin/zsh" > "$BIN_DIR/$c"
    print -r -- "exec /bin/zsh \"$target\"$extra \"\$@\"" >> "$BIN_DIR/$c"
    chmod +x "$BIN_DIR/$c"
  done
  if ! grep -q "$BIN_DIR" "$rcfile" 2>/dev/null; then
    print -r -- "" >> "$rcfile"
    print -r -- "# added by OpenCode Infinite" >> "$rcfile"
    print -r -- "export PATH=\"$BIN_DIR:\$PATH\"" >> "$rcfile"
  fi
  cfg_set OC_CMD "$OC_REAL"
  say ok "  commands installed: opencodeinf, opencode-auto"
  say dim "  $BIN_DIR is on your PATH in new terminals."
}
remove_commands(){
  confirm 'Remove the opencodeinf and opencode-auto commands?' || return 0
  rm -f "$BIN_DIR/opencodeinf" "$BIN_DIR/opencode-auto"
  say ok '  commands removed.'
  pause
}
support_report(){
  local f="$STATE_DIR/reports/report-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$STATE_DIR/reports"
  {
    print -r -- "OpenCode Infinite for macOS - support report"
    print -r -- "generated: $(date)"
    print -r -- "launcher : $VERSION"
    print -r -- "macOS    : $(sw_vers -productVersion 2>/dev/null) $(uname -m)"
    print -r -- "shell    : $ZSH_VERSION"
    print -r -- "opencode : ${OC_VER:-not found} ${OC_REAL:-}"
    print -r -- "warp-cli : $(warp-cli --version 2>/dev/null || print 'not installed')"
    print -r -- "tor      : $(tor --version 2>/dev/null | head -n1 || print 'not installed')"
    print -r -- ""
    print -r -- "--- settings ---"
    cat "$CONF" 2>/dev/null | grep -v -i 'token\|password\|key='
    print -r -- ""
    print -r -- "--- last log lines ---"
    tail -n 120 "$LOG" 2>/dev/null
  } > "$f"
  if [[ $LOG_MASK_IP == 1 ]]; then
    perl -pi -e 's/\b(?:\d{1,3}\.){3}\d{1,3}\b/<ip>/g' "$f" 2>/dev/null
  fi
  say ok "  report written: $f"
}
release_tag(){
  curl -fsSL -m 20 "$REPO/-/releases/permalink/latest" 2>/dev/null | grep -oE '/-/releases/v[0-9]+(\.[0-9]+)+' | head -n1 | sed 's|.*/v||'
}
ver_gt(){
  local -a a b; local i x y
  a=(${(s:.:)1}); b=(${(s:.:)2})
  for (( i = 1; i <= ${#a} || i <= ${#b}; i++ )); do
    x=${a[i]:-0}; y=${b[i]:-0}
    (( 10#$x > 10#$y )) && return 0
    (( 10#$x < 10#$y )) && return 1
  done
  return 1
}
check_updates(){
  local manual=${1:-0} tag cur up
  [[ $UPDATE_ASK == never && $manual == 0 ]] && return 0
  [[ $UPDATE_CHECK != 1 && $manual == 0 ]] && return 0
  cur=${VERSION#macos-}
  up="$REPO_RAW/opencode-infinite-macos.sh"
  if curl -fsI -m 10 "$up" >/dev/null 2>&1; then
    tag=$(release_tag)
    if [[ -n $tag ]] && ver_gt "$tag" "$cur"; then
      say warn "  launcher update available: $cur -> $tag"
      if confirm "Download and replace the launcher now?"; then
        local tmp="$STATE_DIR/launcher.new"
        curl -fsSL -m 60 "$REPO/-/raw/v$tag/opencode-infinite-macos.sh" -o "$tmp" 2>/dev/null
        if [[ -s $tmp ]] && head -n 3 "$tmp" | grep -q 'OpenCode Infinite for macOS'; then
          cp -f "$SELF" "$SELF.bak" 2>/dev/null
          mv -f "$tmp" "$SELF" && chmod +x "$SELF"
          say ok '  launcher replaced. Restart it to use the new version.'
        else
          say err '  the downloaded copy is missing or not the launcher; nothing was replaced.'
          rm -f "$tmp"
        fi
      fi
    elif (( manual == 1 )); then
      say ok "  launcher is up to date ($VERSION)."
    fi
  elif (( manual == 1 )); then
    say ok "  no published macOS build upstream yet; this copy is $VERSION."
  fi
  if (( manual == 1 )); then
    local c; c=$(oc_find) && say ok "  opencode: $(oc_version "$c") at $c"
  fi
}

# ---------------------------------------------------------------- setup, home, main
choose_egress(){
  local def=$OC_EGRESS_DEFAULT
  [[ $def == ASK ]] || { EGRESS=$def; return 0; }
  reset_items; SHOW_BANNER=0
  item 'WARP' 'Cloudflare WARP proxy mode (rotation)' 'Cloudflare WARP in local proxy mode on port 40000. Needs the WARP app.'
  item 'TOR' 'local Tor + HTTPTunnelPort' 'The launcher starts its own tor with an HTTP tunnel. Nothing else to install.'
  item 'PROXY' 'free HTTP proxies' 'Free HTTP proxies from the configured list. Dead ones are skipped.'
  item 'NONE' 'direct, no proxy' 'No proxy. OpenCode runs on your real IP.'
  SEL=1; menu 'Egress for OpenCode only (system traffic stays direct)'
  case $MRES in
    1) EGRESS=WARP;; 2) EGRESS=TOR;; 3) EGRESS=PROXY;; *) EGRESS=NONE;;
  esac
}
choose_folder(){
  local f
  reset_items; SHOW_BANNER=0
  item 'Use this folder' "${PWD:t}" "OpenCode will work in $PWD"
  item 'Browse for a folder...' '' 'Type or paste a folder path.'
  item 'Exit' '' 'Leave the launcher.'
  menu 'Choose a folder to work in'
  case $MRES in
    1) FOLDER=$PWD;;
    2) ask 'Folder path' "$HOME"; FOLDER=$ANSWER;;
    *) return 1;;
  esac
  case $FOLDER in
    "~") FOLDER="$HOME";;
    "~/"*) FOLDER="$HOME/${FOLDER:2}";;
  esac
  [[ -d $FOLDER ]] || { say err "Folder not found: $FOLDER"; pause; return 1; }
  print -r -- "$FOLDER" > "$STATE_DIR/lastfolder.txt"
  return 0
}
setup_wizard(){
  choose_egress || return 0
  cfg_set OC_EGRESS_DEFAULT "$EGRESS"
  reset_items; SHOW_BANNER=0
  item 'CLI' 'terminal TUI' 'OpenCode in this terminal.'
  item 'DESKTOP' 'OpenCode app' 'The OpenCode desktop app, restarted on every new IP.'
  SEL=1; menu 'Run mode'
  [[ $MRES == 2 ]] && cfg_set OC_MODE_DEFAULT DESKTOP || cfg_set OC_MODE_DEFAULT CLI
  cfg_set SETUP_DONE 1
  install_commands
  make_shortcut
  load_cfg
  say ok '  connection set up.'
  pause
}
status_lines(){
  local ip=""
  [[ -n ${PROXY_URL:-} ]] && ip=$(current_ip)
  reset_items; SHOW_BANNER=1
  HEAD=("${TH[acc]}|  OpenCode" "${TH[dim]}|  Folder : ${FOLDER:-$PWD}" "${TH[dim]}|  Egress : $EGRESS" "${TH[dim]}|  Mode   : $OC_MODE_DEFAULT" "${TH[dim]}|  Version: ${OC_VER:-?}  ${OC_REAL:-}")
  [[ -n $ip ]] && HEAD+=("${TH[ok]}|  Exit IP: $ip")
  [[ $EGRESS == WARP ]] && ! have warp-cli && HEAD+=("${TH[warn]}|  WARP   : not found - rotation disabled")
}
main_menu(){
  while true; do
    status_lines
    item 'Fresh start' '' 'Get a new IP / proxy, then open OpenCode. Chats stay untouched.'
    item 'Continue' '' 'Same egress, open OpenCode as it was.'
    item 'Change IP' '' 'Rotate / pick a new proxy only.'
    item 'Chats' '' 'Deep reset and restore.'
    item 'Mode' '' 'Switch between CLI and Desktop.'
    item 'Back' '' 'Return to the home screen.'
    item 'Exit' '' 'Close the launcher.'
    SEL=1; menu 'What do you want to do?'
    case $MRES in
      1) MAIN_ACTION=fresh; return 0;;
      2) MAIN_ACTION=continue; return 0;;
      3) hunt_new; pause;;
      4) deep_reset_or_restore;;
      5) [[ $OC_MODE_DEFAULT == CLI ]] && cfg_set OC_MODE_DEFAULT DESKTOP || cfg_set OC_MODE_DEFAULT CLI; load_cfg;;
      6) return 1;;
      *) return 2;;
    esac
  done
}
deep_reset_or_restore(){
  reset_items; SHOW_BANNER=0
  item 'Deep reset' '' 'Move chats to the Desktop, clear tokens, fresh session.'
  item 'Restore chats' '' 'Pick an archived folder and copy the chats back.'
  item 'Back' '' 'Return.'
  menu 'Chats'
  case $MRES in
    1) deep_reset;;
    2) restore_chats;;
  esac
}
start_open(){
  local rc
  if [[ $OC_MODE_DEFAULT == DESKTOP ]]; then
    local app; app=$(app_find)
    if [[ -z $app ]]; then
      say warn '  OpenCode desktop app not found. Set OC_APP in Settings > Connection.'
      pause; return 1
    fi
    export_proxy
    app_run "$app"
    return 0
  fi
  oc_ensure || return 1
  export_proxy
  token_guard
  local start; start=$(now)
  rm -f "$LIMIT_FLAG" "$ASK_FLAG"
  if [[ $WATCH == 1 ]]; then watch_log "$start" & WATCH_PID=$!; fi
  ( cd "$FOLDER" && exec "$OC_REAL" ) &
  local ocpid=$!
  print -r -- "$ocpid" > "$OC_PIDS"
  wait "$ocpid"; rc=$?
  : > "$OC_PIDS"
  tty_on
  [[ -n ${WATCH_PID:-} ]] && { kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""; }
  EC=$rc
  if [[ -f $LIMIT_FLAG ]]; then
    say warn '  a fatal limit line cut the chat - rotating and resuming it.'
    return 10
  fi
  if [[ -f $ASK_FLAG ]]; then
    say warn '  rate limit detected.'
    ask_rotate && return 10
    return 0
  fi
  (( rc == 0 )) && return 0
  return $rc
}
launch_loop(){
  local mode=$1
  while true; do
    if [[ $mode == fresh ]]; then
      if [[ $EGRESS != NONE ]]; then
        hunt_new || { say err "  could not get a $EGRESS route; not starting on your real IP."; pause; return 1; }
      fi
      mode=open
    elif [[ $EGRESS != NONE && -z ${PROXY_URL:-} ]]; then
      egress_up || { say warn "  egress $EGRESS is not up."; pause; return 1; }
    fi
    start_open; local rc=$?
    case $rc in
      0) # normal close
        if [[ $ON_CLOSE == ask && $OPT_AUTO != 1 ]]; then
          on_close_prompt; local oc=$?
          case $oc in
            0) mode=fresh; continue;;
            1) return 1;;
            *) return 2;;
          esac
        fi
        return 0;;
      10) # limit: rotate, resume, reopen
        if [[ $AUTO_ROTATE != 1 ]]; then
          reset_items; SHOW_BANNER=0
          item 'New IP and resume' '' 'Rotate and continue the same chat.'
          item 'Back' '' 'Return to the menu.'
          menu 'A limit stopped the chat'
          (( MRES == 1 )) || return 1
        fi
        hunt_new || { say err '  could not get a working route.'; return 1; }
        resume_chat; local rr=$?
        if (( rr == 0 )); then mode=open; else mode=fresh; fi
        continue;;
      *)
        if [[ $OPT_AUTO == 1 ]]; then
          crash_retry "$rc"; local cr=$?
          (( cr == 0 )) && { resume_chat; mode=open; continue; }
          return 1
        fi
        say warn "OpenCode exited with code $rc."
        on_close_prompt; local oc=$?
        case $oc in
          0) mode=fresh; continue;;
          1) return 1;;
          *) return 2;;
        esac;;
    esac
  done
}

# ---------------------------------------------------------------- entry
with_tty(){ stty sane 2>/dev/null; "$@"; local rc=$?; stty -echo -icanon 2>/dev/null; return $rc; }
tty_on(){ [[ -t 0 ]] && stty -echo -icanon min 1 time 0 2>/dev/null; }
tty_off(){ [[ -t 0 ]] && stty sane 2>/dev/null; }

help_mode(){
  print -r -- "OpenCode Infinite for macOS $VERSION"
  print -r -- ""
  print -r -- "Usage:"
  print -r -- "  opencode-infinite-macos.sh                 the menu"
  print -r -- "  opencode-infinite-macos.sh --run [args]    quick start with the saved connection"
  print -r -- "  opencode-infinite-macos.sh --auto          start with no menu (folder = current)"
  print -r -- "  opencode-infinite-macos.sh --verify        print the egress and the exit IP"
  print -r -- "  opencode-infinite-macos.sh --renew         clear the tokens and get a new IP"
  print -r -- "  opencode-infinite-macos.sh --install       install opencodeinf / opencode-auto"
  print -r -- "  opencode-infinite-macos.sh --help"
  print -r -- ""
  print -r -- "State: $STATE_DIR"
  print -r -- "Data : $DATA_DIR"
}

lock_take(){
  local lf="$STATE_DIR/launcher.pid" p
  if [[ -f $lf ]]; then
    p=$(cat "$lf" 2>/dev/null)
    if [[ -n $p ]] && kill -0 "$p" 2>/dev/null; then
      say warn "  OpenCode Infinite is already open in another window (PID $p)."
      return 1
    fi
  fi
  print -r -- $$ > "$lf"
  LOCK_FILE=$lf
  return 0
}
lock_drop(){ [[ -n ${LOCK_FILE:-} ]] && rm -f "$LOCK_FILE"; }

cleanup(){
  tty_off
  [[ -n ${WATCH_PID:-} ]] && kill "$WATCH_PID" 2>/dev/null
  lock_drop
  [[ -n ${OURTOR:-} ]] && tor_stop
  return 0
}
trap 'cleanup; exit 130' INT TERM HUP
trap 'cleanup' EXIT

case ${1:-} in
  --help|-h) help_mode; exit 0;;
esac

load_cfg
set_theme "$OCUI_THEME"
load_lang

if [[ ${1:-} == --verify ]]; then
  oc_find >/dev/null 2>&1
  egress_up || { say err "egress $EGRESS is not up"; exit 1; }
  local_ip=$(current_ip)
  say ok "egress: $EGRESS  ip=${local_ip:-none}"
  exit 0
fi
if [[ ${1:-} == --renew ]]; then
  tty_on
  renew_session
  tty_off
  exit 0
fi
if [[ ${1:-} == --install ]]; then
  oc_ensure || exit 1
  install_commands
  exit 0
fi

OPT_AUTO=0; OPT_QUIET=0
if [[ ${1:-} == --run ]]; then
  shift; OPT_QUIET=1
  FOLDER=$PWD
  [[ $EGRESS == ASK ]] && EGRESS=NONE
  lock_take || exit 1
  tty_on
  oc_ensure || { tty_off; exit 1; }
  egress_up || { say err "  egress $EGRESS is not up."; tty_off; exit 1; }
  start_open
  rc=$?
  (( rc == 10 )) && { hunt_new; resume_chat; start_open; }
  tty_off
  exit 0
fi
if [[ ${1:-} == --auto ]]; then
  shift; OPT_AUTO=1; OPT_QUIET=1
  FOLDER=$PWD
  lock_take || exit 1
  tty_on
  oc_ensure || { tty_off; exit 1; }
  launch_loop fresh
  tty_off
  exit 0
fi

lock_take || { tty_off; exit 1; }
tty_on
oc_ensure
[[ $SETUP_DONE != 1 ]] && { load_cfg; }
check_updates 0

HOME_SEL=1
while true; do
  tty_on
  reset_items; SHOW_BANNER=1
  HEAD=()
  [[ $SETUP_DONE == 1 ]] && HEAD+=("${TH[ok]}|  Configured")
  item 'Launch OpenCode' '' 'Pick a folder and a connection, then start.'
  item "$( [[ $SETUP_DONE == 1 ]] && print 'Change connection' || print 'Set up connection' )" '' 'Egress, run mode, commands and the shortcut.'
  item 'Renew session' '' 'Close OpenCode, back up and clear the tokens, get a new IP.'
  item 'Deep reset / Restore' '' 'Move chats to the Desktop, clear tokens, or restore an archive.'
  item 'Settings' '' 'Every launcher option.'
  item 'Support report' '' 'One text file with versions, settings and the log.'
  item 'Install commands' '' 'Write opencodeinf and opencode-auto to ~/.local/bin.'
  item 'Exit' '' 'Close the launcher.'
  SEL=$HOME_SEL; menu 'OpenCode Infinite'
  HOME_SEL=$SEL
  case $MRES in
    1) choose_folder || continue
       choose_egress
       oc_ensure || { pause; continue; }
       main_menu; mm=$?
       if (( mm == 0 )); then
         launch_loop "$MAIN_ACTION"; lr=$?
         (( lr == 2 )) && break
       elif (( mm == 2 )); then
         break
       fi;;
    2) setup_wizard;;
    3) renew_session;;
    4) deep_reset_or_restore;;
    5) settings;;
    6) support_report; pause;;
    7) install_commands; pause;;
    *) break;;
  esac
  load_cfg; set_theme "$OCUI_THEME"; load_lang
done
cleanup
exit 0
