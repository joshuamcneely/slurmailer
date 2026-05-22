#!/bin/bash
# notifier.sbatch: dependent job submitted by notify-sbatch. Runs on a compute node
# after the watched job ends, gathers stats, and emails a report.
# Resources/partition/dependency are set by notify-sbatch at submit time.
#SBATCH --job-name=notifier
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"
export PATH="$SLURM_BIN:$PATH"

# --- parse args passed by notify-sbatch ---
JOBID="" ; STDOUT="" ; STDERR="" ; WORKDIR="" ; SUBMIT_CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobid)   JOBID="$2";   shift 2;;
    --stdout)  STDOUT="$2";  shift 2;;
    --stderr)  STDERR="$2";  shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --submit)  SUBMIT_CMD="$2"; shift 2;;
    *) shift;;
  esac
done

# --- gather core stats (retry: slurmdbd can lag a moment after the job ends) ---
LINE=""
for _ in 1 2 3 4 5; do
  LINE=$(sacct -j "$JOBID" -X --noheader --parsable2 \
    --format=JobName,State,ExitCode,Elapsed,Partition,NodeList | head -1)
  [[ -n "$LINE" ]] && break
  sleep 3
done
IFS='|' read -r JOBNAME STATE EXITCODE ELAPSED PART NODELIST <<<"$LINE"
[[ -z "$JOBNAME" ]] && JOBNAME="job"
[[ -z "$ELAPSED" ]] && ELAPSED="unknown"

# --- verdict (ASCII for Session 1; Session 2 adds MIME-encoded glyphs + HTML) ---
case "$STATE" in
  COMPLETED*)      TAG="OK";        VERDICT="COMPLETED";;
  FAILED*)         TAG="FAILED";    VERDICT="FAILED";;
  TIMEOUT*)        TAG="TIMEOUT";   VERDICT="TIMEOUT";;
  OUT_OF_MEMORY*)  TAG="OOM";       VERDICT="OUT OF MEMORY";;
  CANCELLED*)      TAG="CANCELLED"; VERDICT="$STATE";;
  NODE_FAIL*)      TAG="NODE_FAIL"; VERDICT="NODE FAILURE";;
  *)               TAG="$STATE";    VERDICT="$STATE";;
esac

SUBJECT="[ada] $JOBNAME ($JOBID) $TAG - $ELAPSED"
BODY="$(cat <<EOF
Job:        $JOBNAME ($JOBID)
Result:     $VERDICT  (exit $EXITCODE)
Elapsed:    $ELAPSED
Partition:  $PART
Node(s):    $NODELIST
Workdir:    $WORKDIR
Submit:     $SUBMIT_CMD

-- notify-sbatch
EOF
)"

# --- send (prefer sendmail; fall back to mail). Finalized per compute-node probe. ---
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
