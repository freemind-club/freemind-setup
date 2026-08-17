# Как сменить пароли — все сервисы стека

Все пароли, которые ставит `freemind-setup` — фиксированные учебные (`Vpn_2026!`, `Hermes_2026!`, `Mozg_2026!`, `Omni_2026!`). Это удобно для урока/демо, но **обязательно смени их**, если сервер остаётся в реальном использовании — пароли лежат в открытом репозитории, их видно всем.

У каждого сервиса своя система хранения пароля, поэтому и команда смены своя — единой команды "смени всё" не существует. Ниже — по одному сервису, копируй и меняй `НОВЫЙ_ПАРОЛЬ` на свой.

Заходишь на сервер: `ssh root@ВАШ_IP`, дальше выполняешь команды из нужного раздела.

---

## VPN (WireGuard-панель, wg-easy)

Пароль передаётся контейнеру через переменную окружения при запуске — значит меняется через пересоздание контейнера (данные клиентов не теряются, они в отдельном volume):

```bash
docker rm -f wg-easy

docker run -d \
  --name=wg-easy \
  -e WG_HOST=ВАШ_IP \
  -e PASSWORD=НОВЫЙ_ПАРОЛЬ \
  -v ~/.wg-easy:/etc/wireguard \
  -p 51820:51820/udp \
  -p 51821:51821/tcp \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  --sysctl="net.ipv4.ip_forward=1" \
  --restart unless-stopped \
  weejewel/wg-easy
```

Либо проще — прямо в самой панели: **Settings → Change Password** (если версия wg-easy это поддерживает).

---

## Hermes (веб-дашборд)

Пароль хранится как bcrypt-хэш в `~/.hermes/.env`. Хэш нужно сгенерировать **именно** венв-питоном самого Гермеса — системный `python3` не найдёт нужный модуль:

```bash
HASH=$(cd /usr/local/lib/hermes-agent && ./venv/bin/python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('НОВЫЙ_ПАРОЛЬ'))")

sed -i "s|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=.*|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$HASH|" ~/.hermes/.env

pkill -f "hermes dashboard"
setsid nohup hermes dashboard --host 0.0.0.0 --port 9119 --no-open > ~/.hermes/dashboard.log 2>&1 < /dev/null &
disown
```

Проверка, что дашборд поднялся с новым паролем:
```bash
curl -s http://127.0.0.1:9119/api/status | grep -o '"auth_required":[a-z]*'
# должно быть: "auth_required":true
```

---

## OmniRoute (веб-дашборд)

Пароль хранится в **собственной sqlite-базе** OmniRoute (`~/.omniroute/storage.sqlite`, таблица `key_value`), не в `.env`. Хэш генерируется его же bundled-библиотекой `bcryptjs`:

```bash
NPM_ROOT=$(npm root -g)
cd "$NPM_ROOT/omniroute"

HASH=$(node -e "const b=require('bcryptjs'); console.log(b.hashSync(process.argv[1],12));" 'НОВЫЙ_ПАРОЛЬ')

sqlite3 ~/.omniroute/storage.sqlite "UPDATE key_value SET value = json_quote('$HASH') WHERE key = 'password';"

systemctl restart omniroute
```

Проверка реальным логином:
```bash
curl -s -X POST http://127.0.0.1:20128/api/auth/login -H "Content-Type: application/json" -d '{"password":"НОВЫЙ_ПАРОЛЬ"}'
# должно быть: {"success":true}
```

Если `sqlite3` не установлен: `apt install -y sqlite3`.

---

## Мозг — LightRAG

Пароль веб-панели задаётся строкой `AUTH_ACCOUNTS=логин:пароль` в `.env`:

```bash
sed -i "s|AUTH_ACCOUNTS=.*|AUTH_ACCOUNTS=admin:НОВЫЙ_ПАРОЛЬ|" ~/lightrag/.env
cd ~/lightrag && docker compose restart lightrag
```

---

## Мозг — PostgreSQL brain

Пароль пользователя базы данных — стандартный SQL, но **не забудь** поменять его и в `docker-compose.yml`, иначе при следующем перезапуске контейнер вернёт старый:

```bash
docker exec -it brain-postgres psql -U brain -d brain -c "ALTER USER brain WITH PASSWORD 'НОВЫЙ_ПАРОЛЬ';"

sed -i "s|POSTGRES_PASSWORD:.*|POSTGRES_PASSWORD: НОВЫЙ_ПАРОЛЬ|" ~/oleg_brain/docker-compose.yml
```

---

## Общий совет

Если планируешь держать сервер в реальном использовании — смени все пароли **сразу после установки**, не откладывай. Каждый модуль сам напоминает об этом и печатает точную команду в конце своей работы (в `~/<модуль>-credentials.txt`) — этот файл просто собирает все команды смены в одном месте, для отдельной задачи «пришёл и сменил всё».
