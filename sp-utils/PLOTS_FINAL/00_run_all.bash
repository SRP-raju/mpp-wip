#!/bin/bash
set -euo pipefail

./01_extract_losses.bash

rm -f combined_losses.csv
python3 02_combine_losses.py

# Don't let verify stop plotting; warn and continue
#if ! python3 03_verify_combines_losses.py; then
#  echo "WARNING: verify failed; continuing to plots anyway"
#fi

#python3 ./04_plot_grid_losses.py
python3 ./04_plot_grid_losses_uniq_EPOCH_SCALES.py

echo "Done. Outputs:"
ls -1 *.png 2>/dev/null || true

