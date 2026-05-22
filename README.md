# slurmailer

Get a detailed email when a SLURM job finishes on the **ada** cluster — including
when it fails, times out, is killed, or runs out of memory. The command you run is
`slurmailer` (a drop-in for `sbatch`).

Instead of `sbatch myjob.sbatch`, run:

```
slurmailer myjob.sbatch
```

It submits your job normally (all `sbatch` flags pass through) **plus** a tiny
dependent job that runs after yours ends, gathers its stats, and emails a report to
the address in `config.sh`.

## How it works

1. `slurmailer` submits your job and records its resolved stdout/stderr/workdir.
2. It submits a notifier job with `--dependency=afterany:<jobid>`, so the notifier
   runs no matter how your job ends.
3. The notifier (a tiny compute job on `devq`) queries `sacct` and emails you.

No daemon runs and the login node does no sustained work — the notifier executes on a
compute node and exits in seconds.

## Install (on ada)

```
git clone git@github.com:joshuamcneely/slurmailer.git ~/slurmailer
export PATH="$HOME/slurmailer:$PATH"   # add to ~/.bashrc
```

## Configure

Edit `config.sh`:

- `EMAIL` — destination address
- `LOG_TAIL_LINES` — trailing log lines of stdout/stderr to include
- `NOTIFIER_PARTITION` / `NOTIFIER_QOS` / `NOTIFIER_TIME` / `NOTIFIER_MEM` — notifier job resources
- `SLURM_BIN` — path to the SLURM binaries

## What the email includes

- **Result** — state plus a decoded exit code (`code:signal`) and verdict tag
- **Explanation** — plain-English account of what happened (success, non-zero exit,
  timeout, OOM, cancel, node failure), the signal name if killed, and a reference note
  for common coded statuses (127, 137, 139, …)
- **Next step** — a short suggestion for failures (raise `--time`, raise `--mem`, check
  the log, debug a segfault, …)
- **Timing** — submit / start / end, queue wait, elapsed
- **Resources** — CPUs, CPU time and efficiency, memory used vs requested
- **Placement** — partition, node(s), working directory
- **Submit command** and a **log tail** of stdout (and stderr if non-empty)

## Status

Working and verified end-to-end. The email is sent as **multipart/alternative**: a
formatted HTML version (colour-coded header by outcome, tables, dark log-tail block)
with a plain-text fallback for clients that don't render HTML.
