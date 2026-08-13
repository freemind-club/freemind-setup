#!/usr/bin/env bash
# freemind-setup/modules/mozg.sh — LightRAG ("мозг" памяти для AI-агентов)
# Адаптировано из 00_claude/lightrag/server/install.sh (уже проверенный автоустановщик).
# Подключается через install.sh, использует функции из lib/common.sh для базовых
# вещей (root/dpkg), но использует собственные ask_*/info/warn/error/header —
# это самостоятельный, самодостаточный установщик почти без изменений.

run_module() {

require_root
unlock_dpkg

BOLD='\033[1m'
GRAY='\033[0;90m'

info()  { echo -e "  ${GREEN}✓${NC} $1"; }
error() { echo -e "  ${RED}✗${NC} $1"; }
hint()  { echo -e "  ${GRAY}$1${NC}"; }
header(){ echo -e "\n${BOLD}$1${NC}"; }

ask_default() {
  local prompt="$1" default="$2" varname="$3"
  local val
  read -r -p "$(echo -e "  ${BOLD}${prompt}${NC} [${CYAN}${default}${NC}]: ")" val
  eval "${varname}='${val:-$default}'"
}

ask_required() {
  local prompt="$1" varname="$2"
  local val=""
  while [ -z "$val" ]; do
    read -r -p "$(echo -e "  ${BOLD}${prompt}${NC}: ")" val
    [ -z "$val" ] && error "Это обязательное поле"
  done
  eval "${varname}='${val}'"
}

ask_choice() {
  local prompt="$1" varname="$2"
  shift 2
  local options=("$@")
  echo -e "\n  ${BOLD}${prompt}${NC}"
  for i in "${!options[@]}"; do
    echo -e "    ${CYAN}$((i+1)))${NC} ${options[$i]}"
  done
  local choice
  while true; do
    read -r -p "$(echo -e "  ${BOLD}Выбор${NC} [1]: ")" choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
      eval "${varname}=${choice}"
      return
    fi
    error "Введи число от 1 до ${#options[@]}"
  done
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     LightRAG — Установка и настройка     ║${NC}"
echo -e "${BOLD}║     База знаний для AI-агентов (мозг)    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

header "1. Проверка системы"

OS="linux"
if [[ "$OSTYPE" == "darwin"* ]]; then
  OS="macos"
  info "macOS обнаружена"
else
  info "Linux обнаружена"
fi

if command -v docker &> /dev/null; then
  info "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
else
  warn "Docker не найден — устанавливаю..."
  if [ "$OS" = "macos" ]; then
    error "На macOS установи Docker Desktop вручную: https://docker.com/products/docker-desktop"
    exit 1
  fi
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  info "Docker установлен"
fi

if docker compose version &> /dev/null; then
  info "Docker Compose: $(docker compose version --short 2>/dev/null || echo 'ok')"
else
  error "Docker Compose не найден. Обнови Docker."
  exit 1
fi

if command -v openssl &> /dev/null; then
  info "openssl доступен"
else
  error "openssl не найден — установи: sudo apt install openssl"
  exit 1
fi

header "2. Настройка"

ask_choice "Где устанавливаем?" INSTALL_MODE \
  "Сервер с доменом (VPS)" \
  "Локально (Mac Mini / localhost)"

DOMAIN=""
PROXY_MODE=4
LIGHTRAG_URL=""

if [ "$INSTALL_MODE" = "1" ]; then
  echo ""
  ask_required "Домен (например lrag.example.com)" DOMAIN
  LIGHTRAG_URL="https://${DOMAIN}"

  ask_choice "Reverse proxy для SSL:" PROXY_MODE \
    "Caddy — добавить к существующему" \
    "Caddy — установить новый (Docker)" \
    "Nginx Proxy Manager — настрою сам" \
    "Без прокси (только localhost:9621)"
else
  LIGHTRAG_URL="http://localhost:9621"
  info "URL: ${LIGHTRAG_URL}"
fi

echo ""
header "3. API провайдер"
hint "LightRAG использует LLM для извлечения сущностей из текста."
hint "Нужен OpenAI-совместимый API."
echo ""
hint "Популярные провайдеры:"
hint "  Polza.ai:   https://polza.ai/api/v1"
hint "  OpenRouter:  https://openrouter.ai/api/v1"
hint "  OpenAI:      https://api.openai.com/v1"
echo ""

ask_default "API endpoint" "https://polza.ai/api/v1" API_HOST
ask_required "API ключ" API_KEY

echo ""
header "4. Модели"
hint "LLM — для извлечения сущностей (главное — качество)"
hint "Embedding — для векторного поиска"
echo ""

ask_default "LLM модель" "google/gemini-2.5-flash" LLM_MODEL
ask_default "Embedding модель" "openai/text-embedding-3-small" EMBEDDING_MODEL

CADDY_FILE_PATH=""
if [ "$PROXY_MODE" = "1" ]; then
  echo ""
  ask_default "Путь к существующему Caddyfile" "/etc/caddy/Caddyfile" CADDY_FILE_PATH
fi

header "5. Генерация секретов"

LIGHTRAG_API_KEY=$(openssl rand -hex 32)
TOKEN_SECRET=$(openssl rand -hex 32)
ADMIN_SUFFIX=$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $((RANDOM % 9000 + 1000)))
ADMIN_LOGIN="lrag_admin_${ADMIN_SUFFIX}"
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)

info "API ключ сгенерирован"
info "JWT секрет сгенерирован"
info "Логин: ${ADMIN_LOGIN}"
info "Пароль сгенерирован (16 символов)"

header "6. Создание конфигов"

INSTALL_DIR="${HOME}/lightrag"
mkdir -p "${INSTALL_DIR}"

COMPOSE_CADDY_SERVICE=""
COMPOSE_CADDY_VOLUMES=""
COMPOSE_PORTS='      - "127.0.0.1:9621:9621"'

if [ "$PROXY_MODE" = "2" ]; then
  COMPOSE_PORTS='    expose:
      - "9621"'
  COMPOSE_CADDY_SERVICE="
  # ─── Caddy (reverse proxy + авто-SSL) ───
  caddy:
    image: caddy:2-alpine
    container_name: lightrag-caddy
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - lightrag-net"
  COMPOSE_CADDY_VOLUMES="
  caddy_data:
  caddy_config:"
fi

cat > "${INSTALL_DIR}/docker-compose.yml" << COMPOSE_EOF
services:
  # ─── PostgreSQL (pgvector + Apache AGE) ───
  postgres:
    image: gzdaniel/postgres-for-rag:16.6
    container_name: lightrag-postgres
    restart: unless-stopped
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
      retries: 5

  # ─── LightRAG Server ───
  lightrag:
    image: ghcr.io/hkuds/lightrag:latest
    container_name: lightrag-server
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file: .env
    ports:
${COMPOSE_PORTS}
    volumes:
      - rag_storage:/app/data/rag_storage
      - inputs:/app/data/inputs
    networks:
      - lightrag-net
${COMPOSE_CADDY_SERVICE}
volumes:
  postgres_data:
  rag_storage:
  inputs:${COMPOSE_CADDY_VOLUMES}

networks:
  lightrag-net:
    driver: bridge
COMPOSE_EOF

info "docker-compose.yml создан"

CORS_ORIGINS="*"
if [ -n "$DOMAIN" ]; then
  CORS_ORIGINS="https://${DOMAIN}"
fi

cat > "${INSTALL_DIR}/.env" << ENV_EOF
# ─── LLM ─────────────────────────────────────────────────────
LLM_BINDING=openai
LLM_BINDING_HOST=${API_HOST}
LLM_BINDING_API_KEY=${API_KEY}
LLM_MODEL=${LLM_MODEL}
LLM_MAX_TOKEN_SIZE=32768

# ─── Embeddings ──────────────────────────────────────────────
EMBEDDING_BINDING=openai
EMBEDDING_BINDING_HOST=${API_HOST}
EMBEDDING_BINDING_API_KEY=${API_KEY}
EMBEDDING_MODEL=${EMBEDDING_MODEL}
EMBEDDING_DIM=1536
EMBEDDING_MAX_TOKEN_SIZE=8192

# ─── PostgreSQL ──────────────────────────────────────────────
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=rag
POSTGRES_PASSWORD=rag
POSTGRES_DATABASE=rag

LIGHTRAG_KV_STORAGE=PGKVStorage
LIGHTRAG_VECTOR_STORAGE=PGVectorStorage
LIGHTRAG_GRAPH_STORAGE=PGGraphStorage
LIGHTRAG_DOC_STATUS_STORAGE=PGDocStatusStorage

# ─── Авторизация ─────────────────────────────────────────────
LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY}
AUTH_ACCOUNTS=${ADMIN_LOGIN}:${ADMIN_PASSWORD}
TOKEN_SECRET=${TOKEN_SECRET}
TOKEN_EXPIRE_HOURS=48

# ─── Безопасность ────────────────────────────────────────────
CORS_ORIGINS=${CORS_ORIGINS}
WHITELIST_PATHS=/health

# ─── Сервер ──────────────────────────────────────────────────
PORT=9621
HOST=0.0.0.0
LOG_LEVEL=INFO
TIMEOUT=150
ENV_EOF

info ".env создан"

if [ "$PROXY_MODE" = "1" ]; then
  CADDY_BLOCK="
# ─── LightRAG ───
${DOMAIN} {
    reverse_proxy 127.0.0.1:9621

    header {
        Strict-Transport-Security \"max-age=31536000;\"
        X-Content-Type-Options \"nosniff\"
        X-Frame-Options \"DENY\"
    }
}
"
  if [ -f "$CADDY_FILE_PATH" ]; then
    echo "$CADDY_BLOCK" | sudo tee -a "$CADDY_FILE_PATH" > /dev/null
    sudo caddy reload --config "$CADDY_FILE_PATH" 2>/dev/null || warn "Перезагрузи Caddy: sudo systemctl reload caddy"
    info "Блок добавлен в ${CADDY_FILE_PATH}"
  else
    warn "Файл ${CADDY_FILE_PATH} не найден — создаю"
    echo "$CADDY_BLOCK" | sudo tee "$CADDY_FILE_PATH" > /dev/null
    info "Caddyfile создан: ${CADDY_FILE_PATH}"
  fi
elif [ "$PROXY_MODE" = "2" ]; then
  cat > "${INSTALL_DIR}/Caddyfile" << CADDY_EOF
${DOMAIN} {
    reverse_proxy lightrag:9621

    header {
        Strict-Transport-Security "max-age=31536000;"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
    }
}
CADDY_EOF
  info "Caddyfile создан"
fi

header "7. Запуск LightRAG"

cd "${INSTALL_DIR}"
docker compose up -d 2>&1 | grep -E "Started|Created|Pulling|Error" || true

echo -ne "  Жду PostgreSQL..."
for i in $(seq 1 30); do
  if docker exec lightrag-postgres pg_isready -U rag &>/dev/null; then
    echo -e " ${GREEN}✓${NC}"
    break
  fi
  echo -n "."
  sleep 1
  if [ "$i" = "30" ]; then
    echo -e " ${RED}таймаут${NC}"
    error "PostgreSQL не запустился. Проверь: docker compose logs postgres"
    exit 1
  fi
done

echo -ne "  Жду LightRAG..."
HEALTH_URL="http://localhost:9621/health"
for i in $(seq 1 60); do
  if curl -sf "$HEALTH_URL" &>/dev/null; then
    echo -e " ${GREEN}✓${NC}"
    break
  fi
  echo -n "."
  sleep 2
  if [ "$i" = "60" ]; then
    echo -e " ${RED}таймаут${NC}"
    error "LightRAG не запустился. Проверь: docker compose logs lightrag"
    exit 1
  fi
done

# ─── Вторая половина мозга: PostgreSQL oleg_brain (структурные данные) ───
header "8. PostgreSQL brain — вторая половина мозга (аналитика, клиенты, метрики)"
hint "LightRAG — смысловая память. Brain — таблицы: клиенты, подписчики, аналитика, факты."
echo ""

BRAIN_DIR="${HOME}/oleg_brain"
mkdir -p "$BRAIN_DIR"
BRAIN_PASSWORD="$(openssl rand -hex 16)"

cat > "$BRAIN_DIR/init.sql" << 'SQL_EOF'
-- База данных brain — аналитика, клиенты, метрики

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

cat > "$BRAIN_DIR/docker-compose.yml" << COMPOSE_EOF
services:
  brain-postgres:
    image: postgres:15
    container_name: brain-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: brain
      POSTGRES_PASSWORD: ${BRAIN_PASSWORD}
      POSTGRES_DB: brain
    volumes:
      - ./data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    ports:
      - "127.0.0.1:5433:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U brain -d brain"]
      interval: 5s
      timeout: 5s
      retries: 10
COMPOSE_EOF

cd "$BRAIN_DIR"
docker compose up -d || error "Не удалось запустить brain-postgres"

echo -ne "  Жду PostgreSQL brain..."
for i in $(seq 1 30); do
  if docker exec brain-postgres pg_isready -U brain -d brain &>/dev/null; then
    echo -e " ${GREEN}✓${NC}"
    break
  fi
  echo -n "."
  sleep 1
  if [ "$i" = "30" ]; then
    echo -e " ${RED}таймаут${NC}"
    warn "PostgreSQL brain ещё запускается — проверь: docker logs brain-postgres"
  fi
done
info "Connection string: postgresql://brain:${BRAIN_PASSWORD}@localhost:5433/brain"

save_credentials "${INSTALL_DIR}/credentials.txt" "$(cat << CREDS_EOF
╔══════════════════════════════════════════════════════════════╗
║  Мозг (LightRAG + PostgreSQL brain) — Учётные данные          ║
╚══════════════════════════════════════════════════════════════╝

── Полушарие 1: LightRAG (смысловая память, контекст) ──
URL:          ${LIGHTRAG_URL}
Веб-логин:    ${ADMIN_LOGIN}
Веб-пароль:   ${ADMIN_PASSWORD}
API ключ:     ${LIGHTRAG_API_KEY}
JWT секрет:   ${TOKEN_SECRET}
API endpoint: ${API_HOST}
LLM модель:   ${LLM_MODEL}
Embed модель: ${EMBEDDING_MODEL}

── Полушарие 2: PostgreSQL brain (структурные данные) ──
Connection:   postgresql://brain:${BRAIN_PASSWORD}@localhost:5433/brain
Таблицы:      clients, subscribers, analytics, key_facts

── Подключение к Claude Code (LightRAG MCP) ──
claude mcp add --scope user lightrag \\
  -e LIGHTRAG_SERVER_URL="${LIGHTRAG_URL}" \\
  -e LIGHTRAG_API_KEY="${LIGHTRAG_API_KEY}" \\
  -- npx -y @g99/lightrag-mcp-server

── Подключение к Claude Code (PostgreSQL MCP) ──
claude mcp add --scope user postgres \\
  -- npx -y @modelcontextprotocol/server-postgres \\
  "postgresql://brain:${BRAIN_PASSWORD}@localhost:5433/brain"
CREDS_EOF
)"

if [ "$PROXY_MODE" = "3" ]; then
  echo -e "  ${BOLD}─── Nginx Proxy Manager ───${NC}"
  echo ""
  echo -e "  В админке NPM добавь Proxy Host:"
  echo -e "    Domain:           ${CYAN}${DOMAIN}${NC}"
  echo -e "    Forward Hostname: ${CYAN}lightrag-server${NC}"
  echo -e "    Forward Port:     ${CYAN}9621${NC}"
  echo -e "    SSL:              Request new certificate, Force SSL"
  echo ""
  warn "NPM и LightRAG должны быть в одной Docker-сети!"
  echo -e "  Подключи: ${CYAN}docker network connect <сеть-npm> lightrag-server${NC}"
fi

}
