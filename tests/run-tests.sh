#!/bin/bash
# slurmailer test suite: syntax checks + unit tests for the pure helpers in lib.sh.
# Runs anywhere (no SLURM required):  bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()   { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1: [$2] missing [$3]"; fi; }
empty(){ if [[ -z "$2" ]]; then ok; else bad "$1: expected empty, got [$2]"; fi; }

echo "== syntax checks =="
for f in slurmailer notifier.sbatch lib.sh config.sh \
         tests/test_ok.sbatch tests/test_fail.sbatch tests/test_oom.sbatch; do
  if bash -n "$ROOT/$f" 2>/dev/null; then ok; else bad "bash -n $f"; fi
done

echo "== to_seconds =="
eq "ss"        45      "$(to_seconds 45)"
eq "mm:ss"     123     "$(to_seconds 02:03)"
eq "hh:mm:ss"  21      "$(to_seconds 00:00:21)"
eq "dd-hh:..." 93784   "$(to_seconds 1-02:03:04)"
eq "frac"      123     "$(to_seconds 00:02:03.500)"
eq "unknown"   0       "$(to_seconds unknown)"
eq "empty"     0       "$(to_seconds '')"
eq "INVALID"   0       "$(to_seconds INVALID)"

echo "== to_mb =="
eq "K"   1       "$(to_mb 1024K)"
eq "M"   128     "$(to_mb 128M)"
eq "G"   4096    "$(to_mb 4G)"
eq "T"   2097152 "$(to_mb 2T)"
eq "n-suffix" 256 "$(to_mb 256Mn)"
eq "zero" 0      "$(to_mb 0)"
eq "empty-mb" 0  "$(to_mb '')"

echo "== signal_name =="
has "sig9"  "$(signal_name 9)"  "SIGKILL"
has "sig11" "$(signal_name 11)" "SIGSEGV"
has "sig99" "$(signal_name 99)" "signal 99"

echo "== verdict =="
verdict COMPLETED;            eq "v-ok-tag" OK "$TAG";  eq "v-ok-verdict" COMPLETED "$VERDICT"
verdict "CANCELLED by 42";    eq "v-cancel" CANCELLED "$TAG"
verdict OUT_OF_MEMORY;        eq "v-oom" OOM "$TAG"
verdict WEIRD_STATE;          eq "v-unknown" WEIRD_STATE "$TAG"

echo "== code_reference =="
CODE=0;   empty "code0" "$(code_reference)"
CODE=3;   has "code3"   "$(code_reference)" "application-defined"
CODE=127; has "code127" "$(code_reference)" "command not found"
CODE=137; has "code137" "$(code_reference)" "SIGKILL"
CODE=152; has "code152" "$(code_reference)" "128+24"
CODE=255; has "code255" "$(code_reference)" "-1"

echo "== explain =="
STATE=COMPLETED;     CODE=0; SIG=0;  has "ex-ok"   "$(explain)" "finished successfully"
STATE=FAILED;        CODE=3; SIG=0;  has "ex-fail" "$(explain)" "non-zero status 3"
STATE=FAILED;        CODE=3; SIG=0;  has "ex-fail-ref" "$(explain)" "application-defined"
STATE=OUT_OF_MEMORY; CODE=0; SIG=9;  has "ex-oom"  "$(explain)" "ran out of memory"
STATE=OUT_OF_MEMORY; CODE=0; SIG=9;  has "ex-sig"  "$(explain)" "Terminated by SIGKILL"
STATE=OUT_OF_MEMORY; CODE=0; SIG=125; ! grep -q "signal 125" <<<"$(explain)" && ok || bad "ex-sig125 leaked"

echo "== next_step =="
STATE=COMPLETED;     empty "ns-ok" "$(next_step)"
STATE=TIMEOUT;       has "ns-time" "$(next_step)" "raise --time"
REQMEM=100M; MEM_USED=n/a; STATE=OUT_OF_MEMORY; has "ns-oom" "$(next_step)" "raise --mem"
STATE=FAILED; CODE=127; SIG=0; has "ns-127" "$(next_step)" "command was not found"
STATE=FAILED; CODE=139; SIG=11; has "ns-crash" "$(next_step)" "debug the crash"

echo "== html escaping =="
eq "esc" "&lt;a&gt; &amp; 'b'" "$(esc "<a> & 'b'")"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
