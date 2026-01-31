# VPN Bot — продажа подписок через Telegram

Telegram-бот для продажи VPN ключей с интеграцией **Remnawave** и **Yookassa**.

## Возможности

- Выбор тарифного плана в боте
- Оплата через Yookassa (карты, СБП, ЮMoney)
- Автоматическое создание пользователя в Remnawave
- Выдача группы подписок (Internal Squad) после оплаты
- Отправка ссылки на подписку в Telegram
- **Пробный период** — настраиваемое количество дней (TRIAL_DAYS)
- **Реферальная программа** — бонусные дни за приглашённых (REFERRAL_DAYS)

## Требования

- Python 3.10+
- Панель Remnawave с настроенными Internal Squads
- Аккаунт Yookassa
- Домен с HTTPS для webhook

## Установка

### Одна команда (рекомендуется)

```bash
curl -sSL https://raw.githubusercontent.com/TheNotus/vlessbot/main/install.sh | sudo bash
```

Скрипт клонирует репозиторий и выполняет полную установку.

### Полная установка из локальной папки

```bash
git clone https://github.com/TheNotus/vlessbot.git && cd vlessbot
chmod +x install.sh
sudo ./install.sh
```

### Лёгкая (Linux/macOS)

```bash
chmod +x install.sh
./install.sh
```

### Автоматическая (Windows)

```cmd
install.bat
```

### Ручная

```bash
python -m venv venv
source venv/bin/activate  # Linux/Mac
# или venv\Scripts\activate  # Windows

pip install -r requirements.txt
cp .env.example .env
# Редактирование .env
```

**Подробная инструкция с нуля:** см. [SETUP.md](SETUP.md)

## Конфигурация

### 1. Remnawave

1. Войдите в панель Remnawave
2. Создайте **Internal Squad** (группу подписок) в разделе Internal Squads
3. Скопируйте UUID группы
4. Укажите в `.env`:
   - `REMNAWAVE_SQUAD_UUID` — UUID группы
   - `REMNAWAVE_SUBSCRIPTION_URL` — URL страницы подписок (Subscription Page)

### 2. Yookassa

1. Зарегистрируйтесь на [yookassa.ru](https://yookassa.ru)
2. Получите Shop ID и Secret Key в личном кабинете
3. Настройте Webhook: URL уведомлений = `https://your-domain.com/webhook/yookassa`

### 3. Webhook

Webhook должен быть доступен по HTTPS. Для разработки можно использовать [ngrok](https://ngrok.com):

```bash
ngrok http 8000
# Используйте выданный URL в WEBHOOK_BASE_URL
```

## Запуск

```bash
# Режим webhook (бот + приём платежей)
MODE=webhook python main.py

# Только бот (без оплаты, для тестов)
MODE=bot python main.py
```

## Структура проекта

```
├── main.py              # Точка входа
├── bot.py               # Telegram бот
├── webhook.py           # Webhook Yookassa
├── cleanup_expired.py   # Очистка истёкших ключей (cron)
├── logging_config.py    # Настройка логов
├── config.py            # Конфигурация
├── database.py          # SQLite база заказов
├── remnawave_client.py  # API Remnawave
├── yookassa_client.py   # API Yookassa
├── install.sh           # Полная установка Ubuntu
├── requirements.txt
└── .env.example
```

## Тарифы

По умолчанию:
- 1 месяц — 199 ₽
- 3 месяца — 499 ₽
- 12 месяцев — 1499 ₽

Настройка через переменную `PLANS` в `.env` (формат: `id:name:price:days:gb;squad_uuid`).

## Безопасность

- Не коммитьте `.env` в репозиторий
- Используйте HTTPS для webhook
- Храните секреты Yookassa и Remnawave в безопасном месте
