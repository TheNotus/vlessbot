# VPN Bot — продажа подписок через Telegram

Telegram-бот для продажи VPN ключей с интеграцией **Remnawave** и **Yookassa**.

> **Новичок?** Запустите установку одной командой ниже. В конце скрипт выведет **пошаговую инструкцию** — выполняйте шаги по порядку (Remnawave → .env → ЮKassa → перезапуск бота).

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

**Одна команда** (нужен root, Ubuntu/Debian):

```bash
curl -sSL https://raw.githubusercontent.com/TheNotus/vlessbot/main/install.sh | sudo bash
```

Скрипт спросит: домен для бота, email для SSL, домены для панели (можно пропустить). После установки в консоли появится **пошаговая инструкция** — выполняйте шаги по порядку.

Или из локальной копии:

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

**Порядок после установки** (то же самое выводится в консоли):
1. **Remnawave Panel** — откройте в браузере (домен или IP:8080), создайте админа, Node, Internal Squad, API-токен; вставьте токен в `/opt/remnawave/.env`.
2. **Файл бота** — `sudo nano /opt/vpn-bot/.env`: TELEGRAM_BOT_TOKEN (от @BotFather), ADMIN_IDS (ваш Telegram ID), YOOKASSA_* (из кабинета ЮKassa), REMNAWAVE_* (логин/пароль и UUID из шага 1). Сохранить: Ctrl+O, Enter. Выход: Ctrl+X.
3. **ЮKassa** — в настройках уведомлений укажите URL `https://ваш-домен/webhook/yookassa`.
4. **Перезапуск** — `sudo systemctl restart vpn-bot`.

## Две панели (не путать)

- **Remnawave Panel** — панель VPN (ноды, подписки, Internal Squad). Доступ по домену (`PANEL_DOMAIN`) или по IP:8080. Порт 8080.
- **Админ-панель бота** — управление ботом (пользователи, блокировка, .env). Только через SSH-туннель, не в интернете. При установке вместе с Remnawave использует порт **8082** (8080 занят Remnawave).

## Админ-панель бота

Доступна **только через SSH-туннель** (127.0.0.1). В `.env`:
- `ADMIN_PANEL_ENABLED=true`
- `ADMIN_PANEL_PASSWORD=ваш_пароль`
- `ADMIN_PANEL_PORT=8080` (или **8082**, если установлен Remnawave на 8080)

Подключение (порт 8082 при установке с Remnawave):
```bash
ssh -L 8082:127.0.0.1:8082 user@ваш_сервер
```
Откройте http://127.0.0.1:8082 в браузере. Без Remnawave — порт 8080.

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

## Nginx и Certbot

Перед запуском certbot выполните `sudo nginx -t`. При ошибке «No such file or directory» для файла в `sites-enabled` удалите битую симлинку: `sudo rm /etc/nginx/sites-enabled/имя_файла`.

Webhook слушает на `127.0.0.1:8000`. Nginx проксирует запросы с вашего домена на этот порт. Конфиг: `/etc/nginx/sites-available/vpn-bot`.

## Если панель Remnawave не открывается (502)

Проверьте, что контейнер запущен: `docker ps` (должен быть `remnawave`), и порт: `ss -tlnp | grep 8080`. Если контейнера нет:
```bash
cd /opt/remnawave && sudo docker compose -f docker-compose-prod.yml -f docker-compose-sub.yml up -d
# Если docker compose не найден — используйте: docker-compose -f ... -f ... up -d
```

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
