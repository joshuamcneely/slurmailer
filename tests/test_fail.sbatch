#!/bin/bash
# A tiny failing job for testing slurmailer's exit-code explanation.
# Run with: cd ~/slurmailer/tests && slurmailer test_fail.sbatch
#SBATCH --job-name=slurmailer_test_fail
#SBATCH --partition=shortq
#SBATCH --qos=costed
#SBATCH --time=00:02:00
#SBATCH --ntasks=1
#SBATCH --mem=128M
#SBATCH --output=%x-%j.out
echo "this job fails on purpose"
sleep 5
exit 3
