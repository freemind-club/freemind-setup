#!/usr/bin/env bash
# freemind-setup/modules/omniroute.sh — OmniRoute (единый AI-шлюз) на сервере
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "OmniRoute (AI-шлюз) — установка"

    require_root
    unlock_dpkg

    local server_ip
    server_ip="$(curl -fsSL ifconfig.me || hostname -I | awk '{print $1}')"

    step "Node.js"
    ensure_node

    step "Установка OmniRoute"
    npm install -g omniroute
    command -v omniroute >/dev/null 2>&1 || die "omniroute не найден после npm install -g — проверь вывод выше"
    ok "OmniRoute установлен: $(omniroute --version 2>/dev/null || echo '?')"

    step "Ключи AI-провайдеров"

    mkdir -p ~/.omniroute
    local env_file=~/.omniroute/.env
    local configured=()

    if [ -s "$HOME/ai-keys/.env" ] && confirm "Найден ~/ai-keys/.env (модуль keys уже собирал ключи) — использовать его?"; then
        cp "$HOME/ai-keys/.env" "$env_file"
        configured=("из ~/ai-keys/.env — см. файл")
        ok "Ключи скопированы из ~/ai-keys/.env"
    else
        : > "$env_file"
        echo "Нужен хотя бы один ключ. Остальные можно добавить позже через дашборд OmniRoute."
        echo ""
        echo "Бесплатные (рекомендуется хотя бы 2-3 для фолбэка):"
        collect_api_key "GROQ_API_KEY"         "Groq (самый быстрый)"                 "https://console.groq.com" "gsk_..."
        collect_api_key "CEREBRAS_API_KEY"     "Cerebras (1М токенов/день бесплатно)" "https://cloud.cerebras.ai" "csk-..."
        collect_api_key "GOOGLE_AI_STUDIO_KEY" "Google AI Studio (Gemini)"            "https://aistudio.google.com" "AIza..."
        collect_api_key "OPENROUTER_API_KEY"   "OpenRouter (сотни моделей)"           "https://openrouter.ai" "sk-or-v1-..."
        collect_api_key "SAMBANOVA_API_KEY"    "SambaNova"                            "https://cloud.sambanova.ai" "..."
        collect_api_key "FIREWORKS_API_KEY"    "Fireworks AI"                         "https://fireworks.ai" "fw_..."
        collect_api_key "TOGETHER_API_KEY"     "Together.ai"                          "https://together.ai" "tgp_v1_..."
        echo ""
        echo "Платные (используются реже, для конкретных задач):"
        collect_api_key "ANTHROPIC_API_KEY"    "Anthropic (Claude)"                   "https://console.anthropic.com" "sk-ant-..."
        collect_api_key "OPENAI_API_KEY"       "OpenAI"                               "https://platform.openai.com" "sk-proj-..."
    fi

    if [ "${#configured[@]}" -eq 0 ]; then
        die "Ни одного ключа не добавлено — OmniRoute без провайдера бесполезен. Запусти модуль заново."
    fi

    step "Пароль дашборда"
    local dash_password
    dash_password="$(ask_secret "Пароль для входа в дашборд OmniRoute" "Omni_2026!")"

    # OmniRoute хранит логин в СВОЕЙ sqlite (не в .env) — таблица key_value.
    # Официальный способ задать пароль — переменная INITIAL_PASSWORD в .env,
    # но она подхватывается ТОЛЬКО на самом первом запуске, пока setupComplete=false
    # (см. 00_claude/KNOWLEDGE_BASE.md OMNI-003). Поэтому: если storage.sqlite ещё
    # нет — это чистая установка, кладём INITIAL_PASSWORD ДО первого старта.
    # Если sqlite уже существует (инстанс уже был настроен раньше) — INITIAL_PASSWORD
    # эффекта не даст, и мы правим пароль напрямую через sqlite/bcrypt (fallback).
    local db_path="$HOME/.omniroute/storage.sqlite"
    local fresh_install=true
    if [ -f "$db_path" ]; then
        fresh_install=false
    fi

    if [ "$fresh_install" = true ]; then
        echo "INITIAL_PASSWORD=$dash_password" >> "$env_file"
    fi
    chmod 600 "$env_file"
    ok "Настроено провайдеров: ${configured[*]}"

    step "Автозапуск (systemd)"
    local omniroute_bin
    omniroute_bin="$(command -v omniroute)"
    cat > /etc/systemd/system/omniroute.service << EOF
[Unit]
Description=OmniRoute AI Gateway
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$HOME/.omniroute
ExecStart=$omniroute_bin
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable omniroute
    systemctl restart omniroute
    sleep 3

    if systemctl is-active --quiet omniroute; then
        ok "OmniRoute работает 24/7 (systemctl status omniroute)"
    else
        die "OmniRoute не запустился — смотри: journalctl -u omniroute -n 50"
    fi

    ufw allow 20128/tcp >/dev/null 2>&1 || true

    step "Проверка пароля дашборда"

    local npm_root omni_pkg_dir
    npm_root="$(npm root -g)"
    omni_pkg_dir="$npm_root/omniroute"

    # На самом первом запуске storage.sqlite/таблица key_value могут появиться
    # не мгновенно — ждём немного вместо того чтобы упасть на пустом месте.
    local db_ready=false
    for _ in 1 2 3 4 5 6; do
        if [ -f "$db_path" ] && sqlite3 "$db_path" "SELECT 1 FROM key_value LIMIT 1;" >/dev/null 2>&1; then
            db_ready=true
            break
        fi
        sleep 2
        apt_ensure sqlite3
    done

    local login_check
    login_check="$(curl -s --max-time 8 -X POST "http://127.0.0.1:20128/api/auth/login" -H "Content-Type: application/json" -d "{\"password\":\"$dash_password\"}" 2>/dev/null)"

    if [ "$fresh_install" = true ] && echo "$login_check" | grep -q '"success":true'; then
        ok "Пароль дашборда установлен через INITIAL_PASSWORD и проверен настоящим логином"
    else
        if [ "$fresh_install" = true ]; then
            warn "INITIAL_PASSWORD не сработал сам — правлю пароль напрямую через sqlite (fallback)"
        else
            echo "Инстанс уже был настроен раньше — правлю пароль напрямую через sqlite"
        fi

        apt_ensure sqlite3

        if [ ! -d "$omni_pkg_dir/node_modules/bcryptjs" ]; then
            warn "bcryptjs не найден в $omni_pkg_dir — пропускаю установку пароля, дашборд останется без него (или со значением по умолчанию у OmniRoute)"
        elif [ "$db_ready" != true ]; then
            warn "База $db_path/таблица key_value не появилась вовремя — пропускаю автоустановку пароля. Открой дашборд в браузере один раз (это создаёт базу), потом повтори этот шаг вручную."
        else
            local hash
            hash="$(cd "$omni_pkg_dir" && node -e "const b=require('bcryptjs'); console.log(b.hashSync(process.argv[1], 12));" "$dash_password")"

            # Строка password может ещё не существовать при самом первом запуске.
            # DELETE+INSERT вместо INSERT OR REPLACE — не полагаемся на то, что на key
            # точно висит UNIQUE/PRIMARY KEY (не проверяли схему), так надёжно в любом случае.
            sqlite3 "$db_path" "DELETE FROM key_value WHERE key = 'password'; INSERT INTO key_value (key, value) VALUES ('password', json_quote('$hash'));"
            sqlite3 "$db_path" "DELETE FROM key_value WHERE key = 'requireLogin'; INSERT INTO key_value (key, value) VALUES ('requireLogin', 'true');"
            sqlite3 "$db_path" "DELETE FROM key_value WHERE key = 'setupComplete'; INSERT INTO key_value (key, value) VALUES ('setupComplete', 'true');"

            systemctl restart omniroute
            sleep 3

            login_check="$(curl -s --max-time 8 -X POST "http://127.0.0.1:20128/api/auth/login" -H "Content-Type: application/json" -d "{\"password\":\"$dash_password\"}" 2>/dev/null)"
            if echo "$login_check" | grep -q '"success":true'; then
                ok "Пароль дашборда установлен и проверен настоящим логином"
            else
                warn "Не удалось подтвердить логин автоматически — проверь вручную через браузер. Ответ сервера: $login_check"
            fi
        fi
    fi

    step "Домен для дашборда (опционально)"
    local dashboard_url="http://$server_ip:20128"
    if confirm "Привязать дашборд OmniRoute к домену (https)?"; then
        local domain email
        domain="$(ask "Домен (например ai.твой-домен.ru)")"
        email="$(ask "Email для Let's Encrypt")"
        setup_nginx_site "omniroute" "$domain" "20128" "$email"
        if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
            dashboard_url="https://$domain"
        fi
    fi

    step "Готово"
    save_credentials "$HOME/omniroute-credentials.txt" "$(cat << EOF
╔══════════════════════════════════════════════════╗
║  OmniRoute (AI-шлюз) — установлено                 ║
╚══════════════════════════════════════════════════╝

IP сервера:        $server_ip
Дашборд:            $dashboard_url
Пароль дашборда:    $dash_password
Провайдеры:         ${configured[*]}
Файл ключей:        ~/.omniroute/.env (chmod 600)

⚠️ Ключ для подключения инструментов (Claude Code, n8n, curl)
   создаётся ВРУЧНУЮ в дашборде: $dashboard_url → API Manager → Create API Key
   Скрипт не может создать его сам — это шаг через веб-интерфейс.

API base для инструментов: $dashboard_url/v1

⚠️ Пароль дашборда — смени командой (замени НОВЫЙ_ПАРОЛЬ):
   cd $omni_pkg_dir && HASH=\$(node -e "const b=require('bcryptjs'); console.log(b.hashSync(process.argv[1],12));" 'НОВЫЙ_ПАРОЛЬ')
   sqlite3 ~/.omniroute/storage.sqlite "UPDATE key_value SET value = json_quote('\$HASH') WHERE key = 'password';"
   systemctl restart omniroute
EOF
)"
}
