#!/bin/bash
# notifier.sbatch: dependent job submitted by slurmailer. Runs on a compute node
# after the watched job ends, gathers stats, and emails a detailed report.
# Resources/partition/dependency are set by slurmailer at submit time.
#SBATCH --job-name=notifier
set -uo pipefail

# Parse args FIRST. SLURM runs this from a private spool dir, so config.sh and lib.sh
# are located via the install dir slurmailer passes as --confdir.
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
# shellcheck source=lib.sh
source "$CONFDIR/lib.sh"
[[ -n "${SLURM_BIN:-}" ]] && export PATH="$SLURM_BIN:$PATH"

# Cluster label (config override -> SLURM's cluster name -> generic) and user@cluster,
# used in the subject and the terminal header/prompt. Never hardcode a site here.
CLUSTER="${CLUSTER_LABEL:-${SLURM_CLUSTER_NAME:-cluster}}"
WHO="${USER:-user}@$CLUSTER"
WHO_ESC="$(esc "$WHO")"

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

# --- verdict + exit code (SLURM reports ExitCode as "<code>:<signal>") ---
verdict "$STATE"                      # sets TAG, VERDICT, CFG
CODE="${EXITCODE%%:*}"; SIG="${EXITCODE##*:}"
[[ -z "$CODE" ]] && CODE=0
[[ -z "$SIG"  ]] && SIG=0

# --- resource efficiency (computed from sacct; seff is not installed on ada) ---
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
log_block() { # label path -> plain-text block (for the text part)
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
  printf '%s\n' "$(esc "$EXPLAIN_RAW")"
  if [[ -n "$NEXT_RAW" ]]; then
    sec 'next step'
    printf '<span style="color:#ffbd2e">%s</span>\n' "$(esc "$NEXT_RAW")"
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
  [[ -n "$STDOUT_TAIL" ]] && { sec "stdout :: $(esc "$STDOUT")"; printf '%s\n' "$(esc "$STDOUT_TAIL")"; }
  [[ -n "$STDERR_TAIL" ]] && { sec "stderr :: $(esc "$STDERR")"; printf '%s\n' "$(esc "$STDERR_TAIL")"; }
  printf '\n<span style="color:#3f8f5a">%s:~$</span> _\n' "$WHO_ESC"
)"

HTML_BODY="$(cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#000000;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#000000;padding:18px 8px;"><tr><td align="center">
<table width="680" cellpadding="0" cellspacing="0" style="max-width:680px;width:100%;background:#05080a;border:1px solid #1f5d2f;box-shadow:0 0 18px rgba(43,255,136,.18);">
  <tr><td style="background:#0c140c;border-bottom:1px solid #1f5d2f;padding:7px 12px;font-family:'Courier New',monospace;font-size:12px;color:#7CFC9B;">
    $WHO_ESC :: slurmailer
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
# Bodies are base64-encoded so arbitrary program output (very long lines, 8-bit bytes)
# can never break MIME line-length or transfer-encoding assumptions.
SUBJECT="[$CLUSTER] [$TAG] $JOBNAME ($JOBID) - $ELAPSED"
send_mail() {
  if ! command -v sendmail >/dev/null 2>&1; then
    # Fallback: plain text only (loses HTML), still delivers.
    printf '%s\n' "$TEXT_BODY" | mail -s "[$CLUSTER] $JOBNAME ($JOBID) $TAG - $ELAPSED" "$EMAIL"
    return
  fi
  local boundary="==slurmailer_${JOBID}_${RANDOM}=="
  local subj_enc="=?UTF-8?B?$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')?="
  {
    printf 'To: %s\n' "$EMAIL"
    printf 'From: %s\n' "$FROM"
    printf 'Date: %s\n' "$(date -R)"
    printf 'Subject: %s\n' "$subj_enc"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$boundary"
    printf -- '--%s\n' "$boundary"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: base64\n\n'
    printf '%s' "$TEXT_BODY" | base64
    printf -- '\n--%s\n' "$boundary"
    printf 'Content-Type: text/html; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: base64\n\n'
    printf '%s' "$HTML_BODY" | base64
    printf -- '\n--%s--\n' "$boundary"
  } | sendmail -t
}

send_mail
echo "notifier: sent '$SUBJECT' to $EMAIL (job $JOBID state=$STATE)"

# Echo the composed parts to this notifier's own log for debugging/audit.
printf '\n----- text body -----\n%s\n\n----- html body -----\n%s\n' "$TEXT_BODY" "$HTML_BODY"
