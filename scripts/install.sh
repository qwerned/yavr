#!/bin/zsh
# Build, validate, update, and launch YAVR.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh "${1:-release}"
# YAVR_NO_BACKUP=1 — без резервной копии настроек в dist/backups.
python3 scripts/install-app.py dist/YAVR.app ${YAVR_NO_BACKUP:+--no-backup}
