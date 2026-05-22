#!/bin/bash
# notifier.sbatch: dependent job submitted by slurmailer. Runs on a compute node
# after the watched job ends, gathers stats, and emails a detailed report.
# Resources/partition/dependency are set by slurmailer at submit time.
#SBATCH --job-name=notifier
set -uo pipefail

# SLURM copies this script to a private spool dir before running it, so it cannot
# locate config.sh via its own path. slurmailer passes the install dir as --confdir.
# Parse args FIRST, then source config from the install dir.
CONFDIR="" ; JOBID="" ; STDOUT="" ; STDERR="" ; WORKDIR="" ; SUBMIT_CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confdir) CONFDIR="$2"; shift 2;;
    --jobid)   JOBID="$2";   shift 2;;
    --stdout)  STDOUT="$2";  shift 2;;
    --stderr)  STDERR="$2";  shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --submit)  SUBMIT_CMD="$2"; shift 2;;
    *) shift;;
  esac
done

# shellcheck source=config.sh
source "$CONFDIR/config.sh"
[[ -n "${SLURM_BIN:-}" ]] && export PATH="$SLURM_BIN:$PATH"

# --- gather stats (retry: slurmdbd can lag a moment after the job ends) ---
# Parent allocation row (-X) for state/timing/requests; MaxRSS lives on step rows.
LINE=""
for _ in 1 2 3 4 5; do
  LINE=$(sacct -j "$JOBID" -X --noheader --parsable2 \
    --format=JobName,State,ExitCode,Elapsed,Submit,Start,End,Planned,Partition,NodeList,ReqMem,AllocCPUS,TotalCPU \
    | head -1)
  [[ -n "$LINE" ]] && break
  sleep 3
done
IFS='|' read -r JOBNAME STATE EXITCODE ELAPSED SUBMIT START END QUEUED PART NODELIST REQMEM ALLOCCPUS TOTALCPU <<<"$LINE"
[[ -z "$JOBNAME" ]] && JOBNAME="job"
[[ -z "$ELAPSED" ]] && ELAPSED="unknown"

# MaxRSS: take the largest value across step rows (parent row has none).
MAXRSS=$(sacct -j "$JOBID" --noheader --parsable2 --format=MaxRSS \
  | grep -vE '^$' | sort -h | tail -1)

# --- verdict: ASCII tag (subject/text) + retro accent colour (HTML) ---
case "$STATE" in
  COMPLETED*)      TAG="OK";        VERDICT="COMPLETED";     CFG="#3dff8a";;
  FAILED*)         TAG="FAILED";    VERDICT="FAILED";        CFG="#ff5f56";;
  TIMEOUT*)        TAG="TIMEOUT";   VERDICT="TIMED OUT";     CFG="#ffbd2e";;
  OUT_OF_MEMORY*)  TAG="OOM";       VERDICT="OUT OF MEMORY"; CFG="#ff5f56";;
  CANCELLED*)      TAG="CANCELLED"; VERDICT="CANCELLED";     CFG="#ffbd2e";;
  NODE_FAIL*)      TAG="NODE_FAIL"; VERDICT="NODE FAILURE";  CFG="#ff5f56";;
  *)               TAG="$STATE";    VERDICT="$STATE";        CFG="#8be9fd";;
esac

# --- decode the exit code. SLURM reports "<code>:<signal>". ---
CODE="${EXITCODE%%:*}"; SIG="${EXITCODE##*:}"
[[ -z "$CODE" ]] && CODE=0
[[ -z "$SIG"  ]] && SIG=0

signal_name() {
  case "$1" in
    1)  echo "SIGHUP (hangup)";;
    2)  echo "SIGINT (interrupted)";;
    3)  echo "SIGQUIT (quit)";;
    4)  echo "SIGILL (illegal instruction)";;
    6)  echo "SIGABRT (aborted)";;
    8)  echo "SIGFPE (arithmetic error, e.g. divide-by-zero)";;
    9)  echo "SIGKILL (forcibly killed)";;
    11) echo "SIGSEGV (segmentation fault - invalid memory access)";;
    13) echo "SIGPIPE (broken pipe)";;
    15) echo "SIGTERM (termination requested)";;
    24) echo "SIGXCPU (CPU time limit exceeded)";;
    25) echo "SIGXFSZ (file size limit exceeded)";;
    *)  echo "signal $1";;
  esac
}

# Explain the exit code. Standard codes get a specific note; signal-coded codes
# (128+N) are decoded; everything else is correctly described as application-defined.
code_reference() {
  [[ "$CODE" == "0" ]] && return
  case "$CODE" in
    1)   echo "Exit 1 is a generic 'something went wrong' error.";;
    2)   echo "Exit 2 conventionally means misuse of a command (bad arguments or usage).";;
    126) echo "Exit 126: a command was found but could not be executed (permissions / not executable).";;
    127) echo "Exit 127: 'command not found' - check module loads and PATH in your script.";;
    128) echo "Exit 128: an invalid argument was passed to exit().";;
    130) echo "Exit 130 = 128+2: terminated by SIGINT (Ctrl-C).";;
    132) echo "Exit 132 = 128+4: illegal instruction (SIGILL).";;
    134) echo "Exit 134 = 128+6: aborted (SIGABRT), often a failed assertion.";;
    136) echo "Exit 136 = 128+8: arithmetic error such as divide-by-zero (SIGFPE).";;
    137) echo "Exit 137 = 128+9: killed by SIGKILL - usually an out-of-memory or walltime kill.";;
    139) echo "Exit 139 = 128+11: segmentation fault (invalid memory access).";;
    143) echo "Exit 143 = 128+15: terminated by SIGTERM.";;
    255) echo "Exit 255 usually means the program returned -1 or a status outside 0-255.";;
    *)
      if [[ "$CODE" =~ ^[0-9]+$ && "$CODE" -gt 128 && "$CODE" -le 192 ]]; then
        echo "Exit $CODE = 128+$((CODE-128)): the program was killed by $(signal_name $((CODE-128)))."
      else
        echo "Exit code $CODE is application-defined - it is chosen by the program itself, not a"
        echo "standard system code, so its meaning depends on this program. Check the program's"
        echo "own output/log (see the tail below) or its documentation for what status $CODE means."
        echo "(Standard codes: 0=success, 1=general error, 2=usage, 126/127=exec problems,"
        echo "128+N=killed by signal N.)"
      fi;;
  esac
}

# Plain-English explanation of the outcome.
explain() {
  case "$STATE" in
    COMPLETED*)      echo "Job finished successfully (exit code 0).";;
    FAILED*)         echo "Job failed: the program exited with non-zero status $CODE.";;
    TIMEOUT*)        echo "Job hit its wall-clock time limit (--time) and was killed by SLURM.";;
    OUT_OF_MEMORY*)  echo "Job ran out of memory: it exceeded its --mem allocation and was killed (OOM).";;
    CANCELLED*)      echo "Job was cancelled (e.g. via scancel, by you or an administrator).";;
    NODE_FAIL*)      echo "The compute node running the job failed.";;
    *)               echo "Job ended in state: $STATE.";;
  esac
  if [[ "$SIG" =~ ^[0-9]+$ && "$SIG" -ge 1 && "$SIG" -le 31 ]]; then
    echo "Terminated by $(signal_name "$SIG")."
  fi
  code_reference
}

# A short, actionable next step (omitted on success).
next_step() {
  case "$STATE" in
    COMPLETED*)      return;;
    TIMEOUT*)        echo "Next: raise --time, or split/optimize the job so it finishes sooner.";;
    OUT_OF_MEMORY*)  echo "Next: raise --mem (requested ${REQMEM:-?}; peak usage ${MEM_USED:-n/a}).";;
    NODE_FAIL*)      echo "Next: resubmit - this was a hardware/node fault, not your job.";;
    CANCELLED*)      echo "Next: resubmit if the cancellation was not intentional.";;
    *) if [[ "$SIG" == "11" || "$CODE" == "139" ]]; then
         echo "Next: debug the crash (rebuild with -g and run under gdb/valgrind); see the log tail below."
       elif [[ "$CODE" == "127" ]]; then
         echo "Next: a command was not found - check module loads / PATH in your script."
       else
         echo "Next: check the stderr/stdout tail below for the error."
       fi;;
  esac
}

# --- resource efficiency (computed from sacct; seff is not installed on ada) ---
to_seconds() { # [DD-]HH:MM:SS[.fff] | MM:SS | SS  ->  integer seconds
  local t="${1:-}" d=0 hms a b c
  [[ "$t" =~ ^[0-9][0-9.:-]*$ ]] || { echo 0; return; }   # non-time input -> 0
  if [[ "$t" == *-* ]]; then d="${t%%-*}"; hms="${t#*-}"; else hms="$t"; fi
  hms="${hms%%.*}"
  IFS=':' read -r a b c <<<"$hms"
  if   [[ -n "$c" ]]; then echo $(( 10#${d:-0}*86400 + 10#${a:-0}*3600 + 10#${b:-0}*60 + 10#${c:-0} ))
  elif [[ -n "$b" ]]; then echo $(( 10#${d:-0}*86400 + 10#${a:-0}*60 + 10#${b:-0} ))
  else                     echo $(( 10#${d:-0}*86400 + 10#${a:-0} )); fi
}
to_mb() { # 1234K | 128M | 4G | 2T | bare-bytes (strip per-node/cpu n/c suffix) -> MB
  local v="${1:-}"; [[ -z "$v" || "$v" == "0" ]] && { echo 0; return; }
  v="${v%[nc]}"
  awk -v v="$v" 'BEGIN{
    u=substr(v,length(v),1); n=v+0;
    if(u=="K"||u=="k") printf "%.0f", n/1024;
    else if(u=="M"||u=="m") printf "%.0f", n;
    else if(u=="G"||u=="g") printf "%.0f", n*1024;
    else if(u=="T"||u=="t") printf "%.0f", n*1024*1024;
    else printf "%.0f", n/1048576;
  }'
}
ELAPSED_S=$(to_seconds "$ELAPSED")
TOTALCPU_S=$(to_seconds "$TOTALCPU")
CPU_EFF=$(awk -v t="$TOTALCPU_S" -v a="${ALLOCCPUS:-0}" -v e="$ELAPSED_S" \
  'BEGIN{ if(a>0 && e>0) printf "%.0f%%", 100*t/(a*e); else printf "n/a" }')
MAXRSS_MB=$(to_mb "$MAXRSS"); REQMEM_MB=$(to_mb "$REQMEM")
MEM_EFF=$(awk -v m="$MAXRSS_MB" -v r="$REQMEM_MB" \
  'BEGIN{ if(r>0) printf "%.0f%%", 100*m/r; else printf "n/a" }')
# sacct only records MaxRSS once it has sampled the job; very short jobs report none.
if [[ -n "$MAXRSS" && "$MAXRSS" != "0" ]]; then MEM_USED="$MAXRSS"; else MEM_USED="n/a"; MEM_EFF="n/a"; fi

# --- log tails ---
log_block() { # label path
  local label="$1" path="$2"
  [[ -z "$path" ]] && return
  if [[ ! -e "$path" ]]; then printf '%s (%s): file not found\n\n' "$label" "$path"; return; fi
  [[ ! -s "$path" ]] && return   # skip empty files
  printf '%s (last %s lines of %s):\n' "$label" "$LOG_TAIL_LINES" "$path"
  tail -n "$LOG_TAIL_LINES" "$path" | sed 's/^/    /'
  printf '\n'
}
STDOUT_BLOCK="$(log_block "stdout" "$STDOUT")"
STDERR_BLOCK=""
if [[ -n "$STDERR" && "$STDERR" != "$STDOUT" ]]; then
  STDERR_BLOCK="$(log_block "stderr" "$STDERR")"
fi

EXPLAIN_RAW="$(explain)"
NEXT_RAW="$(next_step)"
EXPLANATION="$(printf '%s' "$EXPLAIN_RAW" | sed 's/^/  /')"

# Show the signal only when it is a real signal number (1-31); SLURM uses out-of-range
# values like 125 internally (e.g. for OOM), which would otherwise be confusing.
if [[ "$SIG" =~ ^[0-9]+$ && "$SIG" -ge 1 && "$SIG" -le 31 ]]; then
  EXITINFO="exit code $CODE, signal $SIG"
else
  EXITINFO="exit code $CODE"
fi

# ===================== plain-text part =====================
TEXT_BODY="$(cat <<EOF
Job:        $JOBNAME ($JOBID)
Result:     $VERDICT  ($EXITINFO)

Explanation:
$EXPLANATION
$( [[ -n "$NEXT_RAW" ]] && printf '\nNext step:\n  %s\n' "$NEXT_RAW" )
Timing:
  Submitted:  $SUBMIT
  Started:    $START
  Ended:      $END
  Queue wait: $QUEUED
  Elapsed:    $ELAPSED

Resources:
  CPUs:       ${ALLOCCPUS:-?}
  CPU time:   ${TOTALCPU:-?}  (efficiency $CPU_EFF)
  Memory:     $MEM_USED used of ${REQMEM:-?} requested  ($MEM_EFF)

Placement:
  Partition:  $PART
  Node(s):    $NODELIST
  Workdir:    $WORKDIR

Submit:     $SUBMIT_CMD

$STDOUT_BLOCK$STDERR_BLOCK-- slurmailer
EOF
)"

# ===================== HTML part (retro CRT terminal) =====================
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
esc() { printf '%s' "${1:-}" | html_escape; }                       # escape a scalar
hesc() { printf '%s' "${1:-}" | html_escape; }                      # escape multi-line block
kv()  { printf '  %-10s %s\n' "$1" "$2"; }                          # aligned key/value line
sec() { printf '\n<span style="color:#3f8f5a">--[ %s ]----------------------------------------</span>\n' "$1"; }

# Raw log tails (shared by text + HTML).
STDOUT_TAIL="$([[ -n "$STDOUT" && -s "$STDOUT" ]] && tail -n "$LOG_TAIL_LINES" "$STDOUT")"
STDERR_TAIL=""
[[ -n "$STDERR" && "$STDERR" != "$STDOUT" && -s "$STDERR" ]] && STDERR_TAIL="$(tail -n "$LOG_TAIL_LINES" "$STDERR")"

BANNER="================================================================
   S L U R M A I L E R     ::     JOB $VERDICT
================================================================"

# Terminal body: one <pre>; spans colour the banner, status, sections, next-step.
PRE="$(
  printf '<span style="color:%s;font-weight:bold">%s</span>\n\n' "$CFG" "$(esc "$BANNER")"
  kv 'job'    "$(esc "$JOBNAME")  ($JOBID)"
  kv 'result' "<span style=\"color:$CFG;font-weight:bold\">$(esc "$VERDICT")</span>  [$(esc "$EXITINFO")]"
  sec 'explanation'
  printf '%s\n' "$(hesc "$EXPLAIN_RAW")"
  if [[ -n "$NEXT_RAW" ]]; then
    sec 'next step'
    printf '<span style="color:#ffbd2e">%s</span>\n' "$(hesc "$NEXT_RAW")"
  fi
  sec 'timing'
  kv 'submitted' "$(esc "$SUBMIT")"
  kv 'started'   "$(esc "$START")"
  kv 'ended'     "$(esc "$END")"
  kv 'queue'     "$(esc "$QUEUED")"
  kv 'elapsed'   "$(esc "$ELAPSED")"
  sec 'resources'
  kv 'cpus'     "$(esc "${ALLOCCPUS:-?}")"
  kv 'cpu-time' "$(esc "${TOTALCPU:-?}")  (eff $(esc "$CPU_EFF"))"
  kv 'memory'   "$(esc "$MEM_USED") / $(esc "${REQMEM:-?}")  ($(esc "$MEM_EFF"))"
  sec 'placement'
  kv 'partition' "$(esc "$PART")"
  kv 'node(s)'   "$(esc "$NODELIST")"
  kv 'workdir'   "$(esc "$WORKDIR")"
  sec 'submit'
  printf '  %s\n' "$(esc "$SUBMIT_CMD")"
  [[ -n "$STDOUT_TAIL" ]] && { sec "stdout :: $(esc "$STDOUT")"; printf '%s\n' "$(hesc "$STDOUT_TAIL")"; }
  [[ -n "$STDERR_TAIL" ]] && { sec "stderr :: $(esc "$STDERR")"; printf '%s\n' "$(hesc "$STDERR_TAIL")"; }
  printf '\n<span style="color:#3f8f5a">pmyjm22@ada:~$</span> _\n'
)"

HTML_BODY="$(cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#000000;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#000000;padding:18px 8px;"><tr><td align="center">
<table width="680" cellpadding="0" cellspacing="0" style="max-width:680px;width:100%;background:#05080a;border:1px solid #1f5d2f;box-shadow:0 0 18px rgba(43,255,136,.18);">
  <tr><td style="background:#0c140c;border-bottom:1px solid #1f5d2f;padding:7px 12px;font-family:'Courier New',monospace;font-size:12px;color:#7CFC9B;">
    pmyjm22@ada :: slurmailer
  </td></tr>
  <tr><td style="padding:14px 16px 18px;">
    <pre style="margin:0;font-family:'Courier New',Courier,monospace;font-size:13px;line-height:1.5;color:#79e6a4;text-shadow:0 0 1px rgba(121,230,164,.45);white-space:pre-wrap;word-break:break-word;">$PRE</pre>
  </td></tr>
</table>
</td></tr></table>
</body></html>
EOF
)"

# ===================== send as multipart/alternative =====================
SUBJECT="[ada] [$TAG] $JOBNAME ($JOBID) - $ELAPSED"
send_mail() {
  if ! command -v sendmail >/dev/null 2>&1; then
    # Fallback: plain text only (loses HTML), still delivers.
    printf '%s\n' "$TEXT_BODY" | mail -s "[ada] $JOBNAME ($JOBID) $TAG - $ELAPSED" "$EMAIL"
    return
  fi
  local boundary="==slurmailer_${JOBID}_${RANDOM}=="
  local subj_enc="=?UTF-8?B?$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')?="
  {
    printf 'To: %s\n' "$EMAIL"
    printf 'From: %s\n' "$FROM"
    printf 'Subject: %s\n' "$subj_enc"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$boundary"
    printf -- '--%s\n' "$boundary"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n\n%s\n\n' "$TEXT_BODY"
    printf -- '--%s\n' "$boundary"
    printf 'Content-Type: text/html; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n\n%s\n\n' "$HTML_BODY"
    printf -- '--%s--\n' "$boundary"
  } | sendmail -t
}

send_mail
echo "notifier: sent '$SUBJECT' to $EMAIL (job $JOBID state=$STATE)"

# Echo the composed parts to this notifier's own log for debugging/audit.
printf '\n----- text body -----\n%s\n\n----- html body -----\n%s\n' "$TEXT_BODY" "$HTML_BODY"
