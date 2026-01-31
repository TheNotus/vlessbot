#!/bin/bash
# VPN Bot - Полная установка на чистый Ubuntu
# Использование:
#   curl -sSL https://raw.githubusercontent.com/TheNotus/vlessbot/main/install.sh | sudo bash
#   sudo ./install.sh  — полная установка из локальной папки
#   ./install.sh       — лёгкая установка (только venv и зависимости)

set -e

REPO_URL="${VPN_BOT_REPO:-https://github.com/TheNotus/vlessbot.git}"
REPO_BRANCH="${VPN_BOT_BRANCH:-main}"

# Определение исходной директории проекта
# При curl | bash: $0="bash", проекта нет — клонируем из git
SCRIPT_DIR=""
if [ -n "$0" ] && [ -f "$0" ] 2>/dev/null; then
    cd "$(dirname "$0")" 2>/dev/null || true
    SCRIPT_DIR="$(pwd)"
fi
# Проверка: в SCRIPT_DIR есть проект? (main.py, requirements.txt)
if [ -z "$SCRIPT_DIR" ] || [ ! -f "${SCRIPT_DIR}/main.py" ] || [ ! -f "${SCRIPT_DIR}/requirements.txt" ]; then
    SCRIPT_DIR=""
fi

# Проверка root — полная или лёгкая установка
FULL_INSTALL=false
if [ "$EUID" -eq 0 ]; then
    FULL_INSTALL=true
fi

# Конфигурация установки
INSTALL_DIR="${VPN_BOT_INSTALL_DIR:-/opt/vpn-bot}"
BOT_USER="${VPN_BOT_USER:-vpnbot}"
LOG_DIR="/var/log/vpn-bot"
SERVICE_NAME="vpn-bot"

if [ "$FULL_INSTALL" = true ]; then
    echo "=========================================="
    echo "  VPN Bot - Полная установка Ubuntu"
    echo "=========================================="
    echo ""
    echo "Директория: $INSTALL_DIR | Пользователь: $BOT_USER"
    echo ""
else
    echo "=========================================="
    echo "  VPN Bot - Лёгкая установка"
    echo "=========================================="
    INSTALL_DIR="$SCRIPT_DIR"
    echo ""
fi

# Лёгкая установка (без sudo) — требует локальный проект
if [ "$FULL_INSTALL" = false ]; then
    if [ -z "$SCRIPT_DIR" ]; then
        echo "Лёгкая установка требует локальную копию проекта."
        echo "Выполните: git clone $REPO_URL && cd vlessbot && ./install.sh"
        exit 1
    fi
    echo "Установка в текущую директорию: $SCRIPT_DIR"
    INSTALL_DIR="$SCRIPT_DIR"
    if ! command -v python3 &>/dev/null; then
        echo "Ошибка: Python 3 не найден"
        exit 1
    fi
    cd "$INSTALL_DIR"
    python3 -m venv venv 2>/dev/null || true
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
    [ ! -f .env ] && cp .env.example .env && echo "Создан .env"
    python3 -c "import asyncio; from database import Database; asyncio.run(Database().init())" 2>/dev/null || true
    echo "Готово. Отредактируйте .env и запустите: python main.py"
    exit 0
fi

# === Полная установка (с sudo) ===

# 1. Обновление системы
echo "[1/8] Обновление системы..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# 2. Установка зависимостей
echo "[2/8] Установка Python и зависимостей..."
apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    curl \
    git \
    cron \
    logrotate \
    rsync

# Ubuntu 22.04+ имеет Python 3.10, для 20.04 может понадобиться PPA
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0")
if [[ "$(printf '%s\n' "3.10" "$PYTHON_VERSION" | sort -V | head -n1)" != "3.10" ]] && [[ "$PYTHON_VERSION" != "0" ]]; then
    echo "  Добавление PPA для Python 3.10..."
    add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
    apt-get update -qq
    apt-get install -y -qq python3.10 python3.10-venv python3.10-dev
    PYTHON_CMD=python3.10
else
    PYTHON_CMD=python3
fi

echo "  Python: $($PYTHON_CMD --version)"

# 3. Создание пользователя и директорий
echo "[3/8] Создание пользователя и директорий..."
if ! id "$BOT_USER" &>/dev/null; then
    useradd -r -m -s /bin/bash "$BOT_USER"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
chown -R "$BOT_USER:$BOT_USER" "$LOG_DIR"
chmod 755 "$LOG_DIR"

# 4. Получение/копирование файлов проекта
echo "[4/8] Установка проекта..."
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/main.py" ] && [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    # Есть локальный проект — копируем
    rsync -a --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' --exclude='.git' \
        "$SCRIPT_DIR/" "$INSTALL_DIR/" 2>/dev/null || \
    cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR/" 2>/dev/null || true
else
    # curl | bash — клонируем из репозитория
    TMP_CLONE=$(mktemp -d)
    trap "rm -rf $TMP_CLONE" EXIT
    echo "  Клонирование из $REPO_URL ($REPO_BRANCH)..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMP_CLONE"
    rsync -a --exclude='.git' "$TMP_CLONE/" "$INSTALL_DIR/"
fi

# 5. Виртуальное окружение и зависимости
echo "[5/8] Установка Python-зависимостей..."
cd "$INSTALL_DIR"
$PYTHON_CMD -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q
echo "  Зависимости установлены"

# Инициализация БД
$PYTHON_CMD -c "
import asyncio
from database import Database
asyncio.run(Database().init())
print('  База данных инициализирована')
" 2>/dev/null || echo "  (БД создастся при первом запуске)"

# 6. Конфигурация .env
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    echo ""
    echo "  ⚠ Создан .env — ОБЯЗАТЕЛЬНО отредактируйте перед запуском!"
fi
chown -R "$BOT_USER:$BOT_USER" "$INSTALL_DIR"

# 7. Systemd сервис
echo "[6/8] Настройка автозапуска (systemd)..."
cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=VPN Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$BOT_USER
Group=$BOT_USER
WorkingDirectory=$INSTALL_DIR
Environment="MODE=webhook"
Environment="VPN_BOT_LOG_DIR=$LOG_DIR"
EnvironmentFile=-$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/python main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
echo "  Сервис $SERVICE_NAME включён в автозапуск"

# 8. Cron для очистки истёкших ключей
echo "[7/8] Настройка очистки истёкших ключей (cron)..."
CRON_CMD="0 4 * * * $BOT_USER cd $INSTALL_DIR && $INSTALL_DIR/venv/bin/python cleanup_expired.py >> $LOG_DIR/cleanup.log 2>&1"
(crontab -l -u $BOT_USER 2>/dev/null | grep -v "cleanup_expired.py" || true; echo "$CRON_CMD") | crontab -u $BOT_USER -
echo "  Cron: ежедневно в 4:00"

# 9. Logrotate
echo "[8/8] Настройка ротации логов..."
cat > /etc/logrotate.d/vpn-bot << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 $BOT_USER $BOT_USER
}
EOF
echo "  Logrotate настроен (14 дней, сжатие)"

echo ""
echo "=========================================="
echo "  Установка завершена!"
echo "=========================================="
echo ""
echo "Следующие шаги:"
echo "  1. Отредактируйте конфигурацию:"
echo "     sudo nano $INSTALL_DIR/.env"
echo ""
echo "  2. Запустите сервис:"
echo "     sudo systemctl start $SERVICE_NAME"
echo ""
echo "  3. Проверьте статус:"
echo "     sudo systemctl status $SERVICE_NAME"
echo ""
echo "  4. Просмотр логов:"
echo "     sudo journalctl -u $SERVICE_NAME -f"
echo "     или: tail -f $LOG_DIR/vpn-bot.log"
echo ""
echo "Управление:"
echo "  Запуск:   sudo systemctl start $SERVICE_NAME"
echo "  Остановка: sudo systemctl stop $SERVICE_NAME"
echo "  Перезапуск: sudo systemctl restart $SERVICE_NAME"
echo ""
