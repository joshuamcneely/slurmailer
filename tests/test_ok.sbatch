#!/bin/bash
# A tiny successful job for end-to-end testing of slurmailer.
# Run with: cd ~/slurmailer/tests && slurmailer test_ok.sbatch
#SBATCH --job-name=slurmailer_test_ok
#SBATCH --partition=shortq
#SBATCH --qos=costed
#SBATCH --time=00:02:00
#SBATCH --ntasks=1
#SBATCH --mem=128M
#SBATCH --output=%x-%j.out
echo "slurmailer end-to-end test: hello from $(hostname)"
echo "sleeping 15s to simulate work..."
sleep 15
echo "done at $(date)."
