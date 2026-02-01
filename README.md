# VPN Bot — продажа подписок через Telegram

Telegram-бот для продажи VPN ключей с интеграцией **Remnawave** и **Yookassa**.

## Возможности

- Выбор тарифного плана в боте
- **Принудительная подписка** — требование подписки на Telegram-канал перед использованием
- **Веб-админ-панель** — управление пользователями, блокировка, отзыв ключей, настройки (.env)
- **Управление пользователями** — блокировка и отзыв ключей прямо из панели
- Оплата через Yookassa (карты, СБП, ЮMoney)
- Автоматическое создание пользователя в Remnawave
- **Nginx** — reverse proxy с поддержкой SSL (Let's Encrypt)
- Пробный период и реферальная программа
- Команда `/stats` для администраторов

## Установка

Единый скрипт полной установки (требуется root):

```bash
curl -sSL https://raw.githubusercontent.com/TheNotus/vlessbot/main/install.sh | sudo bash
```

или из локальной копии:

```bash
git clone https://github.com/TheNotus/vlessbot.git && cd vlessbot
sudo ./install.sh
```

Скрипт устанавливает: **Remnawave Panel** (Docker), **Subscription Page**, Python 3.10+, nginx, certbot, зависимости, systemd-сервис, cron, logrotate.

## Настройка

**Полностью автоматическая установка** (домен + SSL + панель + бот):
```bash
WEBHOOK_DOMAIN=bot.your-domain.com \
PANEL_DOMAIN=panel.your-domain.com \
SUB_DOMAIN=sub.your-domain.com \
CERTBOT_EMAIL=admin@your-domain.com \
sudo ./install.sh
```
- `WEBHOOK_DOMAIN` — домен для webhook бота
- `PANEL_DOMAIN` — домен для Remnawave Panel (опционально)
- `SUB_DOMAIN` — домен для Subscription Page (опционально)
- `CERTBOT_EMAIL` — email для Let's Encrypt
- `REMNAWAVE_PANEL_INSTALL=false` — отключить установку панели (если уже есть)

Скрипт автоматически: установит Docker и Remnawave Panel, настроит nginx, SSL, обновит .env, запустит сервисы.

**Ручная настройка** (если не указаны переменные):
1. `sudo nano /opt/vpn-bot/.env` — укажите WEBHOOK_BASE_URL, токены, пароли
2. `sudo nano /etc/nginx/sites-available/vpn-bot` — server_name=ваш-домен
3. `sudo certbot --nginx -d ваш-домен`
4. В Yookassa: URL уведомлений = `https://ваш-домен/webhook/yookassa`
5. `sudo systemctl start vpn-bot`

## Админ-панель

Панель доступна **только через SSH-туннель** (127.0.0.1). В `.env`:
- `ADMIN_PANEL_ENABLED=true`
- `ADMIN_PANEL_PASSWORD=ваш_пароль`
- `ADMIN_PANEL_PORT=8080` (по умолчанию)

Подключение:
```bash
ssh -L 8080:127.0.0.1:8080 user@ваш_сервер
```
Откройте http://127.0.0.1:8080 в браузере.

**Функции панели:**
- Дашборд — статистика (заказы, выручка, trial, рефералы)
- Пользователи — блокировка, разблокировка, отзыв ключей
- Настройки — просмотр и редактирование .env

## Принудительная подписка

Включение/выключение в `.env` — `FORCED_CHANNEL_ENABLED=true` или `false`.

Чтобы требовать подписку на канал перед использованием бота:
- `FORCED_CHANNEL_ENABLED=true`
- `FORCED_CHANNEL_ID=-1001234567890` (ID канала)
- `FORCED_CHANNEL_USERNAME=@mychannel` (для ссылки)

Бот должен быть администратором канала. Чтобы отключить проверку — `FORCED_CHANNEL_ENABLED=false`.

## Nginx

Webhook слушает на `127.0.0.1:8000`. Nginx проксирует запросы с вашего домена на этот порт. Конфиг: `/etc/nginx/sites-available/vpn-bot`.

## Структура проекта

```
├── main.py              # Точка входа (webhook + админ-панель)
├── bot.py               # Telegram бот
├── admin_panel.py       # Веб-админ-панель
├── webhook.py           # Webhook Yookassa
├── cleanup_expired.py   # Очистка истёкших ключей (cron)
├── database.py          # SQLite: заказы, trial, blocked_users
├── config.py            # Конфигурация
├── remnawave_client.py  # API Remnawave
├── yookassa_client.py   # API Yookassa
├── utils.py
├── install.sh           # Полная установка (nginx + certbot)
└── .env.example
```

## Управление

```bash
sudo systemctl start vpn-bot      # Запуск
sudo systemctl stop vpn-bot       # Остановка
sudo systemctl restart vpn-bot    # Перезапуск
sudo journalctl -u vpn-bot -f     # Логи
```

## Безопасность

- Админ-панель только через SSH-туннель (127.0.0.1)
- Не коммитьте `.env`
- Используйте HTTPS (certbot + Let's Encrypt)
