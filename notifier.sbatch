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

# --- verdict (ASCII for now; HTML/glyphs are a later polish) ---
case "$STATE" in
  COMPLETED*)      TAG="OK";        VERDICT="COMPLETED";;
  FAILED*)         TAG="FAILED";    VERDICT="FAILED";;
  TIMEOUT*)        TAG="TIMEOUT";   VERDICT="TIMEOUT";;
  OUT_OF_MEMORY*)  TAG="OOM";       VERDICT="OUT OF MEMORY";;
  CANCELLED*)      TAG="CANCELLED"; VERDICT="$STATE";;
  NODE_FAIL*)      TAG="NODE_FAIL"; VERDICT="NODE FAILURE";;
  *)               TAG="$STATE";    VERDICT="$STATE";;
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

# Reference note for common coded exit statuses (only shown for non-zero codes).
code_reference() {
  case "$CODE" in
    1)   echo "Exit 1 is a generic error (the program reported failure).";;
    2)   echo "Exit 2 often means misuse of a shell builtin or bad arguments.";;
    126) echo "Exit 126 means a command was found but is not executable (permissions).";;
    127) echo "Exit 127 means 'command not found' - check module loads and PATH in your script.";;
    128) echo "Exit 128 means an invalid exit argument was used.";;
    130) echo "Exit 130 = 128+2: terminated by SIGINT (Ctrl-C).";;
    137) echo "Exit 137 = 128+9: killed by SIGKILL - usually an out-of-memory or walltime kill.";;
    139) echo "Exit 139 = 128+11: crashed with a segmentation fault.";;
    143) echo "Exit 143 = 128+15: terminated by SIGTERM.";;
    *)   if [[ "$CODE" -gt 128 ]] 2>/dev/null; then
           echo "Exit $CODE = 128+$((CODE-128)): killed by $(signal_name $((CODE-128)))."
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

EXPLANATION="$(explain | sed 's/^/  /')"
NEXT="$(next_step)"

# Show the signal only when it is a real signal number (1-31); SLURM uses out-of-range
# values like 125 internally (e.g. for OOM), which would otherwise be confusing.
if [[ "$SIG" =~ ^[0-9]+$ && "$SIG" -ge 1 && "$SIG" -le 31 ]]; then
  EXITINFO="exit code $CODE, signal $SIG"
else
  EXITINFO="exit code $CODE"
fi

SUBJECT="[ada] $JOBNAME ($JOBID) $TAG - $ELAPSED"
BODY="$(cat <<EOF
Job:        $JOBNAME ($JOBID)
Result:     $VERDICT  ($EXITINFO)

Explanation:
$EXPLANATION
$( [[ -n "$NEXT" ]] && printf '\nNext step:\n  %s\n' "$NEXT" )
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

# --- send (prefer sendmail; fall back to mail). Both verified to deliver from ada. ---
send_mail() {
  local subject="$1" body="$2"
  if command -v sendmail >/dev/null 2>&1; then
    sendmail -t <<MAIL
To: $EMAIL
Subject: $subject
From: ${USER:-pmyjm22}@nottingham.ac.uk

$body
MAIL
  else
    printf '%s\n' "$body" | mail -s "$subject" "$EMAIL"
  fi
}

send_mail "$SUBJECT" "$BODY"
echo "notifier: sent '$SUBJECT' to $EMAIL (job $JOBID state=$STATE)"

# Echo the composed message to this notifier's own log for debugging/audit.
printf '\n----- email body -----\n%s\n' "$BODY"
