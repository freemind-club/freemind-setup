# freemind-setup

Один вход — один сервис. Установка компонентов стека FreeMind на голый Ubuntu-сервер одной командой.

## Установка

```bash
# Свой VPN (WireGuard)
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s vpn

# Гермес (AI-агент) + Kanban-доска
curl -fsSL https://raw.githubusercontent.com/freemind-club/freemind-setup/main/install.sh | bash -s hermes
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

Подробные уроки с объяснением каждого шага — в приватном репозитории ClaudeCode, канал @free_mind_rus.

## Структура

```
install.sh              # точка входа, curl | bash -s <модуль>
lib/common.sh            # общие функции (своп, nginx+certbot, промпты)
modules/vpn.sh
modules/hermes.sh
```

## Разработка

Каждый модуль — bash-функция `run_module()`, вызываемая после подключения `lib/common.sh`. Общие вещи (своп, nginx-сайт с SSL, ufw) — в `lib/common.sh`, не дублировать в модулях.
