#!/bin/zsh
# Сборка + установка в /Applications + перезапуск.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh "${1:-release}"

kill -9 $(pgrep -x Vox) 2>/dev/null || true
sleep 1
rm -rf /Applications/Vox.app /Applications/YAVR.app
cp -R dist/YAVR.app /Applications/YAVR.app
open /Applications/YAVR.app
echo "Установлено и запущено: /Applications/YAVR.app"
