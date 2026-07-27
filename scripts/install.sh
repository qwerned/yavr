#!/bin/zsh
# Сборка + установка в /Applications/YAVR.app + перезапуск.
# Трогает только собственный бандл: ничего чужого из /Applications не удаляет.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="/Applications/YAVR.app"

./scripts/make-app.sh "${1:-release}"

# Останавливаем только свой процесс — по полному пути к исполняемому файлу,
# чтобы не задеть одноимённые программы других разработчиков.
for pid in $(pgrep -x YAVR 2>/dev/null); do
    path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$path" in
        */YAVR.app/Contents/MacOS/YAVR) kill "$pid" 2>/dev/null || true ;;
    esac
done
sleep 1

# Перезаписываем только то, что раньше поставил этот же скрипт.
if [[ -e "$TARGET" ]]; then
    existing_id="$(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"
    # com.yavr.vox — id ранних сборок этого же проекта (до переименования).
    if [[ "$existing_id" != "com.yavr.yavr" && "$existing_id" != "com.yavr.vox" ]]; then
        echo "В $TARGET лежит чужое приложение (bundle id: ${existing_id:-неизвестен})."
        echo "Установка отменена — уберите или переименуйте его вручную."
        exit 1
    fi
    rm -rf "$TARGET"
fi

cp -R dist/YAVR.app "$TARGET"
open "$TARGET"
echo "Установлено и запущено: $TARGET"
echo "При первом запуске macOS спросит доступ к микрофону и Универсальному доступу."
