#!/usr/bin/env bash
# freemind-setup/modules/hermes.sh — Hermes + Kanban-доска
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "Гермес (AI-агент) + Kanban — установка"

    require_root
    unlock_dpkg
    ensure_swap 4

    local server_ip
    server_ip="$(curl -fsSL ifconfig.me || hostname -I | awk '{print $1}')"

    step "Python 3.11 + Node.js"
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    export PATH="$HOME/.local/bin:$PATH"
    uv python install 3.11 || true
    ensure_node
    ok "uv готов"

    step "Установка Hermes"
    local hermes_installer
    hermes_installer="${TMP_DIR:-$(mktemp -d)}/hermes-install.sh"
    download_hermes_installer "$hermes_installer"
    bash "$hermes_installer"
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v hermes >/dev/null 2>&1; then
        die "hermes не найден после установки — проверь PATH (\$HOME/.local/bin) и попробуй заново"
    fi
    # Полный путь — в фоновых запусках (setsid nohup) PATH текущей сессии не гарантирован:
    # было «nohup: failed to run command 'hermes'» (найдено вживую)
    local hermes_bin
    hermes_bin="$(command -v hermes)"
    ok "Hermes $("$hermes_bin" --version)"

    # ~/.local/bin нет в PATH новой SSH-сессии — без этого `hermes` после перезахода «не найден»
    # shellcheck disable=SC2016  # $HOME/$PATH должны остаться буквально — раскроются при входе
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    if ! grep -qF "$path_line" ~/.bashrc 2>/dev/null; then
        printf '\n# freemind-setup: команда hermes (~/.local/bin)\n%s\n' "$path_line" >> ~/.bashrc
        ok "\$HOME/.local/bin добавлен в PATH (\$HOME/.bashrc)"
    fi

    step "Стартовая настройка Гермеса — AI-провайдер"
    echo "1) Nous Portal — один логин, всё включено (модель, поиск, картинки, TTS)"
    echo "2) Свои ключи — Anthropic/OpenRouter/другой"
    local choice provider_label
    choice="$(ask "Выбери 1 или 2" "1")"
    if [ "$choice" = "1" ]; then
        hermes setup --portal
        provider_label="Nous Portal"
    else
        hermes model
        provider_label="свои ключи"
    fi
    hermes status || warn "Провайдер не подтверждён — прогони 'hermes status' вручную и проверь"

    step "Диагностика"
    hermes doctor || warn "Doctor нашёл замечания выше — проверь их перед продолжением"

    step "Kanban-доска"
    hermes kanban init
    local demo_task
    demo_task="$(ask "Демо-задача для Kanban (например: собрать список файлов в /var/log)" "собрать список файлов в /var/log")"
    # --assignee обязателен — без него dispatch молча пропускает задачу (skipped_unassigned), найдено вживую
    hermes kanban create "$demo_task" --body "Демо-задача установки" --priority 1 --assignee default
    hermes kanban dispatch
    log "Ждём выполнения демо-задачи (обычно 10-30 сек)..."
    for _ in 1 2 3 4 5 6; do
        sleep 8
        hermes kanban dispatch >/dev/null 2>&1 || true
    done
    hermes kanban list

    step "Веб-дашборд"
    local dashboard_url="SSH-туннель: ssh -L 9119:localhost:9119 root@$server_ip → http://localhost:9119"
    local dash_password="(без пароля — доступ только через SSH-туннель)"
    if confirm "Привязать дашборд к домену (https)? Иначе — только SSH-туннель для себя"; then
        local domain email hash
        domain="$(ask "Домен (например agent.твой-домен.ru)")"
        email="$(ask "Email для Let's Encrypt")"
        dash_password="$(ask_secret "Пароль для входа в дашборд (логин admin)" "Hermes_2026!")"

        # Хэш пароля считает плагин Hermes — нужен его питон с зависимостями и его каталог.
        # Где они лежат, зависит от версии: до v0.23 — /usr/local/lib/hermes-agent/venv,
        # с v0.23 (git-установка) — ~/.hermes/hermes-agent + ~/.hermes/installs/*/environments/*/venv
        # (найдено вживую 07.11.2026). Не нашли — пишем пароль открытым текстом
        # HERMES_DASHBOARD_BASIC_AUTH_PASSWORD (Hermes сам хэширует его при старте, .env — chmod 600).
        # Пароль — через переменную окружения, не подстановкой в код Python
        # (кавычка в пароле ломала команду и позволяла выполнить произвольный код)
        local hash="" hdir py
        for hdir in /usr/local/lib/hermes-agent "$HOME/.hermes/hermes-agent"; do
            [ -d "$hdir/plugins/dashboard_auth" ] || continue
            for py in "$hdir/venv/bin/python" "$HOME"/.hermes/installs/*/environments/*/venv/bin/python; do
                [ -x "$py" ] || continue
                hash="$(cd "$hdir" && FM_DASH_PASSWORD="$dash_password" "$py" -c "import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ['FM_DASH_PASSWORD']))" 2>/dev/null || true)"
                [ -n "$hash" ] && break 2
            done
        done
        sed -i '/^HERMES_DASHBOARD_BASIC_AUTH_/d' ~/.hermes/.env 2>/dev/null || true
        {
            echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin"
            if [ -n "$hash" ]; then
                echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$hash"
            else
                echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$dash_password"
            fi
            echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)"
        } >> ~/.hermes/.env
        chmod 600 ~/.hermes/.env
        [ -n "$hash" ] || warn "Хэш не посчитан — пароль записан в ~/.hermes/.env открытым текстом (файл закрыт chmod 600)"

        # Домен панели обязателен: без dashboard.public_url Гермес на адресе 127.0.0.1 считает
        # себя «только для своих» и пароль НЕ включает — через nginx панель открыта всем
        # (найдено вживую 07.11.2026, v0.23)
        "$hermes_bin" config set dashboard.public_url "https://$domain" >/dev/null

        setup_nginx_site "agent" "$domain" "9119" "$email"

        start_dashboard "$hermes_bin" "0.0.0.0" || true

        local gate
        gate="$(curl -fsSL http://127.0.0.1:9119/api/status 2>/dev/null | grep -o '"auth_required":[a-z]*' || echo "?")"
        if [ "$gate" = '"auth_required":true' ]; then
            ok "Пароль на дашборд включён (auth_required:true)"
        else
            # Без пароля панель на домене открыта всему интернету — гасим её, а не просто предупреждаем
            pkill -f "hermes dashboard" 2>/dev/null || true
            warn "Пароль на дашборд НЕ подтвердился ($gate) — дашборд остановлен, чтобы не висеть открытым."
            warn "Проверь: grep HERMES_DASHBOARD ~/.hermes/.env; hermes config get dashboard.public_url — потом запусти модуль снова"
        fi
        dashboard_url="https://$domain (логин admin)"
        ok "Дашборд: $dashboard_url"
    else
        # Без домена дашборд раньше вообще не запускался — тоннель вёл в пустоту
        # («channel 3: open failed: connect failed: Connection refused», найдено вживую).
        # Слушаем только 127.0.0.1: снаружи порт не виден, попасть можно лишь через SSH-тоннель.
        if start_dashboard "$hermes_bin" "127.0.0.1"; then
            ok "Дашборд запущен на сервере (127.0.0.1:9119)"
        fi
        log "Как открыть со своего компьютера (в отдельном окне терминала, не закрывай его):"
        log "  ssh -L 9119:localhost:9119 root@$server_ip"
        log "Потом в браузере: http://localhost:9119"
    fi

    step "Автозапуск диспетчера (24/7, без Telegram — это отдельный модуль)"
    # --run-as-user root обязателен — по умолчанию hermes отказывается ставить system-сервис
    # под root без явного флага (защита от bare-metal хостов), найдено вживую
    # Если в мастере Гермеса ответили «y» на «Install the gateway service…», он уже поставил
    # user-службу (~/.config/systemd/user). Вторая, системная, видит живой шлюз, пишет
    # «nothing to start», выходит и из-за Restart=always перезапускается по кругу —
    # сотни рестартов (найдено вживую). Поэтому ставим системную, только если user-службы нет.
    if [ -f "$HOME/.config/systemd/user/hermes-gateway.service" ]; then
        ok "Автозапуск уже настроен мастером Гермеса (user-служба) — вторую не ставим"
        if systemctl list-unit-files hermes-gateway.service >/dev/null 2>&1 \
            && systemctl is-enabled hermes-gateway >/dev/null 2>&1; then
            systemctl disable --now hermes-gateway >/dev/null 2>&1 || true
            ok "Лишняя системная служба hermes-gateway отключена (была причиной цикла перезапусков)"
        fi
    else
        "$hermes_bin" gateway install --system --run-as-user root --start-now --start-on-login
    fi
    "$hermes_bin" gateway status || warn "Проверь статус вручную: hermes gateway status"

    step "Готово"
    save_credentials "$HOME/hermes-credentials.txt" "$(cat << EOF
╔══════════════════════════════════════════════════╗
║  Гермес (AI-агент) + Kanban — установлено          ║
╚══════════════════════════════════════════════════╝

IP сервера:       $server_ip
AI-провайдер:      $provider_label
Демо-задача:       $demo_task

Веб-дашборд:       $dashboard_url
Пароль дашборда:   $dash_password

Диспетчер:         systemd, 24/7 (hermes gateway status)
Telegram-гейтвей:  ещё не подключён — отдельный модуль

Проверка: hermes kanban list — демо-задача должна быть done/running

⚠️ Если оставил учебный пароль — смени (латиница и цифры, без кавычек):
   sed -i '/^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD/d' ~/.hermes/.env
   echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=НОВЫЙ_ПАРОЛЬ" >> ~/.hermes/.env
   pkill -f "hermes dashboard"; setsid nohup $hermes_bin dashboard --host 0.0.0.0 --port 9119 --no-open > ~/.hermes/dashboard.log 2>&1 < /dev/null & disown
   Проверка: curl -s http://127.0.0.1:9119/api/status | grep -o '"auth_required":[a-z]*'  → true
EOF
)"

    echo ""
    warn "Перезайди на сервер (exit → ssh снова), чтобы команда hermes заработала в терминале"
}

# download_hermes_installer "куда_сохранить" — установщик Гермеса в файл, с ретраями.
# Раньше было `curl ... | bash`: сайт Гермеса (Vercel) при частых перезапусках отвечает
# 429 Too Many Requests, и установка падала на полпути (найдено вживую).
# Запасной источник — тот же скрипт из GitHub-репозитория (сверено: файлы идентичны).
download_hermes_installer() {
    local out="$1"
    local primary="https://hermes-agent.nousresearch.com/install.sh"
    local fallback="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
    local attempt code pause

    for attempt in 1 2 3; do
        code="$(curl -sSL -o "$out" -w '%{http_code}' "$primary" 2>/dev/null || true)"
        if [ "$code" = "200" ] && [ -s "$out" ] && head -1 "$out" | grep -q '^#!'; then
            ok "Установщик Гермеса скачан"
            return 0
        fi
        [ "$attempt" -lt 3 ] || break
        pause=$((attempt * 10 + 10))
        if [ "$code" = "429" ]; then
            warn "Сайт Гермеса просит подождать (429), пробую ещё раз через $pause с (попытка $((attempt + 1)) из 3)"
        else
            warn "Не удалось скачать установщик Гермеса (код: ${code:-нет ответа}), пробую ещё раз через $pause с (попытка $((attempt + 1)) из 3)"
        fi
        sleep "$pause"
    done

    warn "Основной сайт Гермеса не отвечает — качаю тот же установщик с GitHub"
    code="$(curl -sSL -o "$out" -w '%{http_code}' "$fallback" 2>/dev/null || true)"
    if [ "$code" = "200" ] && [ -s "$out" ] && head -1 "$out" | grep -q '^#!'; then
        ok "Установщик Гермеса скачан (запасной источник GitHub)"
        return 0
    fi
    die "Не удалось скачать установщик Гермеса ни с сайта, ни с GitHub. Подожди пару минут и запусти ту же команду ещё раз — уже поставленное пропустится"
}

# start_dashboard "путь_к_hermes" "host" — запуск веб-дашборда в фоне + ожидание готовности.
# Код возврата 0 = отвечает на /api/status, 1 = не дождались (warn, установка идёт дальше).
start_dashboard() {
    local bin="$1"
    local host="$2"
    pkill -f "hermes dashboard" 2>/dev/null || true
    # setsid + disown — nohup один не всегда переживает завершение SSH-сессии/пайпа (найдено вживую)
    setsid nohup "$bin" dashboard --host "$host" --port 9119 --no-open > ~/.hermes/dashboard.log 2>&1 < /dev/null &
    disown
    # Дашборд поднимается 10-20 с — ждём до 30 с
    log "Ждём запуска дашборда (обычно 10-20 сек)..."
    local _
    for _ in $(seq 1 15); do
        if curl -fsS -o /dev/null http://127.0.0.1:9119/api/status 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    warn "Дашборд не ответил за 30 с — проверь лог: tail -50 ~/.hermes/dashboard.log"
    return 1
}
