# slurmailer

Get a detailed email when a SLURM job finishes on the **ada** cluster — including
when it fails, times out, is killed, or runs out of memory. The command you run is
`notify-sbatch` (a drop-in for `sbatch`).

Instead of `sbatch myjob.sbatch`, run:

```
notify-sbatch myjob.sbatch
```

It submits your job normally (all `sbatch` flags pass through) **plus** a tiny
dependent job that runs after yours ends, gathers its stats, and emails a report to
the address in `config.sh`.

## How it works

1. `notify-sbatch` submits your job and records its resolved stdout/stderr/workdir.
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
- `LOG_TAIL_LINES` — trailing log lines to include
- `NOTIFIER_PARTITION` / `NOTIFIER_TIME` / `NOTIFIER_MEM` — notifier job resources
- `SLURM_BIN` — path to the SLURM binaries

## Status

- **Session 1:** core-stats plain-text email, end-to-end pipeline. ← current
- **Session 2:** full rich HTML email (timing, resource usage, CPU efficiency, log
  tails) — see the design plan.
