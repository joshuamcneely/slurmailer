# slurmailer

Get a detailed email when a SLURM job finishes — including when it **fails, times out,
is killed, or runs out of memory**, which is exactly when you most want to know.

Instead of `sbatch myjob.sbatch`, run:

```
slurmailer myjob.sbatch
```

slurmailer submits your job normally (every `sbatch` flag passes straight through) and
*also* queues a tiny dependent job that runs after yours ends, gathers its stats, and
emails you a report. No daemon runs, and the login node does no sustained work — the
report is built on a compute node and sent in seconds.

```
$ slurmailer --time=02:00:00 -J big_run myjob.sbatch
submitted job:  6810234
notifier job:   6810235  (emails you@example.edu when 6810234 ends)
```

## What the email contains

- **Result** — final state and the decoded exit code
- **Explanation** — plain English: success, non-zero exit, timeout, OOM, cancellation,
  node failure; the signal name if it was killed; and a note on what the exit code means
  (every code is explained — standard ones like 127/137/139 specifically, anything else
  flagged as application-defined)
- **Next step** — a suggestion for failures (raise `--time`, raise `--mem`, check the
  log, debug a crash, …)
- **Timing** — submit / start / end, queue wait, elapsed
- **Resources** — CPUs, CPU time and efficiency, memory used vs requested
- **Placement** — partition, node(s), working directory
- **Submit command** and a **log tail** of stdout (and stderr if non-empty)

The email is sent as multipart: a retro terminal-style HTML version with a plain-text
fallback for clients that don't render HTML.

## Requirements

- A **SLURM** cluster you submit jobs to (provides `sbatch`, `sacct`, `scontrol`).
- A QOS/partition your account can submit small jobs to whose **QOS has no tight
  per-user submit limit** (slurmailer queues one notifier per job — see the note in
  `config.sh`).
- The cluster's **compute nodes can send mail** (`sendmail` or `mail`). Most clusters
  that support `#SBATCH --mail-user` also allow this; if unsure, see Troubleshooting.

## Install

```
git clone git@github.com:joshuamcneely/slurmailer.git ~/slurmailer
# put the command on your PATH (add this line to ~/.bashrc to make it permanent):
export PATH="$HOME/slurmailer:$PATH"
```

Then configure it (next section). Verify the command is found:

```
slurmailer            # prints usage
```

## Configure

Edit `~/slurmailer/config.sh`. The settings are documented inline; the ones you must
review are:

| Setting | What it is |
|---|---|
| `EMAIL` | Where notifications are sent (your address). |
| `FROM` | The sender address (defaults to `EMAIL`). |
| `NOTIFIER_PARTITION` | Partition for the notifier job. Leave `""` for your default. |
| `NOTIFIER_QOS` | QOS for the notifier job — **must not have a tight submit cap**. Leave `""` for your default. |
| `SLURM_BIN` | Directory holding `sbatch`/`sacct`/`scontrol`. Find it with `dirname "$(command -v sbatch)"`. Leave `""` if they're already on `PATH`. |

Optional knobs (`LOG_TAIL_LINES`, `NOTIFIER_TIME`, `NOTIFIER_MEM`) have sensible
defaults.

## Usage

```
slurmailer [any sbatch options] <script> [script args]
```

- All `sbatch` options/arguments are forwarded unchanged, so use it exactly like
  `sbatch` (e.g. `slurmailer --partition=gpu -J train run.sbatch`).
- It prints two job IDs: your real job, and the notifier that will email you when the
  real job ends.
- You do **not** need `#SBATCH --mail-*` lines; slurmailer replaces that with a far more
  detailed message (you can keep them if you also want SLURM's own emails).

## How it works

1. `slurmailer` submits your job and reads its resolved stdout/stderr/workdir from
   `scontrol`.
2. It submits a second tiny job with `--dependency=afterany:<jobid>`, so that job runs
   **no matter how yours ends** (success, failure, timeout, OOM, cancellation).
3. That notifier job (on a compute node) queries `sacct`, builds the report, and sends
   it. `--kill-on-invalid-dep=yes` cleans it up if your job can never run.

## Troubleshooting

- **No email arrives.** Check the notifier's own log under `~/slurmailer/logs/` — it
  records the composed message. If it sent but nothing arrived, test whether your
  compute nodes can mail at all:
  ```
  srun --pty bash -c 'echo test | mail -s "node mail test" you@example.edu'
  ```
  If that doesn't arrive, your site blocks compute-node mail; ask your admins, or set
  `FROM` to a sender your relay accepts.
- **The notifier sits PENDING for a long time / is rejected.** Your `NOTIFIER_QOS` or
  `NOTIFIER_PARTITION` may not be one you can use, or the QOS has a submit cap. Pick a
  partition/QOS you normally submit to, or leave them blank for your default.
- **`sacct: command not found` in the notifier log.** Set `SLURM_BIN` in `config.sh`.

## Repository layout

```
slurmailer        # the command you run (a drop-in for sbatch)
notifier.sbatch   # the dependent job that gathers stats and emails
config.sh         # your settings
tests/            # tiny success / failure / OOM jobs for end-to-end testing
```
