#!/bin/zsh
# Build, validate, update, and launch YAVR.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh "${1:-release}"
python3 scripts/install-app.py dist/YAVR.app
