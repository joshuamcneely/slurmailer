# slurmailer shared helpers, sourced by notifier.sbatch and tests/run-tests.sh.
# These are pure functions (no SLURM/IO calls) so they can be unit-tested in isolation.
# A few read caller globals (STATE, CODE, SIG, REQMEM, MEM_USED) instead of taking
# arguments; that is noted on each.

# verdict <state> -> sets TAG (ASCII), VERDICT (display), CFG (HTML accent colour).
verdict() {
  case "$1" in
    COMPLETED*)      TAG="OK";        VERDICT="COMPLETED";     CFG="#3dff8a";;
    FAILED*)         TAG="FAILED";    VERDICT="FAILED";        CFG="#ff5f56";;
    TIMEOUT*)        TAG="TIMEOUT";   VERDICT="TIMED OUT";     CFG="#ffbd2e";;
    OUT_OF_MEMORY*)  TAG="OOM";       VERDICT="OUT OF MEMORY"; CFG="#ff5f56";;
    CANCELLED*)      TAG="CANCELLED"; VERDICT="CANCELLED";     CFG="#ffbd2e";;
    NODE_FAIL*)      TAG="NODE_FAIL"; VERDICT="NODE FAILURE";  CFG="#ff5f56";;
    *)               TAG="$1";        VERDICT="$1";            CFG="#8be9fd";;
  esac
}

# signal_name <n> -> human-readable signal name.
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

# code_reference  (reads $CODE) -> explains the exit code; nothing for 0.
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

# explain  (reads $STATE, $CODE, $SIG) -> plain-English outcome + signal + code note.
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

# next_step  (reads $STATE, $SIG, $CODE, $REQMEM, $MEM_USED) -> suggestion; empty on success.
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

# to_seconds <[DD-]HH:MM:SS[.fff] | MM:SS | SS> -> integer seconds (non-time -> 0).
to_seconds() {
  local t="${1:-}" d=0 hms a b c
  [[ "$t" =~ ^[0-9][0-9.:-]*$ ]] || { echo 0; return; }
  if [[ "$t" == *-* ]]; then d="${t%%-*}"; hms="${t#*-}"; else hms="$t"; fi
  hms="${hms%%.*}"
  IFS=':' read -r a b c <<<"$hms"
  if   [[ -n "$c" ]]; then echo $(( 10#${d:-0}*86400 + 10#${a:-0}*3600 + 10#${b:-0}*60 + 10#${c:-0} ))
  elif [[ -n "$b" ]]; then echo $(( 10#${d:-0}*86400 + 10#${a:-0}*60 + 10#${b:-0} ))
  else                     echo $(( 10#${d:-0}*86400 + 10#${a:-0} )); fi
}

# to_mb <1234K|128M|4G|2T|bytes> -> whole megabytes (strips per-node/cpu n/c suffix).
to_mb() {
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

# HTML helpers.
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
esc() { printf '%s' "${1:-}" | html_escape; }                       # escape (scalar or multi-line)
kv()  { printf '  %-10s %s\n' "$1" "$2"; }                          # aligned key/value line
sec() { printf '\n<span style="color:#3f8f5a">--[ %s ]----------------------------------------</span>\n' "$1"; }
