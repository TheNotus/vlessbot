# VPN Bot — полная инструкция по настройке с нуля

Пошаговая инструкция по развёртыванию проекта: от установки панели Remnawave до запуска Telegram-бота.

---

## Содержание

1. [Требования](#1-требования)
2. [Установка Remnawave Panel](#2-установка-remnawave-panel)
3. [Настройка Remnawave](#3-настройка-remnawave)
4. [Установка Subscription Page](#4-установка-subscription-page)
5. [Регистрация в Yookassa](#5-регистрация-в-yookassa)
6. [Создание Telegram-бота](#6-создание-telegram-бота)
7. [Установка и настройка VPN Bot](#7-установка-и-настройка-vpn-bot)
8. [Запуск и проверка](#8-запуск-и-проверка)
9. [Пробный режим и реферальная программа](#9-пробный-режим-и-реферальная-программа)

---

## 1. Требования

- **Сервер** с Ubuntu 20.04+ (или другой Linux) и публичным IP
- **Домен** с настроенным DNS (например, `panel.example.com`, `sub.example.com`)
- **Python 3.10+**
- Доступ по SSH к серверу

---

## 2. Установка Remnawave Panel

Remnawave — панель управления VPN на базе Xray-core (VLESS, Trojan, Shadowsocks).

### 2.1. Установка Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Перелогиньтесь или выполните: newgrp docker
```

### 2.2. Установка Remnawave Panel (официальная)

Remnawave Panel использует образ `remnawave/backend` (не `remnawave/panel` — его не существует).

```bash
mkdir -p /opt/remnawave
cd /opt/remnawave
curl -o docker-compose-prod.yml https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml
curl -o .env https://raw.githubusercontent.com/remnawave/backend/main/.env.sample
```

Сгенерируйте секреты и пароль Postgres:

```bash
sed -i "s|^JWT_AUTH_SECRET=.*|JWT_AUTH_SECRET=$(openssl rand -hex 64)|" .env
sed -i "s|^JWT_API_TOKENS_SECRET=.*|JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)|" .env
pw=$(openssl rand -hex 24) && sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$pw|" .env
sed -i "s|postgresql://postgres:[^@]*@|postgresql://postgres:$pw@|" .env
```

Отредактируйте `.env`: `FRONT_END_DOMAIN`, `SUB_PUBLIC_DOMAIN`. Затем:

```bash
# Порт 8080 для панели (по умолчанию 3000)
sed -i 's|- 127.0.0.1:3000:\${APP_PORT:-3000}|- 127.0.0.1:8080:3000|' docker-compose-prod.yml
docker compose -f docker-compose-prod.yml up -d
```

Панель будет доступна по `http://ваш-ip:8080`.

### 2.3. Первоначальная настройка

1. Откройте в браузере `http://ваш-ip:8080`
2. Создайте учётную запись администратора (username и password)
3. Сохраните эти данные — они понадобятся для `REMNAWAVE_USERNAME` и `REMNAWAVE_PASSWORD`

### 2.4. Настройка Nginx (рекомендуется)

Для работы по HTTPS и на домене настройте Nginx:

```bash
sudo apt install nginx certbot python3-certbot-nginx -y
sudo certbot --nginx -d panel.example.com
```

Пример конфигурации `/etc/nginx/sites-available/panel`:

```nginx
server {
    listen 80;
    server_name panel.example.com;
    return 301 https://$server_name$request_uri;
}
server {
    listen 443 ssl;
    server_name panel.example.com;
    ssl_certificate /etc/letsencrypt/live/panel.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/panel.example.com/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/panel /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

---

## 3. Настройка Remnawave

### 3.1. Добавление Node (VPN-сервера)

1. В панели: **Nodes** → **Add Node**
2. Заполните:
   - **Name** — произвольное (например, `Server1`)
   - **Address** — IP или домен вашего VPN-сервера
   - **Config Profile** — выберите или создайте профиль (обычно есть default)
3. Сохраните и дождитесь статуса «Online»

> **Важно:** На самом VPN-сервере должен быть установлен **Remnawave Node**. Инструкция: https://docs.rw/docs/install/remnawave-node

### 3.2. Создание Internal Squad (группы подписок)

Internal Squad определяет, к каким серверам имеют доступ пользователи.

1. В панели: **Internal Squads** → **Edit** (или **+** для новой)
2. Включите нужные **Inbounds** (из Config Profiles)
3. Сохраните
4. Скопируйте **UUID** группы (нажмите на неё или посмотрите в URL)

Этот UUID — значение для `REMNAWAVE_SQUAD_UUID` в `.env`.

### 3.3. Проверка API

Проверьте, что API доступен:

```bash
curl -X POST https://panel.example.com/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}'
```

В ответе должен быть `accessToken`.

---

## 4. Установка Subscription Page

Subscription Page — страница, на которой пользователи получают свои подписки. Она скрывает адрес панели и даёт удобную ссылку.

### 4.1. Установка через Docker

```bash
cd ~/remnawave
```

Добавьте в `docker-compose.yml` (или создайте отдельный compose):

```yaml
  subscription-page:
    image: remnawave/subscription-page:latest
    restart: unless-stopped
    ports:
      - "8081:3000"
    environment:
      - REMNAWAVE_PANEL_URL=https://panel.example.com
      - REMNAWAVE_PANEL_TOKEN=your_api_token
```

> Токен можно получить через API после логина или использовать логин/пароль, если Subscription Page это поддерживает. См. документацию: https://docs.rw/docs/install/remnawave-subscription-page

### 4.2. Настройка Nginx для Subscription Page

```nginx
server {
    listen 443 ssl;
    server_name sub.example.com;
    ssl_certificate ...;
    ssl_certificate_key ...;
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

URL `https://sub.example.com` будет использоваться как `REMNAWAVE_SUBSCRIPTION_URL`.

---

## 5. Регистрация в Yookassa

Yookassa (ЮKassa) — платёжная система для приёма платежей.

### 5.1. Регистрация

1. Перейдите на https://yookassa.ru
2. Зарегистрируйтесь как продавец
3. Заполните данные магазина и подтвердите аккаунт

### 5.2. Получение ключей

1. В личном кабинете: **Настройки** → **Ключи API**
2. Скопируйте:
   - **Shop ID** (ID магазина)
   - **Секретный ключ**

Эти значения — `YOOKASSA_SHOP_ID` и `YOOKASSA_SECRET_KEY`.

### 5.3. Тестовый режим

Для тестов можно создать тестовый магазин: https://yookassa.ru/joinups?createTestShop=true

Тестовые карты: https://yookassa.ru/developers/payment-acceptance/testing-and-going-live/testing

### 5.4. Webhook

После развёртывания бота укажите URL уведомлений:

1. **Настройки** → **Уведомления**
2. URL: `https://ваш-домен.com/webhook/yookassa`
3. События: **payment.succeeded**, **payment.canceled** (опционально)

---

## 6. Создание Telegram-бота

### 6.1. Создание бота

1. Откройте [@BotFather](https://t.me/BotFather) в Telegram
2. Команда: `/newbot`
3. Введите имя бота (например, `My VPN Bot`)
4. Введите username (например, `my_vpn_bot`)
5. Скопируйте выданный **токен** — это `TELEGRAM_BOT_TOKEN`

### 6.2. Опционально: команды бота

В BotFather: `/setcommands` → выберите бота → добавьте:

```
start - Начать
```

---

## 7. Установка и настройка VPN Bot

### 7.1. Установка одной командой

```bash
curl -sSL https://raw.githubusercontent.com/TheNotus/vlessbot/main/install.sh | sudo bash
```

Скрипт автоматически клонирует репозиторий и выполнит полную установку.

### 7.2. Или из локальной копии

```bash
git clone https://github.com/TheNotus/vlessbot.git
cd vlessbot
chmod +x install.sh
sudo ./install.sh
```

Скрипт:

- обновит систему
- установит Python 3.10+, pip, venv, cron, logrotate
- создаст пользователя `vpnbot` и директорию `/opt/vpn-bot`
- установит зависимости проекта
- настроит systemd для автозапуска после перезагрузки
- настроит cron для ежедневной очистки истёкших ключей (4:00)
- настроит ротацию логов (14 дней)

По умолчанию устанавливает в `/opt/vpn-bot`. Переменные:

- `VPN_BOT_INSTALL_DIR` — путь установки (по умолчанию `/opt/vpn-bot`)
- `VPN_BOT_USER` — пользователь (по умолчанию `vpnbot`)

### 7.3. Лёгкая установка (только зависимости)

Если система уже настроена и не нужен полный install.sh:

```bash
chmod +x install.sh
./install.sh  # без sudo — только venv и зависимости
```

### 7.4. Ручная установка (если install.sh не подходит)

```bash
python3 -m venv venv
source venv/bin/activate   # Linux/macOS
# или: venv\Scripts\activate  # Windows

pip install -r requirements.txt
cp .env.example .env
```

### 7.4. Редактирование .env

```bash
nano .env
```

Минимально заполните:

| Переменная | Описание | Пример |
|------------|----------|--------|
| `TELEGRAM_BOT_TOKEN` | Токен от BotFather | `123456:ABC-...` |
| `YOOKASSA_SHOP_ID` | ID магазина Yookassa | `123456` |
| `YOOKASSA_SECRET_KEY` | Секретный ключ Yookassa | `live_...` |
| `WEBHOOK_BASE_URL` | Публичный URL сервера (HTTPS) | `https://bot.example.com` |
| `REMNAWAVE_API_URL` | URL панели Remnawave | `https://panel.example.com` |
| `REMNAWAVE_USERNAME` | Логин администратора | `admin` |
| `REMNAWAVE_PASSWORD` | Пароль администратора | `your_password` |
| `REMNAWAVE_SQUAD_UUID` | UUID Internal Squad | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `REMNAWAVE_SUBSCRIPTION_URL` | URL Subscription Page | `https://sub.example.com` |

Опционально:

| Переменная | Описание | По умолчанию |
|------------|----------|--------------|
| `TRIAL_DAYS` | Дней пробного периода (0 = выключено) | `0` |
| `TRIAL_DATA_LIMIT_GB` | Лимит трафика для пробного периода (ГБ) | `5` |
| `REFERRAL_DAYS` | Дней к подписке за реферала (0 = выключено) | `0` |
| `EXPIRED_CLEANUP_DAYS` | Удалять ключи, истёкшие более N дней назад (0 = отключено) | `7` |

### 7.5. Доступность webhook из интернета

Webhook должен быть доступен по HTTPS. Варианты:

**A) Nginx + домен**

Пример для `bot.example.com`:

```nginx
server {
    listen 443 ssl;
    server_name bot.example.com;
    ssl_certificate ...;
    ssl_certificate_key ...;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**B) ngrok (для разработки)**

```bash
ngrok http 8000
```

В `.env` укажите выданный HTTPS-URL в `WEBHOOK_BASE_URL`.

---

## 8. Запуск и проверка

### 8.1. Запуск

```bash
source venv/bin/activate
MODE=webhook python main.py
```

Бот и webhook-сервер работают на порту 8000.

### 8.2. Запуск в фоне (systemd)

Создайте `/etc/systemd/system/vpn-bot.service`:

```ini
[Unit]
Description=VPN Telegram Bot
After=network.target

[Service]
Type=simple
User=your_user
WorkingDirectory=/home/your_user/vpn-bot
Environment="MODE=webhook"
ExecStart=/home/your_user/vpn-bot/venv/bin/python main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable vpn-bot
sudo systemctl start vpn-bot
sudo systemctl status vpn-bot
```

### 8.3. Проверка

1. Откройте бота в Telegram и нажмите `/start`
2. Должно появиться меню с тарифами
3. Выберите тариф → должна создаться ссылка на оплату
4. После тестовой оплаты подписка должна прийти в чат

---

## 9. Пробный режим и реферальная программа

### 9.1. Пробный период

В `.env`:

```
TRIAL_DAYS=3
TRIAL_DATA_LIMIT_GB=5
```

В боте появится кнопка «Попробовать бесплатно». Каждый пользователь может воспользоваться пробным периодом один раз.

### 9.2. Реферальная программа

В `.env`:

```
REFERRAL_DAYS=7
```

При нажатии «Реферальная программа» пользователь получает персональную ссылку вида `https://t.me/your_bot?start=ref_12345`. Когда *новый* пользователь (ещё не бывший в базе бота) перейдёт по ссылке, рефереру автоматически добавляется указанное количество дней к подписке в Remnawave. Бонус начисляется при наличии активной подписки у реферера.

> **Важно:** Реферер должен уже иметь активного пользователя в Remnawave (подписку или пробный период). Иначе продление невозможно.

---

## Две панели (не путать)

- **Remnawave Panel** — панель VPN (ноды, подписки, Internal Squad). Доступ по домену (`PANEL_DOMAIN`) или по IP:8080. Порт 8080.
- **Админ-панель бота** — управление ботом (пользователи, блокировка, .env). Только через SSH-туннель. При установке по install.sh вместе с Remnawave порт админ-панели бота — **8082** (8080 занят Remnawave). Подключение: `ssh -L 8082:127.0.0.1:8082 user@server` → http://127.0.0.1:8082.

Перед запуском certbot выполните `sudo nginx -t`. При ошибке «No such file or directory» для файла в `sites-enabled` удалите битую симлинку: `sudo rm /etc/nginx/sites-enabled/имя_файла.conf`.

---

## Решение проблем

| Проблема | Решение |
|----------|---------|
| «Ошибка авторизации Remnawave» | Проверьте URL, логин и пароль, доступность панели |
| «Short UUID не найден» | Убедитесь, что в Remnawave есть Internal Squad и он указан в `REMNAWAVE_SQUAD_UUID` |
| Webhook не вызывается | Проверьте доступность URL из интернета, HTTPS, настройки Yookassa |
| Подписка не приходит | Проверьте логи бота и webhook, настройки Yookassa webhook |
| Реферальные дни не начисляются | Реферер должен иметь активного пользователя в Remnawave (купленную подписку) |
| **Панель Remnawave не открывается (502)** | Проверьте `docker ps` (должен быть контейнер `remnawave`) и порт 8080: `ss -tlnp`. Если контейнера нет: `cd /opt/remnawave && sudo docker compose -f docker-compose-prod.yml -f docker-compose-sub.yml up -d` (или `docker-compose` вместо `docker compose`) |
| certbot / nginx: «No such file or directory» | Удалите битую симлинку в `sites-enabled`: `sudo rm /etc/nginx/sites-enabled/имя_файла.conf`, затем `sudo nginx -t` |

---

## Полезные ссылки

- [Remnawave Documentation](https://docs.rw/)
- [Yookassa API](https://yookassa.ru/developers/)
- [python-telegram-bot](https://github.com/python-telegram-bot/python-telegram-bot)
