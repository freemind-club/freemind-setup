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
Провайдеры:         ${configured[*]}
Файл ключей:        ~/.omniroute/.env (chmod 600)

⚠️ Ключ для подключения инструментов (Claude Code, n8n, curl)
   создаётся ВРУЧНУЮ в дашборде: $dashboard_url → API Manager → Create API Key
   Скрипт не может создать его сам — это шаг через веб-интерфейс.

API base для инструментов: $dashboard_url/v1
EOF
)"
}
