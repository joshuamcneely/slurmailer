#!/bin/bash
# A job that deliberately exceeds its memory to test slurmailer's OOM reporting.
# Run with: cd ~/slurmailer/tests && slurmailer test_oom.sbatch
#SBATCH --job-name=slurmailer_test_oom
#SBATCH --partition=shortq
#SBATCH --qos=costed
#SBATCH --time=00:02:00
#SBATCH --ntasks=1
#SBATCH --mem=100M
#SBATCH --output=%x-%j.out
echo "allocating memory until the cgroup OOM-kills us (--mem=100M)..."
a=()
i=0
while true; do
  a+=("$(head -c 1048576 /dev/zero | tr '\0' 'x')")   # ~1 MB per element
  i=$((i+1))
  echo "allocated ~${i} MB"
done
