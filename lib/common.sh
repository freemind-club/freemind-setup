#!/usr/bin/env bash
# freemind-setup/lib/common.sh — общие функции для всех модулей
# Подключается через `source`, не запускается напрямую.

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

die() {
    err "$*"
    exit 1
}

step() {
    echo ""
    echo -e "${CYAN}━━━ $* ━━━${NC}"
}

# ask "Вопрос" "default_value" -> печатает ответ в stdout, дефолт если Enter
ask() {
    local prompt="$1"
    local default="${2:-}"
    local answer
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "$prompt: " answer
        echo "$answer"
    fi
}

# ask_secret "Вопрос" ["default"] -> ввод без эха на экран (пароли). Enter = дефолт, если задан.
ask_secret() {
    local prompt="$1"
    local default="${2:-}"
    local answer
    if [ -n "$default" ]; then
        read -r -s -p "$prompt [Enter = $default]: " answer
        echo "" >&2
        echo "${answer:-$default}"
    else
        read -r -s -p "$prompt: " answer
        echo "" >&2
        echo "$answer"
    fi
}

# confirm "Вопрос" -> код возврата 0 = да, 1 = нет. По умолчанию "нет".
confirm() {
    local prompt="$1"
    local answer
    read -r -p "$prompt (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Нужен root."
    fi
}

# unlock_dpkg — на свежесозданном VPS unattended-upgrades может держать dpkg
# заблокированным первые 1-2 минуты. Без этого первый apt-get падает непонятной ошибкой.
unlock_dpkg() {
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        warn "dpkg занят (свежий сервер ещё обновляется сам) — снимаем блокировку"
        systemctl stop unattended-upgrades 2>/dev/null || true
        kill "$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null)" 2>/dev/null || true
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
        dpkg --configure -a 2>/dev/null || true
    fi
}

ensure_node() {
    if command -v node >/dev/null 2>&1; then
        ok "Node.js $(node --version) уже стоит"
        return 0
    fi
    log "Ставим Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
    apt-get install -y nodejs
    ok "Node.js $(node --version) установлен"
}

# save_credentials "путь" "содержимое" — пишет файл с chmod 600 + печатает где лежит.
# Единый паттерн "готовые настройки для сохранения" во всех модулях.
save_credentials() {
    local path="$1"
    local content="$2"
    echo "$content" > "$path"
    chmod 600 "$path"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "$content"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    ok "Сохранено в $path (chmod 600) — скопируй себе в надёжное место"
}

apt_ensure() {
    # apt_ensure pkg1 pkg2 ... — ставит только то, чего ещё нет.
    # ВАЖНО: используем `dpkg -s` (Status: install ok installed), а НЕ `dpkg -l` —
    # `dpkg -l` возвращает 0 даже для пакета в статусе rc (удалён, конфиги остались),
    # из-за чего пакет считался "уже стоит" и реально не ставился (баг, найденный вживую).
    local missing=()
    for pkg in "$@"; do
        dpkg -s "$pkg" 2>/dev/null | grep -q "^Status:.*installed" || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log "Ставим: ${missing[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

# ensure_swap [размер_в_GB] — критично на тарифах 1-2 ГБ RAM (студенческий тариф)
ensure_swap() {
    local size_gb="${1:-4}"
    local current_swap
    current_swap="$(free -m | awk '/^Swap:/{print $2}')"
    if [ "${current_swap:-0}" -gt 0 ]; then
        ok "Своп уже есть ($(free -h | awk '/^Swap:/{print $2}'))"
        return 0
    fi
    warn "Свопа нет. На тарифах 1-2 ГБ RAM сборки (Node/npm, Docker) могут падать по OOM."
    if confirm "Добавить своп ${size_gb}ГБ сейчас?"; then
        fallocate -l "${size_gb}G" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Своп ${size_gb}ГБ добавлен"
    else
        warn "Пропускаем своп по твоему выбору — если сборка упадёт по памяти, вернись и добавь его вручную."
    fi
}

# collect_api_key VAR_NAME "Название" "URL регистрации" "формат ключа" -> пишет в $env_file, копит в $configured
# Вызывающий модуль обязан объявить (без local внутри самой функции, но local в run_module):
#   local env_file=...   -- куда писать KEY=value
#   local -a configured=()  -- список названий для итоговой сводки
collect_api_key() {
    local var_name="$1" label="$2" url="$3" hint="$4"
    echo ""
    echo -e "  ${CYAN}${label}${NC} — ${url}"
    if confirm "  Зарегистрировался и есть ключ?"; then
        local val
        val="$(ask_secret "  Вставь ключ ($hint)")"
        if [ -n "$val" ]; then
            echo "${var_name}=${val}" >> "$env_file"
            configured+=("$label")
        fi
    fi
}

# wait_for_dns "домен" "ожидаемый_ip" — ждёт пока A-запись разойдётся, с ручным выходом
wait_for_dns() {
    local domain="$1"
    local expected_ip="$2"
    local resolved
    while true; do
        resolved="$(dig +short "$domain" | tail -1)"
        if [ "$resolved" = "$expected_ip" ]; then
            ok "DNS $domain → $expected_ip подтверждён"
            return 0
        fi
        warn "$domain пока резолвится в '${resolved:-<пусто>}', ждём $expected_ip"
        if ! confirm "Подождать ещё 15 секунд и проверить снова?"; then
            warn "Продолжаем без подтверждённого DNS — certbot может упасть, это нормально, повтори позже: certbot --nginx -d $domain"
            return 1
        fi
        sleep 15
    done
}

# nginx_site "имя_конфига" "домен" "локальный_порт" — общий реверс-прокси конфиг + certbot
# используется и VPN-панелью, и дашбордом Hermes — один nginx на весь сервер
setup_nginx_site() {
    local name="$1"
    local domain="$2"
    local local_port="$3"
    local email="$4"

    apt_ensure nginx certbot python3-certbot-nginx

    cat > "/etc/nginx/sites-available/$name" << EOF
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:$local_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    ln -sf "/etc/nginx/sites-available/$name" "/etc/nginx/sites-enabled/$name"
    nginx -t
    systemctl reload nginx

    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true

    local server_ip
    server_ip="$(curl -fsSL ifconfig.me || hostname -I | awk '{print $1}')"
    if wait_for_dns "$domain" "$server_ip"; then
        certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" --redirect
        ok "https://$domain готов"
    else
        warn "SSL не выпущен — DNS не подтверждён. Панель пока доступна только по http://$server_ip:$local_port"
    fi
}
