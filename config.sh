# notify-sbatch configuration (sourced by notify-sbatch and notifier.sbatch)

# Where job-done emails are sent.
EMAIL="pmyjm22@nottingham.ac.uk"

# How many trailing lines of the job's stdout/stderr to include (used in Session 2).
LOG_TAIL_LINES=50

# Resources for the tiny dependent notifier job. devq schedules small/short jobs fast,
# but requires the "dev" QOS (the default "costed" QOS is not permitted on devq).
NOTIFIER_PARTITION="devq"
NOTIFIER_QOS="dev"
NOTIFIER_TIME="00:05:00"
NOTIFIER_MEM="256M"

# SLURM binaries (default loaded module on ada). Ensures sacct/scontrol are on PATH
# inside non-login shells and on compute nodes.
SLURM_BIN="/opt/slurm/23.02.6/bin"
