# freemind-setup

Один вход — один сервис. Установка компонентов стека FreeMind на голый Ubuntu-сервер одной командой.

## Установка

```bash
# Свой VPN (WireGuard)
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s vpn

# Гермес (AI-агент) + Kanban-доска
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s hermes

# OmniRoute (единый AI-шлюз, бесплатные модели)
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s omniroute

# LightRAG — "мозг", память для AI-агентов
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s mozg

# Telegram-гейтвей для уже установленного Hermes
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s telegram
```

Скрипт спросит только то, что реально нужно (пароли, домен) — и прямо по ходу выполнения, не заранее целым списком.

## Требования

- Ubuntu 22.04/24.04, root-доступ
- Рекомендуется 4 ГБ RAM. На тарифах 2 ГБ и меньше скрипт сам предложит добавить своп.

## Модули

| Модуль | Что ставит | Подробный урок |
|---|---|---|
| `vpn` | WireGuard (wg-easy), домен+SSL для панели, firewall, блокировка торрентов (iptables + Suricata) | `урок_свой_vpn_wireguard.md` |
| `hermes` | Hermes (AI-агент), Kanban-доска, веб-дашборд, автозапуск диспетчера | `урок_hermes_install_kanban.md` |
| `omniroute` | OmniRoute (единый AI-шлюз), ключи провайдеров, systemd 24/7 | — |
| `mozg` | LightRAG + PostgreSQL brain (два полушария памяти), Docker, домен опционально | — |
| `telegram` | Telegram-бот для уже установленного Hermes (требует модуль `hermes`) | `урок_hermes_telegram_gateway.md` |

Каждый модуль в конце выводит и сохраняет в `~/<модуль>-credentials.txt` (chmod 600) все данные, которые нужно сохранить — пароли, URL, ключи.

## Пароли по умолчанию (учебные, ОБЯЗАТЕЛЬНО смени после урока)

Для урока/демо все пароли фиксированные и предсказуемые — просто жми Enter на вопросе о пароле, чтобы принять дефолт, или впиши свой:

| Сервис | Дефолтный пароль | Где используется |
|---|---|---|
| VPN (WireGuard-панель) | `Vpn_2026!` | Логин в панель на порту 51821 |
| Hermes (веб-дашборд) | `Hermes_2026!` | Логин `admin` в дашборд (только если выбрал домен) |
| Мозг — LightRAG | `Mozg_2026!` | Логин `admin` в LightRAG |
| Мозг — PostgreSQL brain | `Mozg_2026!` | Пользователь `brain`, БД `brain`, порт 5433 |
| OmniRoute | — (нет своего пароля) | Доступ через API-ключ, создаётся в дашборде вручную |
| Telegram | — (токен, не пароль) | Из @BotFather |

⚠️ Эти пароли **публичные** — они лежат в открытом репозитории. Годятся только для урока/демо на тестовом сервере. Каждый модуль после установки печатает точную команду, как сменить именно его пароль (раздел «⚠️» в конце вывода и в `~/<модуль>-credentials.txt`).

Подробные уроки с объяснением каждого шага — в приватном репозитории ClaudeCode, канал @free_mind_rus.

## 🎓 Скиллы для AI-агентов

Инфраструктура (этот репозиторий) — это где агент работает. **Скиллы** — это то, что он умеет делать, оказавшись там.

**Что такое скилл:** папка с инструкцией (`SKILL.md`) — короткое описание задачи и пошаговая процедура для неё. Claude Code / Hermes / Codex читают краткое описание каждого скилла бесплатно и подгружают полный текст только тогда, когда задача реально совпадает — поэтому скиллы не раздувают контекст даже когда их сотни. Вместо того чтобы объяснять агенту с нуля «как задеплоить на Cloudflare» или «как написать пост в стиле канала» в каждом диалоге — один раз кладёшь скилл, и агент сам подхватывает его когда нужно.

**Открытая библиотека:** [github.com/freemind-club/freemind-skills](https://github.com/freemind-club/freemind-skills) — 33 базовых скилла по 8 категориям + промпты + шаблоны Telegram-ботов + гайды по настройке, бесплатно.

```bash
git clone https://github.com/freemind-club/freemind-skills
cd freemind-skills && bash install.sh
```

Скрипт спросит что установить и покажет список всех скиллов с описанием пользы.

## Структура

```
install.sh              # точка входа, curl | bash -s <модуль>
lib/common.sh            # общие функции (своп, nginx+certbot, промпты)
modules/vpn.sh
modules/hermes.sh
```

## Разработка

Каждый модуль — bash-функция `run_module()`, вызываемая после подключения `lib/common.sh`. Общие вещи (своп, nginx-сайт с SSL, ufw) — в `lib/common.sh`, не дублировать в модулях.
