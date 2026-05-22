# slurmailer configuration  --  sourced by `slurmailer` and `notifier.sbatch`.
# Copy these defaults and edit them for your account and cluster.

# ============================ required ============================

# Where job-done emails are sent (your address).
EMAIL="pmyjm22@nottingham.ac.uk"

# The "From" address on the email. Defaulting to EMAIL (you mail yourself) avoids
# sender-domain rejections. Override only if your site's mail relay needs a
# specific sender address.
FROM="$EMAIL"

# Partition + QOS for the tiny dependent notifier job. Choose a combination your
# account is allowed to submit to.
#
# IMPORTANT: the QOS must NOT have a tight per-user submit limit, because slurmailer
# queues one notifier job per job you submit. (Example: on the ada cluster the "dev"
# QOS caps at 4 submitted jobs/user, which would silently drop notifications during a
# multi-job campaign -- so we use the uncapped "costed" QOS on the short-job partition.)
#
# Leave either one empty ("") to let SLURM use your account default.
NOTIFIER_PARTITION="shortq"
NOTIFIER_QOS="costed"

# ====================== optional (sane defaults) ======================

# Trailing lines of stdout (and stderr, if non-empty) to include in the email.
LOG_TAIL_LINES=50

# Walltime / memory for the notifier job. It only runs `sacct` and sends mail, so
# this is tiny; keep the walltime short so it schedules (and emails you) quickly.
NOTIFIER_TIME="00:05:00"
NOTIFIER_MEM="256M"

# Directory containing the SLURM binaries (sbatch/sacct/scontrol), prepended to PATH
# so they resolve in non-login shells and on compute nodes. Find yours with:
#     dirname "$(command -v sbatch)"
# Leave empty ("") if sacct/scontrol are already on PATH everywhere.
SLURM_BIN="/opt/slurm/23.02.6/bin"
