#!/bin/bash
#SBATCH -J ft_job
#SBATCH -p gpu
#SBATCH -C gpu80
#SBATCH --gres=gpu:1
#SBATCH --time=16:00:00
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err

set -euo pipefail
mkdir -p logs

cd /users/spandit/projects/artimis/mpp/mpp-spandit-npz-clx

usage() {
  cat <<'EOF'
Usage:
  sbatch finetune_chain.sbatch --list <file.list> --line <N> [--warn-min <M>]

Examples:
  sbatch finetune_chain.sbatch --list run_finetune_final_lsc.list --line 1
  sbatch finetune_chain.sbatch --list run_finetune_final_lsc.list --line 4 --warn-min 45

Notes:
- --line is 1-based, equivalent to: sed -n '<N>p'
- Before walltime, script SIGTERMs training, waits, then resubmits itself with:
    --dependency=afterany:$SLURM_JOB_ID
  so the next job will not start until this one ends.
EOF
}

LIST_FILE=""
LINE_NO=""
WARN_MIN="30"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)     LIST_FILE="${2:-}"; shift 2 ;;
    --line)     LINE_NO="${2:-}"; shift 2 ;;
    --warn-min) WARN_MIN="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "${LIST_FILE}" || -z "${LINE_NO}" ]]; then
  echo "ERROR: --list and --line are required."
  usage
  exit 2
fi
if [[ ! -f "${LIST_FILE}" ]]; then
  echo "ERROR: list file not found: ${LIST_FILE}"
  exit 2
fi
if ! [[ "${LINE_NO}" =~ ^[0-9]+$ ]] || [[ "${LINE_NO}" -lt 1 ]]; then
  echo "ERROR: --line must be a positive integer. Got: ${LINE_NO}"
  exit 2
fi
if ! [[ "${WARN_MIN}" =~ ^[0-9]+$ ]] || [[ "${WARN_MIN}" -lt 1 ]]; then
  echo "ERROR: --warn-min must be a positive integer minutes. Got: ${WARN_MIN}"
  exit 2
fi

# Walltime must match #SBATCH --time above (16h). If you change --time, update this.
WALL_SEC=$(( 16 * 3600 ))
WARN_SEC=$(( WARN_MIN * 60 ))
SLEEP_SEC=$(( WALL_SEC - WARN_SEC ))
if [[ "${SLEEP_SEC}" -lt 60 ]]; then
  echo "ERROR: --warn-min is too close to walltime. Reduce --warn-min or increase --time."
  exit 2
fi

CMD="$(sed -n "${LINE_NO}p" "${LIST_FILE}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "${CMD}" ]]; then
  echo "ERROR: line ${LINE_NO} in ${LIST_FILE} is empty."
  exit 2
fi

TRAIN_PID=""

resubmit_self() {
  echo "[SLURM] Resubmitting next job with dependency afterany:${SLURM_JOB_ID} ..."
  sbatch --dependency=afterany:${SLURM_JOB_ID} "$0" \
    --list "${LIST_FILE}" --line "${LINE_NO}" --warn-min "${WARN_MIN}"
}

handle_usr1 () {
  echo "[SLURM] Warning received: ~${WARN_MIN} minutes remaining. Attempting graceful shutdown..."
  date

  if [[ -n "${TRAIN_PID}" ]] && kill -0 "${TRAIN_PID}" 2>/dev/null; then
    echo "[SLURM] Sending SIGTERM to training PID ${TRAIN_PID}..."
    kill -TERM "${TRAIN_PID}" 2>/dev/null || true
  else
    echo "[SLURM] Training PID not found/already exited."
  fi

  # You said checkpoints can take ~20–25 minutes, so wait up to 25 minutes.
  echo "[SLURM] Waiting up to 1500 seconds (~25 min) for training to exit..."
  timeout 1500 bash -c 'while kill -0 '"${TRAIN_PID:-0}"' 2>/dev/null; do sleep 10; done' || true

  resubmit_self
  echo "[SLURM] Exiting before walltime."
  exit 0
}
trap handle_usr1 USR1

# Runtime-configurable warning timer (since #SBATCH directives can’t use runtime args)
(
  sleep "${SLEEP_SEC}"
  kill -USR1 $$
) &

echo "[INFO] Repo: $(pwd)"
echo "[INFO] List file: ${LIST_FILE}"
echo "[INFO] Line: ${LINE_NO}"
echo "[INFO] Walltime: 16h, warning: ${WARN_MIN} min -> sleep ${SLEEP_SEC}s then USR1"
echo "[INFO] Command:"
echo "       ${CMD}"
date

# Run training in background so we can signal it by PID
set +e
bash -lc "${CMD}" &
TRAIN_PID=$!
set -e

wait "${TRAIN_PID}"
RC=$?

echo "[INFO] Training exited with code ${RC}"
date

# If the job ended on its own (not pre-timeout), we do NOT auto-chain by default.
# If you want to always chain, uncomment:
# resubmit_self

exit "${RC}"

