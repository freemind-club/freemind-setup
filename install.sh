#!/usr/bin/env bash
# freemind-setup — единая точка входа для установки стека FreeMind (VPN, Hermes, ...)
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s vpn
#   curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s hermes
set -euo pipefail

REPO_RAW="${FREEMIND_SETUP_RAW:-https://raw.githubusercontent.com/freemind-club/freemind-setup/main}"
MODULE="${1:-}"

VALID_MODULES="vpn hermes omniroute mozg telegram keys"

if [ -z "$MODULE" ]; then
    echo "Использование: curl -fsSL <URL>/install.sh | bash -s <модуль>"
    echo "Доступные модули: $VALID_MODULES"
    exit 1
fi

if ! echo " $VALID_MODULES " | grep -q " $MODULE "; then
    echo "Неизвестный модуль: $MODULE"
    echo "Доступные модули: $VALID_MODULES"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root. Запусти под root или через sudo."
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fetch() {
    # $1 = путь относительно корня репозитория, $2 = куда сохранить
    curl -fsSL "$REPO_RAW/$1" -o "$2" || {
        echo "Не удалось скачать $1 — проверь интернет или что repo доступен."
        exit 1
    }
}

fetch "lib/common.sh" "$TMP_DIR/common.sh"
fetch "modules/$MODULE.sh" "$TMP_DIR/$MODULE.sh"

# shellcheck source=/dev/null
source "$TMP_DIR/common.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/$MODULE.sh"

run_module
