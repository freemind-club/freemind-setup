#!/usr/bin/env bash
# freemind-setup/modules/mozg.sh — «мозг» для AI-агентов: два полушария памяти
#   1) LightRAG — смысловая память (граф знаний + векторный поиск)
#   2) PostgreSQL brain — таблицы (клиенты, подписчики, метрики, факты)
# Подключается через install.sh, использует функции из lib/common.sh.
#
# Бесплатно по умолчанию: LLM и эмбеддинги — бесплатный тариф Mistral (один ключ, без карты).
# Повторный запуск безопасен: ключи/пароли/модели прошлой установки переиспользуются,
# база не пересоздаётся, данные не удаляются.

# ─── Пиннутые версии (образы — тег + digest; обновлять осознанно, после проверки) ───
# lightrag v1.4.13 — та же сборка, что 7 месяцев работает у нас в проде (digest сверен)
MOZG_LIGHTRAG_IMAGE="ghcr.io/hkuds/lightrag:v1.4.13@sha256:fd0d8eed0c886a72f58bef38aa8ba5a057e762980e378442dd1d65b659130f45"
MOZG_RAGPG_IMAGE="gzdaniel/postgres-for-rag:16.6@sha256:bab9b7b22e70a3b4a618040f6517e4b9a3a8c2ce3a4ff5dfa721a7f67c7b6568"
MOZG_BRAIN_IMAGE="postgres:15.14@sha256:822f8795764a670160640888508b2a68ea5c4b045012c2de17e1d0447bdbdc99"
MOZG_MCP_PKG="@g99/lightrag-mcp-server"
MOZG_MCP_VERSION="1.1.0"
# Что даём Гермесу: чтение + запись новых заметок. Удаление/очистку/правку графа — НЕ даём.
MOZG_MCP_TOOLS='["query_text","query_data","insert_text","insert_texts","get_health","get_documents_paginated","get_document_status_counts","get_pipeline_status","get_track_status","search_labels","get_popular_labels","check_entity_exists"]'

BOLD='\033[1m'
GRAY='\033[0;90m'
info()   { echo -e "  ${GREEN}✓${NC} $*"; }
hint()   { echo -e "  ${GRAY}$*${NC}"; }
header() { echo -e "\n${BOLD}$*${NC}"; }

# ─── Ввод без eval ────────────────────────────────────────────────────────────
# mozg_set ИМЯ ЗНАЧЕНИЕ — присвоение по имени переменной через printf -v (не eval).
# Имя — только из кода модуля, но всё равно проверяем regex'ом.
mozg_set() {
    local __mz_name="$1" __mz_value="$2"
    [[ "$__mz_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "внутренняя ошибка: плохое имя переменной '$__mz_name'"
    printf -v "$__mz_name" '%s' "$__mz_value"
}

# Валидаторы: код 0 = значение годится. Управляющие символы/переводы строк отвергаются везде —
# значения идут в .env, YAML и nginx-конфиг и ломали бы их структуру.
mozg_no_ctrl()        { [[ "$1" != *[[:cntrl:]]* ]]; }
mozg_valid_domain()   { mozg_no_ctrl "$1" && [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{1,62}$ ]]; }
mozg_valid_email()    { mozg_no_ctrl "$1" && [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
mozg_valid_url()      { mozg_no_ctrl "$1" && [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; }
mozg_valid_model()    { mozg_no_ctrl "$1" && [[ "$1" =~ ^[A-Za-z0-9._:/@+-]{1,128}$ ]]; }
mozg_valid_key()      { mozg_no_ctrl "$1" && [[ "$1" =~ ^[A-Za-z0-9._~+/=-]{8,512}$ ]]; }
mozg_valid_dim()      { [[ "$1" =~ ^[0-9]{2,5}$ ]]; }
# Пароль: без пробелов, кавычек, ':', ',', '@', '#', '/' — он идёт в AUTH_ACCOUNTS=логин:пароль,
# в YAML и в строку подключения postgresql://… и там эти символы ломают разбор.
mozg_valid_password() { mozg_no_ctrl "$1" && [[ "$1" =~ ^[A-Za-z0-9_.!-]{8,64}$ ]]; }

# mozg_ask "Вопрос" "дефолт" ИМЯ валидатор "подсказка при ошибке" — видимый ввод
mozg_ask() {
    local __mz_p="$1" __mz_d="$2" __mz_var="$3" __mz_check="$4" __mz_bad="${5:-Неверный формат}"
    local __mz_in
    while true; do
        if [ -n "$__mz_d" ]; then
            read -r -p "$(echo -e "  ${BOLD}${__mz_p}${NC} [${CYAN}${__mz_d}${NC}]: ")" __mz_in
            __mz_in="${__mz_in:-$__mz_d}"
        else
            read -r -p "$(echo -e "  ${BOLD}${__mz_p}${NC}: ")" __mz_in
        fi
        if [ -n "$__mz_in" ] && "$__mz_check" "$__mz_in"; then
            mozg_set "$__mz_var" "$__mz_in"
            return 0
        fi
        err "  $__mz_bad"
    done
}

# mozg_ask_secret "Вопрос" ИМЯ валидатор ["дефолт"] — скрытый ввод (read -s), значение не эхоится
mozg_ask_secret() {
    local __mz_p="$1" __mz_var="$2" __mz_check="$3" __mz_d="${4:-}"
    local __mz_in
    while true; do
        if [ -n "$__mz_d" ]; then
            read -r -s -p "$(echo -e "  ${BOLD}${__mz_p}${NC} [Enter = ${CYAN}${__mz_d}${NC}]: ")" __mz_in
            __mz_in="${__mz_in:-$__mz_d}"
        else
            read -r -s -p "$(echo -e "  ${BOLD}${__mz_p}${NC}: ")" __mz_in
        fi
        echo ""
        if [ -n "$__mz_in" ] && "$__mz_check" "$__mz_in"; then
            mozg_set "$__mz_var" "$__mz_in"
            return 0
        fi
        err "  Неверный формат (пустое значение, пробел или недопустимый символ) — попробуй ещё раз"
    done
}

# mozg_choice "Вопрос" ИМЯ "вариант 1" "вариант 2" ... — номер варианта, Enter = 1
mozg_choice() {
    local __mz_p="$1" __mz_var="$2"
    shift 2
    local __mz_opts=("$@") __mz_i __mz_in
    echo -e "\n  ${BOLD}${__mz_p}${NC}"
    for __mz_i in "${!__mz_opts[@]}"; do
        echo -e "    ${CYAN}$((__mz_i + 1)))${NC} ${__mz_opts[$__mz_i]}"
    done
    while true; do
        read -r -p "$(echo -e "  ${BOLD}Выбор${NC} [1]: ")" __mz_in
        __mz_in="${__mz_in:-1}"
        if [[ "$__mz_in" =~ ^[0-9]+$ ]] && [ "$__mz_in" -ge 1 ] && [ "$__mz_in" -le "${#__mz_opts[@]}" ]; then
            mozg_set "$__mz_var" "$__mz_in"
            return 0
        fi
        err "  Введи число от 1 до ${#__mz_opts[@]}"
    done
}

# mozg_yes "Вопрос" — да по умолчанию (Enter = да)
mozg_yes() {
    local a
    read -r -p "$1 (Y/n): " a
    [[ ! "$a" =~ ^[Nn] ]]
}

# mozg_env_get ФАЙЛ КЛЮЧ — значение KEY=… из .env (последнее), без вывода на экран
mozg_env_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | tail -1
}

# mozg_tail4 СЕКРЕТ — «…abcd» для показа вместо секрета
mozg_tail4() { printf '…%s' "${1: -4}"; }

# mozg_http_check URL [КЛЮЧ] [заголовок] — HTTP-код GET-запроса. Ключ передаётся curl через
# stdin (-K -), а не аргументом: так он не виден в `ps` другим процессам.
mozg_http_check() {
    local url="$1" key="${2:-}" hdr="${3:-Authorization: Bearer}"
    if [ -n "$key" ]; then
        printf 'header = "%s %s"\n' "$hdr" "$key" \
            | curl -s -o /dev/null -m 20 -w '%{http_code}' -K - "$url" 2>/dev/null || true
    else
        curl -s -o /dev/null -m 20 -w '%{http_code}' "$url" 2>/dev/null || true
    fi
}

# mozg_get_key ИМЯ "Название" ИМЯ_В_ai-keys "как получить" URL_провайдера
# Берёт ключ из ~/ai-keys/.env (модуль keys), если он там есть, иначе спрашивает (скрыто).
# Проверяет ключ бесплатным запросом списка моделей (GET /models — данные не отправляются).
mozg_get_key() {
    local __mz_kvar="$1" label="$2" keys_name="$3" how="$4" host="$5"
    local found __mz_key code
    found="$(mozg_env_get "$HOME/ai-keys/.env" "$keys_name")"
    if [ -n "$found" ] && mozg_valid_key "$found" \
        && mozg_yes "  Нашёл ключ ${label} в ~/ai-keys/.env ($(mozg_tail4 "$found")). Взять его?"; then
        __mz_key="$found"
    else
        echo ""
        echo -e "  ${CYAN}${label}${NC}: ${how}"
        mozg_ask_secret "Вставь ключ ${label}" __mz_key mozg_valid_key
    fi
    while true; do
        code="$(mozg_http_check "${host}/models" "$__mz_key")"
        case "$code" in
            200) info "Ключ ${label} принят провайдером"; break ;;
            401|403)
                err "  Провайдер не принял ключ ${label} (HTTP $code)."
                if mozg_yes "  Ввести ключ заново?"; then
                    mozg_ask_secret "Вставь ключ ${label}" __mz_key mozg_valid_key
                    continue
                fi
                warn "Продолжаю с этим ключом — мозг не сможет обрабатывать заметки, пока ключ не заработает"
                break ;;
            *)
                warn "Не удалось проверить ключ ${label} (ответ: ${code:-нет связи}) — продолжаю, проверим на тестовой заметке"
                break ;;
        esac
    done
    mozg_set "$__mz_kvar" "$__mz_key"
}

# ─── Проверка ресурсов ────────────────────────────────────────────────────────
mozg_check_resources() {
    local total_mb avail_mb swap_mb disk_gb
    total_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
    avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)"
    swap_mb="$(free -m | awk '/^Swap:/{print $2}')"
    disk_gb="$(df -Pk /var/lib 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')"

    echo ""
    free -h
    echo ""
    hint "Мозгу нужно: ~0.4–0.6 ГБ RAM в покое (LightRAG ~150 МБ + 2 PostgreSQL ~100–250 МБ),"
    hint "до ~1.5 ГБ в момент загрузки документов. Диск: ~4 ГБ под образы + данные."
    hint "Модели работают у провайдера (Mistral/Google), на сервере нейросеть НЕ запускается."

    if [ "${total_mb:-0}" -lt 1900 ]; then
        warn "На сервере всего ${total_mb} МБ RAM. Для мозга рядом с Гермесом нужно от 2 ГБ, комфортно — 4 ГБ."
        confirm "Всё равно продолжить?" || { warn "Остановился по твоему выбору — ничего не установлено"; exit 0; }
    fi
    if [ "${avail_mb:-0}" -lt 1200 ]; then
        warn "Свободно только ${avail_mb} МБ RAM — при загрузке документов сервер может начать тормозить."
        hint "Посмотри, что ест память: ps aux --sort=-%mem | head"
        if [ "${swap_mb:-0}" -eq 0 ]; then
            ensure_swap 4
        fi
    else
        info "RAM: свободно ${avail_mb} МБ из ${total_mb} МБ — хватает"
    fi
    if [ "${disk_gb:-0}" -lt 6 ]; then
        warn "Свободно на диске ${disk_gb} ГБ, а нужно ~6 ГБ (образы ~4 ГБ + данные)."
        confirm "Всё равно продолжить?" || { warn "Остановился по твоему выбору — ничего не установлено"; exit 0; }
    else
        info "Диск: свободно ${disk_gb} ГБ"
    fi
}

# ─── Docker без curl | sh ─────────────────────────────────────────────────────
# Ставим из официального репозитория Ubuntu (apt, подписанные пакеты), а не get.docker.com | sh.
# В группу docker никого не добавляем (это ≈ root) — модуль и так работает под root.
mozg_ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Docker не найден — ставлю из репозитория Ubuntu (apt: docker.io + docker-compose-v2)"
        apt_ensure docker.io docker-compose-v2
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    if ! docker compose version >/dev/null 2>&1; then
        if dpkg -s docker.io 2>/dev/null | grep -q "^Status:.*installed"; then
            apt_ensure docker-compose-v2
        else
            die "Docker стоит, но без «docker compose». Если ставил Docker с docker.com: apt-get install -y docker-compose-plugin — и запусти модуль снова"
        fi
    fi
    docker info >/dev/null 2>&1 || die "Docker не отвечает. Проверь: systemctl status docker"
    info "Docker $(docker --version | awk '{print $3}' | tr -d ',') + Compose $(docker compose version --short 2>/dev/null || echo ok)"
}

# mozg_port_free ПОРТ КОНТЕЙНЕР — порт свободен или занят нашим же контейнером (повторный запуск)
mozg_port_free() {
    local port="$1" container="$2"
    if ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q .; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container" && return 0
        return 1
    fi
    return 0
}

# ─── Подключение к Гермесу (MCP) ──────────────────────────────────────────────
HERMES_STATUS="не подключён"
mozg_connect_hermes() {
    local api_key="$1"
    local hermes_bin
    hermes_bin="$(command -v hermes 2>/dev/null || true)"
    if [ -z "$hermes_bin" ] && [ -x "$HOME/.local/bin/hermes" ]; then
        hermes_bin="$HOME/.local/bin/hermes"
    fi

    header "9. Подключение мозга к Гермесу"
    if [ -z "$hermes_bin" ] || [ ! -d "$HOME/.hermes" ]; then
        warn "Гермес на этом сервере не найден — пропускаю. Поставишь модуль hermes → запусти mozg ещё раз: всё уже стоящее пропустится, останется только подключение"
        HERMES_STATUS="не подключён (Гермес не установлен)"
        return 0
    fi

    hint "Гермес получит MCP-сервер «mozg» (${MOZG_MCP_PKG}@${MOZG_MCP_VERSION}) с инструментами:"
    hint "  читать:   query_text, query_data, search_labels, get_documents_paginated, статусы"
    hint "  писать:   insert_text, insert_texts — только ДОБАВЛЯТЬ новые заметки"
    hint "  НЕ даём:  delete_*, clear_*, merge/update/create сущностей — удалить память Гермес не сможет"
    hint "Ключ доступа ляжет в ~/.hermes/.env (chmod 600), в config.yaml — только ссылка на него."
    if ! mozg_yes "Подключить мозг к Гермесу?"; then
        HERMES_STATUS="не подключён (по твоему выбору)"
        return 0
    fi

    if ! command -v npm >/dev/null 2>&1; then
        log "Нет npm — ставлю Node.js из репозитория Ubuntu (apt)"
        apt_ensure nodejs npm
    fi
    if ! command -v npm >/dev/null 2>&1; then
        warn "npm не поставился — подключение пропущено. Мозг работает, подключи позже: запусти mozg ещё раз"
        HERMES_STATUS="не подключён (нет npm)"
        return 0
    fi

    local mcp_bin
    mcp_bin="$(npm prefix -g 2>/dev/null)/bin/lightrag-mcp-server"
    if ! npm ls -g --depth=0 "${MOZG_MCP_PKG}@${MOZG_MCP_VERSION}" >/dev/null 2>&1 || [ ! -x "$mcp_bin" ]; then
        log "Ставлю ${MOZG_MCP_PKG}@${MOZG_MCP_VERSION} (точная версия, без install-скриптов)"
        if ! npm install -g --ignore-scripts --no-fund --no-audit "${MOZG_MCP_PKG}@${MOZG_MCP_VERSION}" >/dev/null; then
            warn "npm install не удался — подключение пропущено. Мозг работает, повтори позже: запусти mozg ещё раз"
            HERMES_STATUS="не подключён (ошибка npm install)"
            return 0
        fi
    fi
    [ -x "$mcp_bin" ] || { warn "Не нашёл $mcp_bin после установки — подключение пропущено"; HERMES_STATUS="не подключён (MCP не найден)"; return 0; }
    info "MCP-сервер: $mcp_bin"

    # Ключ — в ~/.hermes/.env (строку заменяем, не дублируем — повторный запуск безопасен)
    local henv="$HOME/.hermes/.env" tmp
    touch "$henv"
    chmod 600 "$henv"
    tmp="$(mktemp)"
    grep -v '^MOZG_LIGHTRAG_API_KEY=' "$henv" > "$tmp" || true
    printf 'MOZG_LIGHTRAG_API_KEY=%s\n' "$api_key" >> "$tmp"
    cat "$tmp" > "$henv"
    rm -f "$tmp"
    info "Ключ записан в ~/.hermes/.env ($(mozg_tail4 "$api_key"))"

    # Бэкап config.yaml до изменения
    if [ -f "$HOME/.hermes/config.yaml" ]; then
        cp -p "$HOME/.hermes/config.yaml" "$HOME/.hermes/config.yaml.bak-mozg-$(date +%Y%m%d-%H%M%S)"
    fi
    local json
    # shellcheck disable=SC2016  # ${env:…} — синтаксис Гермеса, должен попасть в конфиг буквально
    json="$(printf '{"command":"%s","args":[],"env":{"LIGHTRAG_SERVER_URL":"http://127.0.0.1:9621","LIGHTRAG_API_KEY":"${env:MOZG_LIGHTRAG_API_KEY}"},"timeout":180,"tools":{"include":%s,"resources":false,"prompts":false}}' "$mcp_bin" "$MOZG_MCP_TOOLS")"
    if ! "$hermes_bin" config set mcp_servers.mozg "$json"; then
        warn "Гермес не принял настройку — подключение пропущено. Бэкап конфига: ~/.hermes/config.yaml.bak-mozg-*"
        HERMES_STATUS="не подключён (ошибка hermes config set)"
        return 0
    fi
    if "$hermes_bin" mcp test mozg; then
        info "Гермес видит мозг (hermes mcp test mozg)"
        HERMES_STATUS="подключён: MCP «mozg» (чтение + добавление заметок)"
    else
        warn "Проверка не прошла — посмотри вывод выше и повтори: hermes mcp test mozg"
        HERMES_STATUS="настроен, но проверка не прошла (hermes mcp test mozg)"
    fi
    hint "Новые чаты Гермеса увидят мозг сразу. Telegram-бот/диспетчер (служба) — после перезапуска."
    if confirm "Перезапустить службу Гермеса сейчас (Telegram-бот моргнёт на ~10 сек)?"; then
        "$hermes_bin" gateway restart || warn "Не удалось перезапустить — сделай вручную: hermes gateway restart"
    fi
}

# ─── Основной сценарий ────────────────────────────────────────────────────────
run_module() {
    require_root
    unlock_dpkg

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Мозг: LightRAG + PostgreSQL brain      ║${NC}"
    echo -e "${BOLD}║   Память для AI-агентов — бесплатно      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

    local INSTALL_DIR="$HOME/lightrag"
    local ENV_FILE="$INSTALL_DIR/.env"
    local BRAIN_DIR="$HOME/brain"
    # Совместимость с ранними установками
    [ -d "$HOME/oleg_brain" ] && [ ! -d "$BRAIN_DIR" ] && BRAIN_DIR="$HOME/oleg_brain"

    header "1. Проверка сервера"
    mozg_check_resources
    apt_ensure curl openssl iproute2
    mozg_ensure_docker
    mozg_port_free 9621 lightrag-server || die "Порт 9621 занят другой программой — освободи его (ss -ltnp | grep 9621) и запусти снова"

    # ─── 2. Доступ ───
    header "2. Как будешь открывать веб-панель мозга"
    local ACCESS_MODE DOMAIN="" EMAIL="" SERVER_IP
    SERVER_IP="$(curl -fsS -m 10 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
    mozg_choice "Выбери вариант:" ACCESS_MODE \
        "Без домена — через SSH-тоннель (проще и безопаснее, рекомендую)" \
        "Свой домен + https (nginx + Let's Encrypt)"
    if [ "$ACCESS_MODE" = "2" ]; then
        mozg_ask "Домен (например mozg.твой-домен.ru; кириллицу — в punycode xn--…)" "" DOMAIN mozg_valid_domain \
            "Не похоже на домен: только латиница, цифры, точки и дефисы"
        mozg_ask "Email для Let's Encrypt" "" EMAIL mozg_valid_email "Не похоже на email"
    fi

    # ─── 3. Модели ───
    header "3. Нейросеть для мозга (бесплатно)"
    hint "LightRAG сам не «думает»: LLM вытаскивает из текста сущности и связи, эмбеддинги — для поиска."
    hint "Обе модели работают у провайдера по API — на сервер ничего тяжёлого не ставится."

    local MODEL_BLOCK="" LLM_MODEL="" EMBEDDING_MODEL="" PROVIDER_LABEL="" KEEP_MODELS=0
    local OLD_DIM NEW_DIM
    OLD_DIM="$(mozg_env_get "$ENV_FILE" EMBEDDING_DIM)"
    if [ -f "$ENV_FILE" ] && [ -n "$(mozg_env_get "$ENV_FILE" LLM_MODEL)" ]; then
        echo ""
        info "Нашёл прошлую установку: LLM $(mozg_env_get "$ENV_FILE" LLM_MODEL), эмбеддинги $(mozg_env_get "$ENV_FILE" EMBEDDING_MODEL)"
        if mozg_yes "  Оставить модели и ключи как есть?"; then
            KEEP_MODELS=1
            MODEL_BLOCK="$(grep -E '^(LLM_|EMBEDDING_|MAX_ASYNC=|MAX_PARALLEL_INSERT=)' "$ENV_FILE" | grep -v '^LLM_MAX_TOKEN_SIZE=')"
            LLM_MODEL="$(mozg_env_get "$ENV_FILE" LLM_MODEL)"
            EMBEDDING_MODEL="$(mozg_env_get "$ENV_FILE" EMBEDDING_MODEL)"
            PROVIDER_LABEL="как в прошлой установке"
        fi
    fi

    if [ "$KEEP_MODELS" = "0" ]; then
        local PRESET LLM_HOST LLM_KEY EMB_HOST EMB_KEY EMB_DIM MAX_ASYNC EMB_ASYNC
        local MISTRAL_HOW="console.mistral.ai → войти (Google/почта) → план Experiment (бесплатный, без карты, нужен номер телефона) → API Keys → Create new key"
        local GOOGLE_HOW="aistudio.google.com → Get API key → Create API key (без карты). Пишет «недоступно в регионе» — заходи через VPN"
        mozg_choice "Чем мозг будет обрабатывать заметки?" PRESET \
            "Mistral — ОДИН бесплатный ключ на всё (рекомендую)" \
            "Google AI Studio (Gemini, LLM) + Mistral (эмбеддинги) — два бесплатных ключа" \
            "Свой OpenAI-совместимый провайдер (OpenRouter, Polza, OmniRoute, OpenAI…)"
        case "$PRESET" in
            1)
                LLM_HOST="https://api.mistral.ai/v1"
                mozg_get_key LLM_KEY "Mistral" MISTRAL_API_KEY "$MISTRAL_HOW" "$LLM_HOST"
                LLM_MODEL="mistral-small-latest"
                EMB_HOST="$LLM_HOST"; EMB_KEY="$LLM_KEY"
                EMBEDDING_MODEL="mistral-embed"; EMB_DIM=1024
                # Бесплатный Mistral — ~1 запрос/сек на ключ: всё по одному, иначе 429
                MAX_ASYNC=1; EMB_ASYNC=1
                PROVIDER_LABEL="Mistral (бесплатный тариф Experiment)"
                ;;
            2)
                LLM_HOST="https://generativelanguage.googleapis.com/v1beta/openai"
                mozg_get_key LLM_KEY "Google AI Studio" GOOGLE_AI_STUDIO_KEY "$GOOGLE_HOW" "$LLM_HOST"
                LLM_MODEL="gemini-2.5-flash-lite"
                EMB_HOST="https://api.mistral.ai/v1"
                mozg_get_key EMB_KEY "Mistral" MISTRAL_API_KEY "$MISTRAL_HOW" "$EMB_HOST"
                EMBEDDING_MODEL="mistral-embed"; EMB_DIM=1024
                MAX_ASYNC=2; EMB_ASYNC=2
                PROVIDER_LABEL="Google AI Studio (LLM) + Mistral (эмбеддинги), бесплатные тарифы"
                ;;
            3)
                hint "Нужен OpenAI-совместимый адрес (…/v1), где есть и чат-модель, и модель эмбеддингов."
                mozg_ask "Адрес API (LLM)" "https://openrouter.ai/api/v1" LLM_HOST mozg_valid_url "Нужен адрес вида https://host/v1"
                mozg_ask_secret "Ключ API (LLM)" LLM_KEY mozg_valid_key
                mozg_ask "LLM модель" "google/gemini-2.5-flash-lite" LLM_MODEL mozg_valid_model "Недопустимые символы в имени модели"
                mozg_ask "Адрес API (эмбеддинги)" "$LLM_HOST" EMB_HOST mozg_valid_url "Нужен адрес вида https://host/v1"
                if [ "$EMB_HOST" = "$LLM_HOST" ]; then
                    EMB_KEY="$LLM_KEY"
                else
                    mozg_ask_secret "Ключ API (эмбеддинги)" EMB_KEY mozg_valid_key
                fi
                mozg_ask "Модель эмбеддингов" "openai/text-embedding-3-small" EMBEDDING_MODEL mozg_valid_model "Недопустимые символы в имени модели"
                mozg_ask "Размерность эмбеддингов (text-embedding-3-small = 1536, mistral-embed = 1024)" "1536" EMB_DIM mozg_valid_dim "Нужно число"
                MAX_ASYNC=2; EMB_ASYNC=2
                PROVIDER_LABEL="свой провайдер: $LLM_HOST"
                ;;
        esac
        NEW_DIM="$EMB_DIM"
        if [ -n "$OLD_DIM" ] && [ "$OLD_DIM" != "$NEW_DIM" ] \
            && docker volume ls --format '{{.Name}}' | grep -qx 'lightrag_postgres_data'; then
            warn "В базе мозга уже лежат векторы размерности $OLD_DIM, а новая модель эмбеддингов даёт $NEW_DIM."
            warn "Со старыми заметками LightRAG работать не сможет. Либо оставь прежнюю модель (запусти модуль заново),"
            warn "либо удали базу вручную (УДАЛИТ ВСЕ знания): cd ~/lightrag && docker compose down -v"
            confirm "Всё равно продолжить с новой моделью?" || { warn "Остановился — ничего не изменено"; exit 0; }
        fi
        MODEL_BLOCK="LLM_BINDING=openai
LLM_BINDING_HOST=${LLM_HOST}
LLM_BINDING_API_KEY=${LLM_KEY}
LLM_MODEL=${LLM_MODEL}
EMBEDDING_BINDING=openai
EMBEDDING_BINDING_HOST=${EMB_HOST}
EMBEDDING_BINDING_API_KEY=${EMB_KEY}
EMBEDDING_MODEL=${EMBEDDING_MODEL}
EMBEDDING_DIM=${EMB_DIM}
EMBEDDING_MAX_TOKEN_SIZE=8192
EMBEDDING_FUNC_MAX_ASYNC=${EMB_ASYNC}
MAX_ASYNC=${MAX_ASYNC}
MAX_PARALLEL_INSERT=1"
    fi

    # ─── 4. Секреты ───
    header "4. Доступы"
    local LIGHTRAG_API_KEY TOKEN_SECRET ADMIN_LOGIN="admin" ADMIN_PASSWORD OLD_PASSWORD DEFAULT_PASSWORD
    # Машинные секреты: случайные; при повторном запуске — прежние (иначе отвалятся Гермес/Claude Code)
    LIGHTRAG_API_KEY="$(mozg_env_get "$ENV_FILE" LIGHTRAG_API_KEY)"
    [ -n "$LIGHTRAG_API_KEY" ] || LIGHTRAG_API_KEY="$(openssl rand -hex 32)"
    TOKEN_SECRET="$(mozg_env_get "$ENV_FILE" TOKEN_SECRET)"
    [ -n "$TOKEN_SECRET" ] || TOKEN_SECRET="$(openssl rand -hex 32)"
    OLD_PASSWORD="$(mozg_env_get "$ENV_FILE" AUTH_ACCOUNTS)"
    OLD_PASSWORD="${OLD_PASSWORD#*:}"
    if [ -n "$OLD_PASSWORD" ] && mozg_valid_password "$OLD_PASSWORD"; then
        DEFAULT_PASSWORD="$OLD_PASSWORD"
    elif [ "$ACCESS_MODE" = "2" ]; then
        # С доменом панель видна всему интернету — учебный пароль из публичного README не годится
        DEFAULT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
        hint "С доменом панель открыта в интернет — по умолчанию предлагаю случайный пароль."
    else
        DEFAULT_PASSWORD="Mozg_2026!"
    fi
    hint "Пароль: 8–64 символа, латиница, цифры и _ . ! -"
    mozg_ask_secret "Пароль для входа в веб-панель (логин admin)" ADMIN_PASSWORD mozg_valid_password "$DEFAULT_PASSWORD"
    info "Ключ API мозга и JWT-секрет: $( [ -f "$ENV_FILE" ] && echo 'взяты из прошлой установки' || echo 'сгенерированы')"

    # ─── 5. Конфиги ───
    header "5. Конфиги"
    mkdir -p "$INSTALL_DIR"
    local CORS_ORIGINS="*"
    [ -n "$DOMAIN" ] && CORS_ORIGINS="https://${DOMAIN}"

    cat > "$INSTALL_DIR/docker-compose.yml" << COMPOSE_EOF
# Создано freemind-setup (модуль mozg). Образы пиннуты по digest.
services:
  # ─── PostgreSQL (pgvector + Apache AGE) — хранилище LightRAG, наружу не открыт ───
  postgres:
    image: ${MOZG_RAGPG_IMAGE}
    container_name: lightrag-postgres
    restart: unless-stopped
    mem_limit: 768m
    environment:
      POSTGRES_USER: rag
      POSTGRES_PASSWORD: rag
      POSTGRES_DB: rag
    volumes:
      - postgres_data:/var/lib/postgresql
    networks:
      - lightrag-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U rag"]
      interval: 5s
      timeout: 5s
      retries: 10

  # ─── LightRAG Server — только localhost; снаружи через nginx или SSH-тоннель ───
  lightrag:
    image: ${MOZG_LIGHTRAG_IMAGE}
    container_name: lightrag-server
    restart: unless-stopped
    mem_limit: 1536m
    depends_on:
      postgres:
        condition: service_healthy
    env_file: .env
    ports:
      - "127.0.0.1:9621:9621"
    volumes:
      - rag_storage:/app/data/rag_storage
      - inputs:/app/data/inputs
    networks:
      - lightrag-net

volumes:
  postgres_data:
  rag_storage:
  inputs:

networks:
  lightrag-net:
    driver: bridge
COMPOSE_EOF
    info "$INSTALL_DIR/docker-compose.yml"

    (
        umask 077
        cat > "$ENV_FILE" << ENV_EOF
# Создано freemind-setup (модуль mozg). Секреты — не публиковать, файл chmod 600.
# ─── LLM + эмбеддинги ───────────────────────────────────────
${MODEL_BLOCK}
LLM_MAX_TOKEN_SIZE=32768
SUMMARY_LANGUAGE=Russian

# ─── PostgreSQL (внутренний, наружу не открыт) ──────────────
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=rag
POSTGRES_PASSWORD=rag
POSTGRES_DATABASE=rag
LIGHTRAG_KV_STORAGE=PGKVStorage
LIGHTRAG_VECTOR_STORAGE=PGVectorStorage
LIGHTRAG_GRAPH_STORAGE=PGGraphStorage
LIGHTRAG_DOC_STATUS_STORAGE=PGDocStatusStorage

# ─── Авторизация ────────────────────────────────────────────
LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY}
AUTH_ACCOUNTS=${ADMIN_LOGIN}:${ADMIN_PASSWORD}
TOKEN_SECRET=${TOKEN_SECRET}
TOKEN_EXPIRE_HOURS=48
CORS_ORIGINS=${CORS_ORIGINS}
WHITELIST_PATHS=/health

# ─── Сервер ─────────────────────────────────────────────────
PORT=9621
HOST=0.0.0.0
LOG_LEVEL=INFO
TIMEOUT=150
ENV_EOF
    )
    chmod 600 "$ENV_FILE"
    info "$ENV_FILE (chmod 600)"

    # ─── 6. Запуск LightRAG ───
    header "6. Запуск LightRAG (первый раз качает ~3.5 ГБ образов — 2–10 минут)"
    docker compose -f "$INSTALL_DIR/docker-compose.yml" pull \
        || die "Не удалось скачать образы. Проверь интернет и место на диске (df -h), потом запусти модуль снова"
    docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d --remove-orphans \
        || die "Не удалось запустить контейнеры. Смотри: cd ~/lightrag && docker compose logs --tail 50"

    local i ok_flag=0
    echo -ne "  Жду LightRAG..."
    for i in $(seq 1 60); do
        if curl -sf -m 5 http://127.0.0.1:9621/health >/dev/null 2>&1; then
            ok_flag=1
            break
        fi
        echo -n "."
        sleep 3
    done
    if [ "$ok_flag" = "1" ]; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}таймаут${NC}"
        die "LightRAG не ответил за 3 минуты. Смотри: cd ~/lightrag && docker compose logs --tail 50 lightrag"
    fi

    if [ -n "$DOMAIN" ]; then
        ensure_ufw
        setup_nginx_site "mozg" "$DOMAIN" "9621" "$EMAIL" \
            "client_max_body_size 50m; proxy_read_timeout 300s; proxy_send_timeout 300s;"
    fi

    # ─── 7. Проверка сквозняком: заметка → LLM + эмбеддинги → поиск ───
    header "7. Проверка мозга на тестовой заметке"
    local SELFTEST="не проводилась"
    if mozg_yes "Проверить, что мозг реально запоминает (1 короткая заметка, ~1–3 мин, бесплатный лимит)?"; then
        SELFTEST="$(mozg_selftest "$LIGHTRAG_API_KEY")"
        case "$SELFTEST" in
            ok*) info "Мозг запомнил и нашёл тестовую заметку — LLM и эмбеддинги работают" ;;
            *)   warn "Проверка: $SELFTEST"
                 hint "Частые причины: ключ не активирован, лимит бесплатного тарифа, у Mistral не подтверждён телефон."
                 hint "Логи: cd ~/lightrag && docker compose logs --tail 80 lightrag | grep -iE 'error|429|401'" ;;
        esac
    fi

    # ─── 8. PostgreSQL brain ───
    header "8. Второе полушарие — PostgreSQL brain (таблицы: клиенты, подписчики, метрики, факты)"
    hint "LightRAG — смыслы и связи. Brain — точные цифры (сколько, когда, сумма)."
    local BRAIN_PASSWORD="" BRAIN_STATUS="не установлен (по твоему выбору)"
    if mozg_yes "Ставим PostgreSQL brain?"; then
        mozg_port_free 5433 brain-postgres || die "Порт 5433 занят другой программой — освободи его (ss -ltnp | grep 5433) и запусти снова"
        mkdir -p "$BRAIN_DIR"
        BRAIN_PASSWORD="$(mozg_env_get "$BRAIN_DIR/.env" BRAIN_PASSWORD)"
        if [ -d "$BRAIN_DIR/data" ] && [ -n "$(ls -A "$BRAIN_DIR/data" 2>/dev/null)" ]; then
            # База уже создана — пароль внутри неё, переменная окружения его больше не меняет
            if [ -z "$BRAIN_PASSWORD" ]; then
                BRAIN_PASSWORD="$(sed -n 's/^ *POSTGRES_PASSWORD: *//p' "$BRAIN_DIR/docker-compose.yml" 2>/dev/null | tail -1)"
            fi
            mozg_valid_password "$BRAIN_PASSWORD" || BRAIN_PASSWORD="Mozg_2026!"
            info "База brain уже есть — оставляю её и прежний пароль (смена пароля — см. PASSWORDS.md)"
        else
            local BRAIN_DEFAULT="Mozg_2026!"
            [ "$ACCESS_MODE" = "2" ] && BRAIN_DEFAULT="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
            mozg_valid_password "$BRAIN_PASSWORD" && BRAIN_DEFAULT="$BRAIN_PASSWORD"
            mozg_ask_secret "Пароль для PostgreSQL brain (пользователь brain)" BRAIN_PASSWORD mozg_valid_password "$BRAIN_DEFAULT"
        fi
        (
            umask 077
            printf 'BRAIN_PASSWORD=%s\n' "$BRAIN_PASSWORD" > "$BRAIN_DIR/.env"
        )
        chmod 600 "$BRAIN_DIR/.env"

        # init.sql читает postgres внутри контейнера (не root) — файл должен быть читаемым (644)
        cat > "$BRAIN_DIR/init.sql" << 'SQL_EOF'
-- База brain — точные данные: клиенты, подписчики, метрики, факты
CREATE TABLE IF NOT EXISTS clients (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    telegram VARCHAR(255),
    status VARCHAR(50),
    tariff VARCHAR(100),
    price DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS subscribers (
    id SERIAL PRIMARY KEY,
    telegram_id BIGINT,
    bot VARCHAR(100),
    joined_date TIMESTAMP DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS analytics (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    value DECIMAL(15,2),
    period VARCHAR(50),
    project VARCHAR(100),
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS key_facts (
    id SERIAL PRIMARY KEY,
    category VARCHAR(100),
    key VARCHAR(255),
    value TEXT,
    updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_subscribers_bot ON subscribers(bot);
CREATE INDEX IF NOT EXISTS idx_subscribers_joined ON subscribers(joined_date);
CREATE INDEX IF NOT EXISTS idx_analytics_project ON analytics(project);
CREATE INDEX IF NOT EXISTS idx_analytics_period ON analytics(period);
CREATE INDEX IF NOT EXISTS idx_key_facts_category ON key_facts(category);
CREATE INDEX IF NOT EXISTS idx_clients_status ON clients(status);
INSERT INTO key_facts (category, key, value) VALUES ('system', 'setup_date', NOW()::TEXT);
SQL_EOF
        chmod 644 "$BRAIN_DIR/init.sql"

        # Пароль — подстановкой из .env рядом (docker compose читает его сам), не в теле YAML
        cat > "$BRAIN_DIR/docker-compose.yml" << COMPOSE_EOF
# Создано freemind-setup (модуль mozg). Пароль — в .env рядом (chmod 600).
services:
  brain-postgres:
    image: ${MOZG_BRAIN_IMAGE}
    container_name: brain-postgres
    restart: unless-stopped
    mem_limit: 384m
    environment:
      POSTGRES_USER: brain
      POSTGRES_PASSWORD: \${BRAIN_PASSWORD}
      POSTGRES_DB: brain
    volumes:
      - ./data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "127.0.0.1:5433:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U brain -d brain"]
      interval: 5s
      timeout: 5s
      retries: 10
COMPOSE_EOF

        if docker compose -f "$BRAIN_DIR/docker-compose.yml" up -d; then
            echo -ne "  Жду PostgreSQL brain..."
            ok_flag=0
            for i in $(seq 1 30); do
                if docker exec brain-postgres pg_isready -U brain -d brain >/dev/null 2>&1; then
                    ok_flag=1
                    break
                fi
                echo -n "."
                sleep 2
            done
            if [ "$ok_flag" = "1" ]; then
                echo -e " ${GREEN}✓${NC}"
                BRAIN_STATUS="работает: 127.0.0.1:5433, база brain"
            else
                echo -e " ${RED}таймаут${NC}"
                warn "brain-postgres ещё запускается — проверь: docker logs brain-postgres"
                BRAIN_STATUS="запущен, но не подтверждён (docker logs brain-postgres)"
            fi
        else
            warn "Не удалось запустить brain-postgres — LightRAG при этом работает. Смотри: docker logs brain-postgres"
            BRAIN_STATUS="ошибка запуска (docker logs brain-postgres)"
        fi
    fi

    # ─── 9. Гермес ───
    mozg_connect_hermes "$LIGHTRAG_API_KEY"

    # ─── Итог ───
    local ACCESS_HOWTO BRAIN_LINES PASS_LINES
    if [ -n "$DOMAIN" ]; then
        ACCESS_HOWTO="Веб-панель:   https://${DOMAIN}"
    else
        ACCESS_HOWTO="Веб-панель:   на своём компьютере в отдельном окне терминала:
                ssh -L 9621:localhost:9621 root@${SERVER_IP}
              потом в браузере: http://localhost:9621"
    fi
    if [ -n "$BRAIN_PASSWORD" ]; then
        BRAIN_LINES="Статус:       ${BRAIN_STATUS}
Подключение:  postgresql://brain:${BRAIN_PASSWORD}@127.0.0.1:5433/brain
Консоль:      docker exec -it brain-postgres psql -U brain -d brain
Таблицы:      clients, subscribers, analytics, key_facts"
        PASS_LINES="   Brain:    см. раздел «Мозг — PostgreSQL brain» в PASSWORDS.md (папка ${BRAIN_DIR})"
    else
        BRAIN_LINES="Статус:       ${BRAIN_STATUS}"
        PASS_LINES=""
    fi

    # shellcheck disable=SC2016  # $(sed …) должен остаться буквально — выполнится у студента при копипасте
    local KEY_FROM_FILE='$(sed -n "s/^LIGHTRAG_API_KEY=//p" ~/lightrag/.env)'
    local CLAUDE_CMD
    CLAUDE_CMD="$(printf '%s \\\n  %s \\\n  %s \\\n  %s' \
        "claude mcp add --scope user lightrag" \
        "-e LIGHTRAG_SERVER_URL=http://127.0.0.1:9621" \
        "-e LIGHTRAG_API_KEY=\"${KEY_FROM_FILE}\"" \
        "-- npx -y ${MOZG_MCP_PKG}@${MOZG_MCP_VERSION}")"
    save_credentials "$HOME/mozg-credentials.txt" "$(cat << CREDS_EOF
╔══════════════════════════════════════════════════════════════╗
║  Мозг (LightRAG + PostgreSQL brain) — установлено              ║
╚══════════════════════════════════════════════════════════════╝

── Полушарие 1: LightRAG (смыслы, контекст, связи) ──
${ACCESS_HOWTO}
Логин:        ${ADMIN_LOGIN}
Пароль:       ${ADMIN_PASSWORD}
API для агентов: http://127.0.0.1:9621 (с этого сервера), ключ в ~/lightrag/.env ($(mozg_tail4 "$LIGHTRAG_API_KEY"))
Нейросеть:    ${PROVIDER_LABEL}
LLM / эмбед.: ${LLM_MODEL} / ${EMBEDDING_MODEL}
Самопроверка: ${SELFTEST}

── Полушарие 2: PostgreSQL brain (точные цифры) ──
${BRAIN_LINES}

── Гермес ──
${HERMES_STATUS}
Проверить:    hermes mcp test mozg
Попробуй в чате: «Запомни в мозг: я записался на Нейроспринт» → потом «Что мозг знает про Нейроспринт?»

── Claude Code на этом же сервере (по желанию) ──
${CLAUDE_CMD}

── Управление ──
Логи:         cd ~/lightrag && docker compose logs --tail 50 lightrag
Перезапуск:   cd ~/lightrag && docker compose restart
Память:       docker stats --no-stream

⚠️ Пароли учебные — смени после урока (точные команды — PASSWORDS.md):
   LightRAG: sed -i "s|^AUTH_ACCOUNTS=.*|AUTH_ACCOUNTS=admin:НОВЫЙ_ПАРОЛЬ|" ~/lightrag/.env && cd ~/lightrag && docker compose up -d
${PASS_LINES}
CREDS_EOF
)"
}

# mozg_selftest КЛЮЧ — кладёт короткую заметку и ждёт её обработки. Печатает итог одной строкой.
# Текст фиксированный: при повторном запуске LightRAG узнаёт дубль и не тратит лимит заново.
mozg_selftest() {
    local key="$1" resp track status i
    local note="Тестовая заметка freemind-setup: мозг FreeMind установлен и умеет запоминать. Кодовое слово проверки — Бобёр-Навигатор."
    resp="$(printf 'header = "X-API-Key: %s"\n' "$key" | curl -s -m 30 -K - \
        -H 'Content-Type: application/json' \
        -d "{\"text\": \"${note}\", \"file_source\": \"freemind-setup-selftest\"}" \
        http://127.0.0.1:9621/documents/text 2>/dev/null || true)"
    if echo "$resp" | grep -q '"duplicated"'; then
        echo "ok (заметка уже была в мозге с прошлой установки)"
        return 0
    fi
    track="$(echo "$resp" | grep -o '"track_id": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ -z "$track" ]; then
        echo "не удалось добавить заметку (ответ сервера: ${resp:0:120})"
        return 0
    fi
    for i in $(seq 1 60); do
        status="$(printf 'header = "X-API-Key: %s"\n' "$key" | curl -s -m 15 -K - \
            "http://127.0.0.1:9621/documents/track_status/${track}" 2>/dev/null || true)"
        if echo "$status" | grep -qi '"processed"'; then
            echo "ok (заметка обработана за ~$((i * 5)) с)"
            return 0
        fi
        if echo "$status" | grep -qi '"failed"'; then
            echo "заметка НЕ обработана — провайдер нейросети вернул ошибку: $(echo "$status" | grep -o '"error_msg": *"[^"]*"' | head -1 | cut -c1-160)"
            return 0
        fi
        sleep 5
    done
    echo "не дождался обработки за 5 минут (медленный бесплатный лимит?) — проверь позже в веб-панели, вкладка Documents"
}
