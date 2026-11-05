#!/usr/bin/env bash
# freemind-setup/modules/office.sh — цифровой офис, Директор на доске задач, офис → мозг,
# ночная зашифрованная копия, сжатые ответы caveman (© Julius Brussee, MIT, закреплённый коммит)
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "Проверка окружения"
    require_root
    unlock_dpkg

    # Ищем Гермеса
    local hermes_bin=""
    if command -v hermes >/dev/null 2>&1; then
        hermes_bin="$(command -v hermes)"
    elif [ -x "$HOME/.local/bin/hermes" ]; then
        hermes_bin="$HOME/.local/bin/hermes"
    else
        die "Гермес не найден. Сначала установи модуль hermes: curl ... | bash -s hermes"
    fi
    ok "Гермес: $hermes_bin"

    # Проверка Мозга (LightRAG)
    local mozg_enabled=false
    local mozg_api_key=""
    if curl -sf -m5 http://127.0.0.1:9621/health >/dev/null 2>&1; then
        if [ -f "$HOME/lightrag/.env" ]; then
            mozg_api_key=$(grep '^LIGHTRAG_API_KEY=' "$HOME/lightrag/.env" | cut -d'=' -f2- || true)
            if [ -n "$mozg_api_key" ]; then
                mozg_enabled=true
                ok "Мозг найден и доступен"
            fi
        fi
    fi
    if [ "$mozg_enabled" = false ]; then
        warn "Мозг не найден или не настроен — шаги синхронизации офис→мозг будут пропущены."
        warn "Поставь модуль mozg и запусти office ещё раз, если это нужно."
    fi

    step "Создание структуры папок ~/office"
    mkdir -p ~/office
    chmod 750 ~/office

    # Папки и их владельцы
    declare -A descs=(
        ["входящие"]="всё новое: заявки, документы, файлы от тебя и ролей"
        ["разбор"]="Диспетчер раскладывает входящее по задачам"
        ["продажи"]="сделки, клиенты, коммерческие предложения"
        ["маркетинг"]="стратегии, контент-планы, рекламные материалы"
        ["финансы"]="счета, акты, бюджет"
        ["юр-документы"]="договоры, уставы, доверенности"
        ["отчёты"]="сводки и отчёты Аналитика"
        ["архив"]="завершённые дела и старые версии"
    )
    declare -A folders=(
        ["входящие"]="Секретарь (сторож)"
        ["разбор"]="Диспетчер"
        ["продажи"]="Владелец"
        ["маркетинг"]="Владелец"
        ["финансы"]="Владелец"
        ["юр-документы"]="Владелец"
        ["отчёты"]="Аналитик"
        ["архив"]="Архивариус"
    )

    # Неделя 5 уже создала офис на латинице: inbox (сторожит Секретарь), inbox-done,
    # otvety-chernoviki, inbox-razbor.md. Её не трогаем и не дублируем русскими папками
    # (было вживую 05.11: рядом с inbox появилась пустая «входящие» → два входа).
    local inbox_dir="входящие"
    if [ -d "$HOME/office/inbox" ]; then
        inbox_dir="inbox"
        unset 'folders[входящие]' 'folders[разбор]'
        ok "Найден офис недели 5 (inbox) — входящие остаются в ~/office/inbox, «входящие»/«разбор» не создаю"
    fi

    local latin_dupes=()
    for dir in "${!folders[@]}"; do
        mkdir -p "$HOME/office/$dir"
        # README.md если нет
        if [ ! -f "$HOME/office/$dir/README.md" ]; then
            echo "# Папка: $dir" > "$HOME/office/$dir/README.md"
            { echo "Владелец: ${folders[$dir]}"; echo; echo "${descs[$dir]}"; } >> "$HOME/office/$dir/README.md"
        fi
    done

    # Проверка латинских дублей
    for lat in "vhodyashchie" "prodazhi" "marketing" "finansy" "otchety" "arhiv"; do
        if [ -d "$HOME/office/$lat" ]; then latin_dupes+=("$lat"); fi
    done
    if [ ${#latin_dupes[@]} -gt 0 ]; then
        warn "Найдены латинские дубли папок: ${latin_dupes[*]}. Я их не трогаю — перенеси файлы в русские папки сам."
    fi

    # КАРТА_ОФИСА.md
    if [ ! -f "$HOME/office/КАРТА_ОФИСА.md" ]; then
        {
            echo "# Карта Цифрового Офиса"
            echo "| Папка | Владелец | Описание |"
            echo "| :--- | :--- | :--- |"
            if [ "$inbox_dir" = "inbox" ]; then
                echo "| inbox | Секретарь (сторож) | всё новое: заявки, документы, файлы от тебя и ролей (с недели 5) |"
                echo "| inbox-done | Секретарь | разобранное из inbox |"
                echo "| otvety-chernoviki | Секретарь | черновики ответов клиентам — отправляет только владелец |"
                echo "| inbox-razbor.md | Диспетчер/Секретарь | журнал разбора входящих |"
            fi
            for dir in "входящие" "разбор" "продажи" "маркетинг" "финансы" "юр-документы" "отчёты" "архив"; do
                [ -n "${folders[$dir]:-}" ] || continue
                echo "| $dir | ${folders[$dir]} | ${descs[$dir]} |"
            done
        } > "$HOME/office/КАРТА_ОФИСА.md"
    fi
    ok "Структура офиса готова"

    step "Настройка Директора (Kanban)"
    apt_ensure python3-yaml
    local config_file="$HOME/.hermes/config.yaml"
    if [ -f "$config_file" ]; then
        cp -p "$config_file" "$config_file.bak-office-$(date +%Y%m%d)"
        python3 -I <<EOF
import yaml, os
path = os.path.expanduser("$config_file")
with open(path, 'r') as f:
    cfg = yaml.safe_load(f) or {}

def ensure_list_item(obj, key_path, item):
    d = obj
    keys = key_path.split('.')
    for k in keys[:-1]:
        d = d.setdefault(k, {})
    lst = d.get(keys[-1], [])
    if not isinstance(lst, list): lst = []
    if item not in lst:
        lst.append(item)
    d[keys[-1]] = lst

# Добавляем kanban в инструменты
ensure_list_item(cfg, 'toolsets', 'kanban')
ensure_list_item(cfg, 'platform_toolsets.telegram', 'kanban')
ensure_list_item(cfg, 'platform_toolsets.cli', 'kanban')

with open(path, 'w') as f:
    yaml.dump(cfg, f, allow_unicode=True, sort_keys=False)
EOF
    fi

    # Инициализация доски
    if ! "$hermes_bin" kanban list >/dev/null 2>&1; then
        "$hermes_bin" kanban init || warn "Не удалось создать доску: hermes kanban init — запусти вручную"
    fi
    ok "Канбан-доска подключена"

    step "Настройка Caveman (сжатые ответы)"
    if confirm "Включить сжатые ответы caveman (экономит токены)?"; then
        local cv_dir="$HOME/.hermes/skills/productivity/caveman"
        mkdir -p "$cv_dir"
        curl -fsSL -m 30 "https://raw.githubusercontent.com/JuliusBrussee/caveman/655b7d9c5431f822264b7732e9901c5578ac84cf/skills/caveman/SKILL.md" -o "$cv_dir/SKILL.md" || { warn "Не удалось скачать caveman — пропускаю"; rm -f "$cv_dir/SKILL.md"; }
        local sha
        sha=$(sha256sum "$cv_dir/SKILL.md" 2>/dev/null | awk '{print $1}' || true)
        if [ "$sha" = "6a93e68b5d843ab6da3290dfe81cfdf26de166be7f3feca5acb52744f63db593" ]; then
            echo "caveman © Julius Brussee, MIT, https://github.com/JuliusBrussee/caveman" > "$cv_dir/LICENSE-NOTE.txt"
            python3 -I <<EOF
import yaml, os
path = os.path.expanduser("$config_file")
with open(path, 'r') as f: cfg = yaml.safe_load(f) or {}
skills = cfg.setdefault('skills', {}) or {}
cfg['skills'] = skills
auto_load = skills.get('auto_load') or []
if not isinstance(auto_load, list): auto_load = [auto_load]
if 'caveman' not in auto_load:
    auto_load.append('caveman')
    skills['auto_load'] = auto_load
    with open(path, 'w') as f: yaml.dump(cfg, f, allow_unicode=True, sort_keys=False)
EOF
            ok "Скилл caveman установлен"
        else
            rm -f "$cv_dir/SKILL.md"
            warn "Контрольная сумма caveman не совпала — скилл не установлен."
        fi
    fi

    step "Обновление правил (SOUL.md)"
    local soul_file="$HOME/.hermes/SOUL.md"
    [ -f "$soul_file" ] && cp -p "$soul_file" "$soul_file.bak-office-$(date +%Y%m%d)"
    
    local caveman_rule=""
    if [ -f "$HOME/.hermes/skills/productivity/caveman/SKILL.md" ]; then
        caveman_rule="(г) Отвечай кратко в стиле caveman (скилл caveman, уровень lite в Telegram), технические детали и команды пиши полностью."
    fi

    # Собираем блок правил
    local office_block
    office_block=$(cat <<EOF
<!-- freemind-setup:office:BEGIN -->
### Правила Цифрового Офиса
(а) **Ты — Директор**: задачи ролям ставишь только карточками на доске (kanban_create), сам работу ролей не делаешь. Деньги, удаление файлов, отправка писем наружу — только после явного «да» владельца. Перед раздачей сверься с реестром команды: задачу получает только сотрудник, чья роль ПРЯМО про это (посты и тексты для канала — Копирайтер, видео — Рилсы, черновики ответов клиентам — Секретарь). Если такого сотрудника нет — не отдавай «ближайшему по смыслу»: скажи «в штате нет <роль>» и предложи нанять его через Кадровика.
(б) **Офис**: файлы лежат в ~/office (см. КАРТА_ОФИСА.md). Новые входящие — в папку «$inbox_dir», результаты твоей работы — в папку соответствующей роли. Одно имя папки — одна папка: не создавай дубли латиницей/кириллицей.
(в) **Память**: Смыслы (решения, факты, данные клиентов) — мозг LightRAG (инструменты mozg: query_text перед задачей, insert_text 1-3 предложения после). Цифры — база brain (только SELECT; INSERT — покажи владельцу и жди «да»). Не пиши в мозг пароли, ключи, черновики и логи.
$caveman_rule
<!-- freemind-setup:office:END -->
EOF
)
    if grep -q "freemind-setup:office:BEGIN" "$soul_file" 2>/dev/null; then
        # Заменяем существующий блок
        python3 -I -c 'import sys
c=open(sys.argv[1],encoding="utf-8").read(); b="<!-- freemind-setup:office:BEGIN -->"; e="<!-- freemind-setup:office:END -->"
i=c.index(b); j=c.index(e,i)+len(e)
open(sys.argv[1]+".tmp","w",encoding="utf-8").write(c[:i]+sys.argv[2]+c[j:])' "$soul_file" "$office_block" && mv "$soul_file.tmp" "$soul_file"
    else
        echo -e "\n$office_block" >> "$soul_file"
    fi
    ok "Инструкции Директора обновлены"

    if [ "$mozg_enabled" = true ]; then
        step "Синхронизация Офис → Мозг"
        cat <<'EOF' > /usr/local/bin/fm-office-to-brain.py
#!/usr/bin/env python3
import os, re, hashlib, json, urllib.request, sys

OFFICE_DIR = os.path.expanduser("~/office")
STATE_FILE = os.path.expanduser("~/.local/state/fm-office-to-brain.json")
ENV_FILE = os.path.expanduser("~/lightrag/.env")
API_URL = "http://127.0.0.1:9621/documents/text"

def get_api_key():
    try:
        with open(ENV_FILE, 'r') as f:
            for line in f:
                if line.startswith('LIGHTRAG_API_KEY='):
                    return line.strip().split('=', 1)[1].strip().strip('"').strip("'")
    except: return None
    return None

NAME_MARKERS = ['.env', 'key', 'secret', 'пароль', 'password', 'token', 'доступ']
CONTENT_RE = re.compile(r'(BEGIN [A-Z ]*PRIVATE KEY|\b(sk|ghp|gho|xox[bp])-?[A-Za-z0-9_]{16,}|[A-Z_]*(API_KEY|TOKEN|SECRET|PASSWORD)\s*=\s*\S{6,})')

def is_secret(path, content):
    if any(m in path.lower() for m in NAME_MARKERS): return True
    return bool(CONTENT_RE.search(content))

api_key = get_api_key()
if not api_key:
    print("Ошибка: API_KEY не найден")
    sys.exit(1)

os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
state = {}
if os.path.exists(STATE_FILE):
    try:
        with open(STATE_FILE, 'r') as f: state = json.load(f)
    except Exception: state = {}

sent, skipped = 0, 0
for root, dirs, files in os.walk(OFFICE_DIR):
    dirs[:] = [d for d in dirs if not d.startswith(('.', '.stversions', '.stfolder'))]
    for f in files:
        if f.startswith('.') or '.bak' in f: continue
        ext = os.path.splitext(f)[1].lower()
        path = os.path.join(root, f)
        rel_path = os.path.relpath(path, OFFICE_DIR)
        
        if ext in ['.docx', '.pdf']:
            print(f"Пропуск {rel_path}: не поддерживается")
            skipped += 1; continue
        if ext not in ['.md', '.txt', '.csv']: continue
        if os.path.getsize(path) > 1024 * 1024: continue

        try:
            with open(path, 'r', encoding='utf-8') as tf:
                content = tf.read()
            if is_secret(rel_path, content):
                skipped += 1; continue
            
            h = hashlib.sha256(content.encode()).hexdigest()
            if state.get(path) == h: continue

            req = urllib.request.Request(API_URL, method='POST')
            req.add_header('X-API-Key', api_key)
            req.add_header('Content-Type', 'application/json')
            data = json.dumps({"text": f"Файл офиса: {rel_path}\n\n{content}", "file_source": f"office/{rel_path}"}).encode()
            with urllib.request.urlopen(req, data=data, timeout=60) as resp:
                if resp.status == 200:
                    state[path] = h
                    sent += 1
        except Exception as e:
            print(f"Ошибка {rel_path}: {e}", file=sys.stderr)

with open(STATE_FILE, 'w') as f: json.dump(state, f)
print(f"Итог: отправлено {sent}, пропущено {skipped}")
EOF
        chmod 700 /usr/local/bin/fm-office-to-brain.py

        cat <<EOF > /etc/systemd/system/fm-office-to-brain.service
[Unit]
Description=Sync Office to LightRAG Brain
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fm-office-to-brain.py
User=root
Nice=10
EOF
        cat <<EOF > /etc/systemd/system/fm-office-to-brain.timer
[Unit]
Description=Sync Office to Brain every hour

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now fm-office-to-brain.timer
        ok "Служба синхронизации Офис → Мозг включена"
    fi

    step "Настройка ночного бэкапа"
    apt_ensure age
    mkdir -p /root/.secrets /root/backups-enc
    chmod 700 /root/.secrets

    if [ ! -f /root/.secrets/backup_age.key ]; then
        age-keygen -o /root/.secrets/backup_age.key
        chmod 600 /root/.secrets/backup_age.key
    fi
    local pubkey
    pubkey=$(age-keygen -y /root/.secrets/backup_age.key)

    cat <<EOF > /usr/local/bin/fm-night-backup.sh
#!/usr/bin/env bash
# Сгенерировано freemind-setup (модуль office). Пути подставлены при установке.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
TMP_DIR=\$(mktemp -d)
trap 'rm -rf "\$TMP_DIR"' EXIT
DATE=\$(date +%Y-%m-%d_%H%M)
BACKUP_FILE="/root/backups-enc/fm-backup-\$DATE.tar.gz.age"

# 1. Сбор данных
mkdir -p "\$TMP_DIR/data"
if [ -x "$hermes_bin" ]; then
    "$hermes_bin" backup -o "\$TMP_DIR/data/hermes-backup.tar.gz" || tar -czf "\$TMP_DIR/data/hermes-manual.tar.gz" --exclude="auth.json" --exclude="sessions" --exclude="cache" --exclude="logs" -C "$HOME" .hermes
else
    tar -czf "\$TMP_DIR/data/hermes-manual.tar.gz" --exclude="auth.json" --exclude="sessions" --exclude="cache" --exclude="logs" -C "$HOME" .hermes
fi

if docker ps | grep -q lightrag-postgres; then
    docker exec lightrag-postgres sh -c 'PGPASSWORD="\$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U "\$POSTGRES_USER" "\$POSTGRES_DB"' | gzip > "\$TMP_DIR/data/mozg-lightrag.sql.gz" || true
fi
if docker ps | grep -q brain-postgres; then
    docker exec brain-postgres sh -c 'PGPASSWORD="\$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U "\$POSTGRES_USER" "\$POSTGRES_DB"' | gzip > "\$TMP_DIR/data/brain-postgres.sql.gz" || true
fi
tar -czf "\$TMP_DIR/data/office.tar.gz" -C "$HOME" office

# 2. Шифрование
tar -cz -C "\$TMP_DIR/data" . | age -r "$pubkey" -o "\$BACKUP_FILE"

# 3. Проверка
if [ -s "\$BACKUP_FILE" ] && age -d -i /root/.secrets/backup_age.key "\$BACKUP_FILE" | tar -tz >/dev/null; then
    SIZE=\$(du -sh "\$BACKUP_FILE" | awk '{print \$1}')
    echo "\$DATE | ok | \$SIZE" > /root/backups-enc/LAST_STATUS.txt
    # Ротация (оставляем 7)
    ls -1t /root/backups-enc/fm-backup-*.age 2>/dev/null | tail -n +8 | xargs -r rm -f --
else
    echo "\$DATE | fail | 0" > /root/backups-enc/LAST_STATUS.txt
    exit 1
fi
EOF
    chmod 700 /usr/local/bin/fm-night-backup.sh

    cat <<EOF > /etc/systemd/system/fm-night-backup.service
[Unit]
Description=Nightly Encrypted Backup (Office & Hermes)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fm-night-backup.sh
EOF
    cat <<EOF > /etc/systemd/system/fm-night-backup.timer
[Unit]
Description=Nightly Backup Timer

[Timer]
OnCalendar=*-*-* 03:30
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now fm-night-backup.timer
    ok "Ночной бэкап настроен (03:30, шифрование age)"

    if confirm "Сделать первую резервную копию прямо сейчас?"; then
        /usr/local/bin/fm-night-backup.sh && ok "Копия создана" || warn "Ошибка при создании копии"
    fi

    step "Перезапуск систем"
    "$hermes_bin" gateway restart || warn "Не удалось перезапустить шлюз, сделай это вручную."
    ok "Настройка завершена"

    save_credentials "$HOME/office-info.txt" "$(cat <<EOF
╔══════════════════════════════════════════════════════════╗
║        ЦИФРОВОЙ ОФИС И БЭКАПЫ УСТАНОВЛЕНЫ                ║
╚══════════════════════════════════════════════════════════╝

Папка офиса:    ~/office
Инструменты:    Канбан-доска (hermes kanban), Мозг (если был)
Шифрование:     age (ключ в /root/.secrets/backup_age.key)

⚠️  ВАЖНО: Сохрани ключ /root/.secrets/backup_age.key
   в свой менеджер паролей! Без него бэкапы НЕ РАСШИФРОВАТЬ.

Как проверить:
1. Таймеры: systemctl list-timers | grep fm-
2. Статус бэкапа: cat /root/backups-enc/LAST_STATUS.txt
3. Логи синхронизации: journalctl -u fm-office-to-brain -n 20

Директор (Гермес) теперь знает правила работы с папками и доской.
EOF
)"
}
