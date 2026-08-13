#!/usr/bin/env bash
# freemind-setup/modules/hermes.sh — Hermes + Kanban-доска
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "Гермес (AI-агент) + Kanban — установка"

    require_root
    ensure_swap 4

    step "Python 3.11 + Node.js"
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # shellcheck source=/dev/null
        source "$HOME/.bashrc" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
    fi
    uv python install 3.11 || true

    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi
    ok "Node $(node --version 2>/dev/null || echo '?'), uv готов"

    step "Установка Hermes"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v hermes >/dev/null 2>&1; then
        die "hermes не найден после установки — проверь PATH (\$HOME/.local/bin) и попробуй заново"
    fi
    ok "Hermes $(hermes --version)"

    step "AI-провайдер"
    echo "1) Nous Portal — один логин, всё включено (модель, поиск, картинки, TTS)"
    echo "2) Свои ключи — Anthropic/OpenRouter/другой"
    local choice
    choice="$(ask "Выбери 1 или 2" "1")"
    if [ "$choice" = "1" ]; then
        hermes setup --portal
    else
        hermes model
    fi
    hermes status || warn "Провайдер не подтверждён — прогони 'hermes status' вручную и проверь"

    step "Диагностика"
    hermes doctor || warn "Doctor нашёл замечания выше — проверь их перед продолжением"

    step "Kanban-доска"
    hermes kanban init
    local demo_task
    demo_task="$(ask "Демо-задача для Kanban (например: собрать список файлов в /var/log)" "собрать список файлов в /var/log")"
    hermes kanban create "$demo_task" --body "Демо-задача установки" --priority 1
    hermes kanban dispatch
    sleep 5
    hermes kanban list

    step "Веб-дашборд"
    if confirm "Привязать дашборд к домену (https)? Иначе — только SSH-туннель для себя"; then
        local domain email dash_password hash
        domain="$(ask "Домен (например agent.твой-домен.ru)")"
        email="$(ask "Email для Let's Encrypt")"
        dash_password="$(ask_secret "Пароль для входа в дашборд (логин будет admin)")"

        hash="$(python3 -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('$dash_password'))")"
        {
            echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin"
            echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$hash"
            echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)"
        } >> ~/.hermes/.env
        chmod 600 ~/.hermes/.env

        setup_nginx_site "agent" "$domain" "9119" "$email"

        nohup hermes dashboard --host 0.0.0.0 --port 9119 --no-open > ~/.hermes/dashboard.log 2>&1 &
        sleep 3

        local gate
        gate="$(curl -fsSL http://127.0.0.1:9119/api/status 2>/dev/null | grep -o '"auth_required":[a-z]*' || echo "?")"
        if [ "$gate" = '"auth_required":true' ]; then
            ok "Пароль на дашборд включён (auth_required:true)"
        else
            warn "Не удалось подтвердить auth_required:true — проверь вручную: curl http://127.0.0.1:9119/api/status"
        fi
        ok "Дашборд: https://$domain (логин admin)"
    else
        local server_ip
        server_ip="$(curl -fsSL ifconfig.me || hostname -I | awk '{print $1}')"
        echo "Со своего компьютера: ssh -L 9119:localhost:9119 root@$server_ip"
        echo "Потом открой http://localhost:9119"
    fi

    step "Автозапуск диспетчера (24/7, без Telegram — это отдельный модуль)"
    hermes gateway install --system --start-now --start-on-login
    hermes gateway status || warn "Проверь статус вручную: hermes gateway status"

    step "Готово"
    echo "Hermes установлен, провайдер подключён, демо-задача \"$demo_task\" отправлена в работу."
    echo "Диспетчер работает в фоне — новые задачи (hermes kanban create ...) подхватятся сами."
}
