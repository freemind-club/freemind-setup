#!/usr/bin/env bash
# freemind-setup/modules/sync.sh — Syncthing: папка проектов «сервер ↔ свой компьютер»
# Подключается через install.sh, использует функции из lib/common.sh
#
# Что делает:
#   1. Ставит Syncthing из официального apt-репозитория (ключ сверяется по отпечатку).
#   2. Создаёт папку проектов (по умолчанию ~/Проекты) и .stignore — секреты и мусор не синхронизируются.
#   3. Запускает службу syncthing@root (24/7) и через `syncthing cli` добавляет папку:
#      в обе стороны, мгновенная реакция на изменения, корзина версий на 30 дней.
#   4. Веб-интерфейс Syncthing — только 127.0.0.1:8384 (снаружи не виден, вход через SSH-тоннель).
#   5. Открывает в ufw порты Syncthing (22000/tcp+udp, 21027/udp).
#   6. (По желанию) сразу добавляет твой компьютер по его ID — тогда тоннель не нужен.
# Повторный запуск безопасен: уже сделанное пропускается, чужие настройки не перезаписываются.
#
# Папку Гермеса ~/.hermes НЕ синхронизируем: там ключи, токен бота и база SQLite,
# которую запись с двух сторон портит.

# Официальный ключ подписи пакетов Syncthing (https://apt.syncthing.net/).
# Отпечаток основного ключа — сверяем автоматически, чтобы не поставить подменённое.
SYNCTHING_KEY_URL="https://syncthing.net/release-key.gpg"
SYNCTHING_KEY_FPR="FBA2E162F2F44657B38F0309E5665F9BD5970C47"
SYNCTHING_KEYRING="/etc/apt/keyrings/syncthing-archive-keyring.gpg"
SYNCTHING_CHANNEL="stable-v2"
SYNC_FOLDER_ID="projects"
SYNC_SERVICE="syncthing@root"

run_module() {
    step "Синхронизация папки проектов (Syncthing) — установка"

    require_root
    unlock_dpkg

    local server_ip
    server_ip="$(curl -fsSL ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

    step "Syncthing"
    install_syncthing

    step "Папка проектов"
    local sync_dir
    sync_dir="$(ask_sync_dir)"
    mkdir -p "$sync_dir"
    ok "Папка: $sync_dir"
    write_stignore "$sync_dir"

    step "Служба Syncthing (24/7)"
    start_syncthing

    step "Настройка папки"
    add_sync_folder "$sync_dir"
    keep_gui_local

    step "Firewall (ufw)"
    open_sync_ports

    step "ID этого сервера"
    local server_id
    server_id="$(syncthing_my_id)"
    [ -n "$server_id" ] || die "Не удалось узнать ID сервера — проверь: systemctl status $SYNC_SERVICE"
    ok "ID сервера получен"

    step "Твой компьютер (можно пропустить)"
    local pc_status="не добавлен — добавишь через веб-интерфейс (тоннель) или запусти модуль ещё раз"
    if add_computer; then
        pc_status="добавлен, папка ему открыта — осталось принять её на компьютере"
    fi

    apply_restart_if_needed

    step "Готово"
    save_credentials "$HOME/sync-info.txt" "$(cat << EOF
╔══════════════════════════════════════════════════╗
║  Синхронизация папки проектов — установлено        ║
╚══════════════════════════════════════════════════╝

ID сервера (скопируй целиком — он нужен на компьютере):
  $server_id

Папка на сервере:   $sync_dir
Режим:              в обе стороны, корзина версий 30 дней ($sync_dir/.stversions)
Не синхронизируется: .env, ключи, .ssh, .hermes, .git, мусор — список в $sync_dir/.stignore
Компьютер:          $pc_status

Веб-интерфейс Syncthing на сервере (только через SSH-тоннель):
  1. На компьютере в отдельном окне терминала (не закрывай его):
       ssh -L 8385:127.0.0.1:8384 root@$server_ip
     или в Netcatty: «Проброс портов» → локальный 8385 → 127.0.0.1:8384
  2. В браузере: http://127.0.0.1:8385

Что сделать на компьютере:
  1. Поставь Syncthing (Mac: syncthing-macos, Windows: Syncthing Windows Setup — ссылки в уроке).
  2. В его веб-интерфейсе (http://127.0.0.1:8384): «Добавить удалённое устройство» → вставь ID сервера.
  3. Прими папку «Проекты», выбери, где она будет лежать на компьютере,
     и на вкладке «Шаблоны игнорирования» вставь те же строки, что в .stignore сервера.

Скажи Гермесу: «Все файлы, которые создаёшь для меня, сохраняй в папку $sync_dir»

Проверка: systemctl status $SYNC_SERVICE    ·    ls $sync_dir
EOF
)"
}

# install_syncthing — официальный apt-репозиторий, без `curl | sh`. Уже стоит — не трогаем.
install_syncthing() {
    if command -v syncthing >/dev/null 2>&1; then
        ok "Syncthing уже стоит: $(syncthing --version 2>/dev/null | awk '{print $2}')"
        return 0
    fi

    apt_ensure ca-certificates curl gnupg

    local tmp_key
    tmp_key="${TMP_DIR:-$(mktemp -d)}/syncthing-release-key.gpg"
    curl -fsSL "$SYNCTHING_KEY_URL" -o "$tmp_key" \
        || die "Не удалось скачать ключ Syncthing ($SYNCTHING_KEY_URL) — проверь интернет и запусти ещё раз"

    # Сверка отпечатка: ключ с другим отпечатком = подмена или смена ключа — не ставим молча
    local fpr
    fpr="$(gpg --show-keys --with-colons "$tmp_key" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}' || true)"
    if [ "$fpr" != "$SYNCTHING_KEY_FPR" ]; then
        die "Отпечаток ключа Syncthing не совпал (ждали $SYNCTHING_KEY_FPR, получили ${fpr:-пусто}). Установка остановлена — напиши в чат потока"
    fi
    ok "Ключ Syncthing проверен (отпечаток совпал)"

    mkdir -p /etc/apt/keyrings
    install -m 644 "$tmp_key" "$SYNCTHING_KEYRING"
    echo "deb [signed-by=$SYNCTHING_KEYRING] https://apt.syncthing.net/ syncthing $SYNCTHING_CHANNEL" \
        > /etc/apt/sources.list.d/syncthing.list
    # Как советует apt.syncthing.net: пакеты Syncthing — из их репозитория, а не старые из Ubuntu
    printf "Package: *\nPin: origin apt.syncthing.net\nPin-Priority: 990\n" > /etc/apt/preferences.d/syncthing.pref

    log "Ставим Syncthing..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y syncthing
    command -v syncthing >/dev/null 2>&1 || die "Syncthing не установился — посмотри ошибки apt выше"
    ok "Syncthing $(syncthing --version 2>/dev/null | awk '{print $2}') установлен"
}

# ask_sync_dir — путь к папке проектов. Отсекаем опасное: весь дом, корень, ~/.hermes, спецсимволы.
ask_sync_dir() {
    local dir
    while true; do
        dir="$(ask "Папка для синхронизации (Enter — оставить как есть)" "$HOME/Проекты")"
        dir="${dir%/}"
        case "$dir" in
            "~"/*) dir="$HOME/${dir#\~/}" ;;
        esac
        if [[ "$dir" =~ [[:cntrl:]] ]] || [[ "$dir" == *'"'* ]] || [[ "$dir" == *\\* ]]; then
            warn "В пути не должно быть кавычек, обратной косой черты и спецсимволов — попробуй ещё раз" >&2
        elif [[ "$dir" != /* ]]; then
            warn "Путь должен начинаться с / (например $HOME/Проекты) — попробуй ещё раз" >&2
        elif [ -z "$dir" ] || [ "$dir" = "$HOME" ] || [ "$dir" = "/root" ] || [ "$dir" = "/home" ]; then
            warn "Весь домашний каталог синхронизировать нельзя — там ключи и настройки. Возьми отдельную папку, например $HOME/Проекты" >&2
        elif [[ "$dir" == "$HOME/.hermes" || "$dir" == "$HOME/.hermes/"* || "$dir" == "$HOME/.ssh"* ]]; then
            warn "Папки Гермеса и SSH не синхронизируем: ключи, токен бота и база ломаются от записи с двух сторон" >&2
        elif [[ "$dir" =~ ^/(etc|usr|bin|sbin|lib|lib64|boot|proc|sys|dev|run|var|opt|snap)(/|$) ]]; then
            warn "Системные папки синхронизировать нельзя — возьми папку в $HOME" >&2
        else
            echo "$dir"
            return 0
        fi
    done
}

# write_stignore "папка" — безопасный шаблон. Уже есть — не перезаписываем (там могут быть твои правки).
write_stignore() {
    local dir="$1"
    local file="$dir/.stignore"
    if [ -f "$file" ]; then
        if grep -qF '.env' "$file"; then
            ok ".stignore уже есть — оставляем как есть"
        else
            warn ".stignore уже есть, но в нём нет правила для .env — проверь, что секреты не уходят в синхронизацию: $file"
        fi
        return 0
    fi
    cat > "$file" << 'EOF'
// freemind-setup: что НЕ синхронизируется между сервером и компьютером.
// (?d) — такие файлы можно удалять, если из-за них не удаляется папка (лечит «висит на 95%»).

// Секреты — никогда не уезжают с устройства
.env
*.env
.env.*
*.key
*.pem
id_rsa*
id_ed25519*
id_ecdsa*
.ssh
.hermes
.claude
*-credentials.txt

// Служебное программ — пересоздаётся само
.git
.venv
venv
node_modules
__pycache__
*.pyc

// Мусор Mac и Windows
(?d).DS_Store
(?d)._*
(?d).Spotlight-V100
(?d).Trashes
(?d)Thumbs.db
(?d)desktop.ini
(?d)~$*
EOF
    chmod 644 "$file"
    ok ".stignore создан: секреты и мусор не синхронизируются"
}

# start_syncthing — первый запуск без «Default Folder» (~/Sync), включение в автозапуск, ожидание API.
start_syncthing() {
    if [ ! -f "$HOME/.local/state/syncthing/config.xml" ] && [ ! -f "$HOME/.config/syncthing/config.xml" ]; then
        log "Первый запуск — создаём ключи и конфиг Syncthing"
        STNODEFAULTFOLDER=1 syncthing generate --no-default-folder >/dev/null 2>&1 \
            || STNODEFAULTFOLDER=1 syncthing generate >/dev/null 2>&1 \
            || warn "syncthing generate не отработал — служба создаст конфиг сама"
    fi

    systemctl enable --now "$SYNC_SERVICE" >/dev/null 2>&1 \
        || die "Не удалось запустить службу $SYNC_SERVICE — посмотри: journalctl -u $SYNC_SERVICE -n 50"

    log "Ждём, пока Syncthing запустится (обычно 5-15 сек)..."
    local _
    for _ in $(seq 1 30); do
        if syncthing cli show system >/dev/null 2>&1; then
            ok "Syncthing работает (служба $SYNC_SERVICE, автозапуск включён)"
            remove_default_folder
            return 0
        fi
        sleep 2
    done
    die "Syncthing не ответил за 60 с — посмотри: journalctl -u $SYNC_SERVICE -n 50"
}

# remove_default_folder — на старых версиях Syncthing при первом старте сам заводит пустую ~/Sync.
# Убираем, только если она пустая (там лишь служебная .stfolder) — чужое не трогаем.
remove_default_folder() {
    syncthing cli config folders list 2>/dev/null | grep -qx "default" || return 0
    local path
    path="$(syncthing cli config folders default path get 2>/dev/null || true)"
    if [ -n "$path" ] && [ -d "$path" ] && [ -z "$(find "$path" -mindepth 1 -maxdepth 1 ! -name .stfolder 2>/dev/null)" ]; then
        syncthing cli config folders default delete >/dev/null 2>&1 || true
        rm -rf "$path/.stfolder" 2>/dev/null || true
        rmdir "$path" 2>/dev/null || true
        ok "Лишняя пустая папка «Default Folder» убрана"
    fi
}

# add_sync_folder "путь" — папка в обе стороны, fsWatcher, полный пересмотр раз в час, корзина 30 дней.
add_sync_folder() {
    local dir="$1"
    local f="$SYNC_FOLDER_ID"

    if syncthing cli config folders list 2>/dev/null | grep -qx "$f"; then
        local current
        current="$(syncthing cli config folders "$f" path get 2>/dev/null || true)"
        current="${current%/}"
        if [ "$current" != "$dir" ]; then
            warn "Папка синхронизации уже настроена на $current — не меняю её (чтобы не перепутать файлы)."
            warn "Если нужна другая папка — поменяй путь в веб-интерфейсе Syncthing."
            return 0
        fi
        ok "Папка «Проекты» уже настроена — проверяем параметры"
    else
        syncthing cli config folders add --id "$f" --label "Проекты" --path "$dir" --type sendreceive \
            || die "Не удалось добавить папку в Syncthing — посмотри: journalctl -u $SYNC_SERVICE -n 50"
        ok "Папка добавлена в Syncthing"
    fi

    # Ставим явно и при повторном запуске — команда «set» безопасна, значения те же
    local failed=0
    syncthing cli config folders "$f" type set sendreceive || failed=1
    syncthing cli config folders "$f" fswatcher-enabled set true || failed=1
    syncthing cli config folders "$f" rescan-intervals set 3600 || failed=1
    syncthing cli config folders "$f" versioning type set staggered || failed=1
    syncthing cli config folders "$f" versioning params set maxAge 2592000 || failed=1
    syncthing cli config folders "$f" versioning cleanup-intervals set 3600 || failed=1
    if [ "$failed" -ne 0 ]; then
        warn "Часть настроек папки не применилась — проверь в веб-интерфейсе: папка «Проекты» → «Изменить» (тип «Отправка и получение», версии «Поэтапное», 30 дней)"
        return 0
    fi
    ok "В обе стороны · изменения ловятся сразу · корзина версий 30 дней"
}

# keep_gui_local — веб-интерфейс только для самого сервера. Снаружи — только через SSH-тоннель.
keep_gui_local() {
    local addr
    addr="$(syncthing cli config gui raw-address get 2>/dev/null || true)"
    if [ "$addr" != "127.0.0.1:8384" ]; then
        syncthing cli config gui raw-address set 127.0.0.1:8384 \
            || die "Не удалось закрыть веб-интерфейс Syncthing от внешнего мира — остановлено, напиши в чат потока"
        ok "Веб-интерфейс Syncthing: только 127.0.0.1:8384 (было: ${addr:-не задано})"
    else
        ok "Веб-интерфейс Syncthing: только 127.0.0.1:8384 — снаружи не виден"
    fi
}

# open_sync_ports — порты Syncthing. ufw не включаем сами (чтобы не отрезать SSH), только добавляем правила.
open_sync_ports() {
    ensure_ufw
    ufw allow 22000/tcp comment 'Syncthing' >/dev/null 2>&1 || ufw allow 22000/tcp >/dev/null 2>&1 || true
    ufw allow 22000/udp comment 'Syncthing' >/dev/null 2>&1 || ufw allow 22000/udp >/dev/null 2>&1 || true
    ufw allow 21027/udp comment 'Syncthing' >/dev/null 2>&1 || ufw allow 21027/udp >/dev/null 2>&1 || true
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "ufw: открыты 22000/tcp, 22000/udp, 21027/udp (Syncthing)"
    else
        ok "Правила для Syncthing добавлены (22000/tcp, 22000/udp, 21027/udp)"
        log "ufw сейчас выключен — правила сработают, когда включишь его (SSH-порт $(ssh_port) не забудь разрешить)"
    fi
}

# syncthing_my_id — ID этого сервера (не секрет: по нему другие устройства просят разрешения подключиться)
syncthing_my_id() {
    syncthing cli show system 2>/dev/null | grep -o '"myID": *"[A-Z0-9-]*"' | grep -o '[A-Z0-9]\{7\}\(-[A-Z0-9]\{7\}\)\{7\}' | head -1 || true
}

# add_computer — по желанию: ID компьютера → устройство + доступ к папке. Код 0 = добавлен.
add_computer() {
    echo "  Если Syncthing на компьютере уже стоит, вставь его ID: тогда веб-интерфейс сервера"
    echo "  открывать не придётся. ID — в программе на компьютере: «Действия» → «Показать ID»."
    echo "  Ещё не ставил — просто Enter, это можно сделать потом."
    local pc_id
    pc_id="$(ask "ID компьютера (Enter — пропустить)" "")"
    pc_id="$(echo "$pc_id" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
    [ -n "$pc_id" ] || { log "Пропускаем — компьютер добавишь позже"; return 1; }

    if ! [[ "$pc_id" =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]]; then
        warn "Это не похоже на ID Syncthing (8 групп по 7 знаков через дефис). Пропускаю — запусти модуль ещё раз с верным ID"
        return 1
    fi
    if [ "$pc_id" = "$(syncthing_my_id)" ]; then
        warn "Это ID самого сервера, а нужен ID компьютера. Пропускаю"
        return 1
    fi

    if syncthing cli config devices list 2>/dev/null | grep -qx "$pc_id"; then
        ok "Компьютер уже в списке устройств"
    else
        syncthing cli config devices add --device-id "$pc_id" --name "Мой компьютер" --addresses dynamic \
            || { warn "Не удалось добавить компьютер — добавь его в веб-интерфейсе (тоннель)"; return 1; }
        ok "Компьютер добавлен"
    fi

    if syncthing cli config folders "$SYNC_FOLDER_ID" devices list 2>/dev/null | grep -qx "$pc_id"; then
        ok "Папка «Проекты» компьютеру уже открыта"
    else
        syncthing cli config folders "$SYNC_FOLDER_ID" devices add --device-id "$pc_id" \
            || { warn "Не удалось открыть папку компьютеру — сделай это в веб-интерфейсе (тоннель)"; return 1; }
        ok "Папка «Проекты» открыта компьютеру"
    fi
    return 0
}

# apply_restart_if_needed — если какая-то настройка требует перезапуска Syncthing, перезапускаем
apply_restart_if_needed() {
    if syncthing cli show config-status 2>/dev/null | grep -q '"requiresRestart": *true'; then
        log "Перезапускаем Syncthing, чтобы применить настройки..."
        systemctl restart "$SYNC_SERVICE"
        local _
        for _ in $(seq 1 15); do
            syncthing cli show system >/dev/null 2>&1 && break
            sleep 2
        done
    fi
}
