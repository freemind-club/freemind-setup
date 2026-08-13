#!/usr/bin/env bash
# freemind-setup/modules/telegram.sh — подключение Telegram к уже установленному Hermes
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "Telegram-гейтвей для Гермеса"

    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v hermes >/dev/null 2>&1; then
        die "Hermes не найден — сначала выполни: install.sh hermes"
    fi
    ok "Hermes $(hermes --version) найден"

    step "Бот через BotFather"
    echo "  1. В Telegram открой @BotFather"
    echo "  2. Отправь /newbot, придумай имя и username (обязательно кончается на bot)"
    echo "  3. Скопируй токен вида 123456789:ABCdef..."
    echo ""
    local bot_token
    bot_token="$(ask_secret "Вставь токен бота")"
    [ -z "$bot_token" ] && die "Без токена дальше нет смысла — запусти модуль заново"

    step "Твой Telegram ID"
    echo "  Напиши боту @userinfobot — он сразу пришлёт числовой ID"
    local user_id
    user_id="$(ask "Твой числовой Telegram ID")"
    [ -z "$user_id" ] && die "Без ID гейтвей никого не пустит — запусти модуль заново"

    step "Записываем конфиг"
    {
        echo "TELEGRAM_BOT_TOKEN=$bot_token"
        echo "TELEGRAM_ALLOWED_USERS=$user_id"
    } >> ~/.hermes/.env
    chmod 600 ~/.hermes/.env
    ok "Записано в ~/.hermes/.env"

    step "Перезапуск диспетчера"
    hermes gateway restart
    sleep 3
    hermes gateway status || warn "Проверь статус вручную: hermes gateway status"

    step "Готово"
    save_credentials "$HOME/telegram-credentials.txt" "$(cat << EOF
╔══════════════════════════════════════════════════╗
║  Telegram-гейтвей для Гермеса — подключено         ║
╚══════════════════════════════════════════════════╝

Бот-токен:      $bot_token
Разрешённый ID: $user_id

Проверка: напиши боту в Telegram — должен ответить за пару секунд.
Групповые чаты: по умолчанию бот видит только команды и ответы себе —
  выключи Privacy Mode через @BotFather (Bot Settings → Group Privacy),
  затем удали и заново добавь бота в группу.
EOF
)"
}
