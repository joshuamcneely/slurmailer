# slurmailer configuration (sourced by slurmailer and notifier.sbatch)

# Where job-done emails are sent.
EMAIL="pmyjm22@nottingham.ac.uk"

# How many trailing lines of the job's stdout/stderr to include in the email.
LOG_TAIL_LINES=50

# Resources for the tiny dependent notifier job.
# Runs on shortq with the default "costed" QOS. NOTE: the notifier QOS must NOT have a
# tight MaxSubmitJobsPerUser, because slurmailer queues one notifier per submitted job.
# The "dev" QOS (devq) caps at 4 submitted jobs/user (verified 2026-05-22), which would
# silently drop notifications during multi-job campaigns; "costed" has no submit cap and
# shortq accepts it. Revisit only if ada's QOS/partition policy changes.
NOTIFIER_PARTITION="shortq"
NOTIFIER_QOS="costed"
NOTIFIER_TIME="00:05:00"
NOTIFIER_MEM="256M"

# SLURM binaries (default loaded module on ada). Ensures sacct/scontrol are on PATH
# inside non-login shells and on compute nodes.
SLURM_BIN="/opt/slurm/23.02.6/bin"
