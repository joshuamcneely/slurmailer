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
export PATH="$SLURM_BIN:$PATH"

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

# --- verdict: ASCII tag (subject/text), unicode glyph + colours (HTML header) ---
case "$STATE" in
  COMPLETED*)      TAG="OK";        VERDICT="COMPLETED";     GLYPH="✓"; CBG="#e6f4ea"; CFG="#1a7f37";;
  FAILED*)         TAG="FAILED";    VERDICT="FAILED";        GLYPH="✗"; CBG="#fde8e6"; CFG="#c0392b";;
  TIMEOUT*)        TAG="TIMEOUT";   VERDICT="TIMEOUT";       GLYPH="⏱"; CBG="#fff4e5"; CFG="#b7791f";;
  OUT_OF_MEMORY*)  TAG="OOM";       VERDICT="OUT OF MEMORY"; GLYPH="✗"; CBG="#fde8e6"; CFG="#c0392b";;
  CANCELLED*)      TAG="CANCELLED"; VERDICT="$STATE";        GLYPH="⚠"; CBG="#fff4e5"; CFG="#b7791f";;
  NODE_FAIL*)      TAG="NODE_FAIL"; VERDICT="NODE FAILURE";  GLYPH="✗"; CBG="#fde8e6"; CFG="#c0392b";;
  *)               TAG="$STATE";    VERDICT="$STATE";        GLYPH="•"; CBG="#eef1f4"; CFG="#1f2328";;
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

# ===================== HTML part =====================
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
esc()  { printf '%s' "${1:-}" | html_escape; }                 # escape a scalar
para() { printf '%s' "${1:-}" | html_escape | sed 's#$#<br>#'; } # multi-line -> <br>
row()  { printf '<tr><td style="padding:2px 14px 2px 0;color:#777;vertical-align:top;white-space:nowrap;">%s</td><td style="padding:2px 0;color:#1f2328;">%s</td></tr>' "$1" "$2"; }
log_html() { # label path tail -> html block (empty if no tail)
  local label="$1" path="$2" tail="$3"
  [[ -z "$tail" ]] && return
  printf '<div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.04em;margin:16px 0 4px;">%s</div><div style="font-size:11px;color:#999;margin-bottom:4px;word-break:break-all;">%s</div><pre style="margin:0;padding:10px;background:#0d1117;color:#c9d1d9;border-radius:6px;font-size:12px;line-height:1.45;overflow:auto;white-space:pre-wrap;word-break:break-word;">%s</pre>' \
    "$label" "$(esc "$path")" "$(printf '%s' "$tail" | html_escape)"
}

EXPLAIN_HTML="$(para "$EXPLAIN_RAW")"
NEXT_HTML_BLOCK=""
[[ -n "$NEXT_RAW" ]] && NEXT_HTML_BLOCK="<div style=\"margin-top:12px;padding:10px 12px;background:#fff8e1;border-left:3px solid #f0b400;border-radius:4px;font-size:13px;color:#5f4b00;\">$(para "$NEXT_RAW")</div>"

TIMING_ROWS="$(row Submitted "$(esc "$SUBMIT")"; row Started "$(esc "$START")"; row Ended "$(esc "$END")"; row 'Queue wait' "$(esc "$QUEUED")"; row Elapsed "$(esc "$ELAPSED")")"
RES_ROWS="$(row CPUs "$(esc "${ALLOCCPUS:-?}")"; row 'CPU time' "$(esc "${TOTALCPU:-?}") &nbsp;(efficiency $(esc "$CPU_EFF"))"; row Memory "$(esc "$MEM_USED") used of $(esc "${REQMEM:-?}") requested &nbsp;($(esc "$MEM_EFF"))")"
PLACE_ROWS="$(row Partition "$(esc "$PART")"; row 'Node(s)' "$(esc "$NODELIST")"; row Workdir "$(esc "$WORKDIR")")"

STDOUT_HTML="$(log_html "stdout" "$STDOUT" "$([[ -n "$STDOUT" && -s "$STDOUT" ]] && tail -n "$LOG_TAIL_LINES" "$STDOUT")")"
STDERR_HTML=""
[[ -n "$STDERR" && "$STDERR" != "$STDOUT" ]] && STDERR_HTML="$(log_html "stderr" "$STDERR" "$([[ -s "$STDERR" ]] && tail -n "$LOG_TAIL_LINES" "$STDERR")")"

sec_label='font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.04em;margin:16px 0 4px;'
HTML_BODY="$(cat <<EOF
<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f4f4f5;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:16px 8px;"><tr><td align="center">
<table width="640" cellpadding="0" cellspacing="0" style="max-width:640px;width:100%;background:#ffffff;border:1px solid #e2e2e4;border-radius:8px;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#1f2328;">
  <tr><td style="background:$CBG;border-top-left-radius:8px;border-top-right-radius:8px;padding:16px 20px;border-bottom:1px solid #e2e2e4;">
    <div style="font-size:20px;font-weight:600;color:$CFG;">$GLYPH&nbsp;$(esc "$VERDICT")</div>
    <div style="font-size:13px;color:#555;margin-top:3px;">$(esc "$JOBNAME") &middot; job $JOBID &middot; $(esc "$EXITINFO")</div>
  </td></tr>
  <tr><td style="padding:16px 20px 0;">
    <div style="font-size:14px;line-height:1.5;">$EXPLAIN_HTML</div>
    $NEXT_HTML_BLOCK
  </td></tr>
  <tr><td style="padding:4px 20px 0;">
    <div style="$sec_label">Timing</div><table cellpadding="0" cellspacing="0" style="font-size:13px;">$TIMING_ROWS</table>
    <div style="$sec_label">Resources</div><table cellpadding="0" cellspacing="0" style="font-size:13px;">$RES_ROWS</table>
    <div style="$sec_label">Placement</div><table cellpadding="0" cellspacing="0" style="font-size:13px;">$PLACE_ROWS</table>
  </td></tr>
  <tr><td style="padding:8px 20px 0;">
    <div style="$sec_label">Submit command</div>
    <pre style="margin:0;padding:10px;background:#f6f8fa;border:1px solid #e2e2e4;border-radius:6px;font-size:12px;overflow:auto;white-space:pre-wrap;word-break:break-word;">$(esc "$SUBMIT_CMD")</pre>
  </td></tr>
  <tr><td style="padding:0 20px 8px;">$STDOUT_HTML$STDERR_HTML</td></tr>
  <tr><td style="padding:12px 20px;border-top:1px solid #eee;color:#999;font-size:11px;">sent by slurmailer</td></tr>
</table>
</td></tr></table>
</body></html>
EOF
)"

# ===================== send as multipart/alternative =====================
SUBJECT="[ada] $GLYPH $JOBNAME ($JOBID) $TAG - $ELAPSED"
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
    printf 'From: %s@nottingham.ac.uk\n' "${USER:-pmyjm22}"
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
