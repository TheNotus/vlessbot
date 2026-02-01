#!/bin/bash
# VPN Bot — единый скрипт полной установки (бот + Remnawave Panel)
# Использование: curl -sSL .../install.sh | sudo bash  или: sudo ./install.sh
# Автоматизация: WEBHOOK_DOMAIN=bot.example.com CERTBOT_EMAIL=admin@example.com sudo ./install.sh
# С панелью: PANEL_DOMAIN=panel.example.com SUB_DOMAIN=sub.example.com (опционально)

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_URL="${VPN_BOT_REPO:-https://github.com/TheNotus/vlessbot.git}"
REPO_BRANCH="${VPN_BOT_BRANCH:-main}"
REMNAWAVE_PANEL_INSTALL="${REMNAWAVE_PANEL_INSTALL:-true}"

SCRIPT_DIR=""
if [ -n "$0" ] && [ -f "$0" ] 2>/dev/null; then
    cd "$(dirname "$0")" 2>/dev/null || true
    SCRIPT_DIR="$(pwd)"
fi
if [ -z "$SCRIPT_DIR" ] || [ ! -f "${SCRIPT_DIR}/main.py" ] || [ ! -f "${SCRIPT_DIR}/requirements.txt" ]; then
    SCRIPT_DIR=""
fi

if [ "$EUID" -ne 0 ]; then
    echo "Требуется root. Запустите: sudo ./install.sh"
    echo "Или: curl -sSL .../install.sh | sudo bash"
    exit 1
fi

INSTALL_DIR="${VPN_BOT_INSTALL_DIR:-/opt/vpn-bot}"
BOT_USER="${VPN_BOT_USER:-vpnbot}"
LOG_DIR="/var/log/vpn-bot"
SERVICE_NAME="vpn-bot"
REMNAWAVE_DIR="${REMNAWAVE_DIR:-/opt/remnawave}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
SUB_DOMAIN="${SUB_DOMAIN:-}"
PANEL_PORT="${PANEL_PORT:-8080}"
SUB_PORT="${SUB_PORT:-8081}"

echo "=========================================="
echo "  VPN Bot — Полная установка"
echo "=========================================="
echo ""
echo "Директория: $INSTALL_DIR | Пользователь: $BOT_USER"
echo ""

# Запрос доменов (если не заданы переменными)
# </dev/tty — чтобы read работал при curl | bash (stdin иначе занят pipe)
if [ -z "$WEBHOOK_DOMAIN" ] || [ "$WEBHOOK_DOMAIN" = "bot.example.com" ]; then
    echo -e "${CYAN}Введите домен для webhook бота (например bot.example.com):${NC}"
    echo -e "  DNS должен указывать на IP этого сервера."
    read -r -p "Домен: " WEBHOOK_DOMAIN </dev/tty
    WEBHOOK_DOMAIN="${WEBHOOK_DOMAIN:-bot.example.com}"
    if [ "$WEBHOOK_DOMAIN" = "bot.example.com" ]; then
        echo -e "  ${YELLOW}Используется bot.example.com — замените вручную в nginx и .env${NC}"
    fi
fi
if [ -z "$CERTBOT_EMAIL" ]; then
    read -r -p "Email для SSL (Let's Encrypt) или Enter чтобы пропустить: " CERTBOT_EMAIL </dev/tty
fi
if [ -z "$PANEL_DOMAIN" ] && [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
    read -r -p "Домен для Remnawave Panel (Enter — только по IP): " PANEL_DOMAIN </dev/tty
fi
if [ -z "$SUB_DOMAIN" ] && [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
    read -r -p "Домен для Subscription Page (Enter — только по IP): " SUB_DOMAIN </dev/tty
fi
echo ""

# 1. Обновление системы
echo "[1/10] Обновление системы..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# 2. Установка зависимостей
echo "[2/10] Установка Python, nginx и зависимостей..."
apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    curl \
    git \
    cron \
    logrotate \
    rsync \
    nginx \
    certbot \
    python3-certbot-nginx

# 2b. Установка Remnawave Panel (Docker + Panel + Subscription Page)
if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
    echo "[2b/10] Установка Remnawave Panel..."
    if ! command -v docker &>/dev/null; then
        echo "  Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    if ! command -v docker &>/dev/null; then
        apt-get install -y -qq docker.io docker-compose-v2
        systemctl enable docker
        systemctl start docker
    fi
    mkdir -p "$REMNAWAVE_DIR"
    # Subscription page вызывает API панели — при одном хосте используем internal URL
    PANEL_URL_FOR_SUB="http://panel:3000"
    cat > "$REMNAWAVE_DIR/docker-compose.yml" << REMNAWAVEEOF
services:
  panel:
    image: remnawave/panel:latest
    container_name: remnawave-panel
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PANEL_PORT}:3000"
    volumes:
      - ./data:/app/data
    environment:
      - NODE_ENV=production

  subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription
    restart: unless-stopped
    ports:
      - "127.0.0.1:${SUB_PORT}:3000"
    environment:
      - REMNAWAVE_PANEL_URL=${PANEL_URL_FOR_SUB}
      - REMNAWAVE_API_TOKEN=\${REMNAWAVE_API_TOKEN:-}
    depends_on:
      - panel
REMNAWAVEEOF
    cat > "$REMNAWAVE_DIR/.env" << REMNAWAVEENV
# Добавьте API токен после создания в панели: Settings -> API Tokens
REMNAWAVE_API_TOKEN=
REMNAWAVEENV
    cd "$REMNAWAVE_DIR"
    docker compose pull -q 2>/dev/null || docker-compose pull -q 2>/dev/null || true
    docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true
    echo "  Remnawave Panel: http://127.0.0.1:$PANEL_PORT (nginx ниже)"
    echo "  Subscription Page: http://127.0.0.1:$SUB_PORT"

    # Nginx для панели и subscription page
    if [ -n "$PANEL_DOMAIN" ]; then
        cat > /etc/nginx/sites-available/remnawave-panel << NGINXPANELEOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXPANELEOF
        ln -sf /etc/nginx/sites-available/remnawave-panel /etc/nginx/sites-enabled/ 2>/dev/null || true
        [ -n "$CERTBOT_EMAIL" ] && certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" 2>/dev/null || true
        echo "  Panel: https://$PANEL_DOMAIN"
    fi
    if [ -n "$SUB_DOMAIN" ]; then
        cat > /etc/nginx/sites-available/remnawave-sub << NGINXSUBEOF
server {
    listen 80;
    server_name $SUB_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXSUBEOF
        ln -sf /etc/nginx/sites-available/remnawave-sub /etc/nginx/sites-enabled/ 2>/dev/null || true
        [ -n "$CERTBOT_EMAIL" ] && certbot --nginx -d "$SUB_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" 2>/dev/null || true
        echo "  Subscription: https://$SUB_DOMAIN"
    fi
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

    # Обновить .env бота (если ещё не создан, будет ниже)
    # API — всегда localhost (бот и панель на одном сервере, без зависимости от DNS)
    REMNAWAVE_API_URL="http://127.0.0.1:$PANEL_PORT"
    REMNAWAVE_SUB_URL="http://127.0.0.1:$SUB_PORT"
    [ -n "$SUB_DOMAIN" ] && REMNAWAVE_SUB_URL="https://$SUB_DOMAIN"
fi

# 3. Python 3.10+
echo "[3/10] Проверка Python..."
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

# 4. Пользователь и директории
echo "[4/10] Создание пользователя и директорий..."
if ! id "$BOT_USER" &>/dev/null; then
    useradd -r -m -s /bin/bash "$BOT_USER"
fi
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
chown -R "$BOT_USER:$BOT_USER" "$LOG_DIR"
chmod 755 "$LOG_DIR"

# 5. Проект
echo "[5/10] Установка проекта..."
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/main.py" ] && [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    rsync -a --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' --exclude='.git' \
        "$SCRIPT_DIR/" "$INSTALL_DIR/" 2>/dev/null || cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR/" 2>/dev/null || true
else
    TMP_CLONE=$(mktemp -d)
    trap "rm -rf $TMP_CLONE" EXIT
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMP_CLONE"
    rsync -a --exclude='.git' "$TMP_CLONE/" "$INSTALL_DIR/"
fi

# 6. Python-зависимости
echo "[6/10] Установка Python-зависимостей..."
cd "$INSTALL_DIR"
$PYTHON_CMD -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q
echo "  Зависимости установлены"

$PYTHON_CMD -c "
import asyncio
from database import Database
asyncio.run(Database().init())
print('  БД инициализирована')
" 2>/dev/null || echo "  (БД при первом запуске)"

# 7. .env
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    echo ""
    echo "  ⚠ Создан .env — ОБЯЗАТЕЛЬНО отредактируйте!"
fi
chown -R "$BOT_USER:$BOT_USER" "$INSTALL_DIR"

# 8. Nginx (webhook бота)
echo ""
echo "[7/10] Настройка nginx..."
WEBHOOK_PORT="${WEBHOOK_PORT:-8000}"
cat > /etc/nginx/sites-available/vpn-bot << NGINXEOF
server {
    listen 80;
    server_name $WEBHOOK_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF
ln -sf /etc/nginx/sites-available/vpn-bot /etc/nginx/sites-enabled/ 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || echo "  Nginx: отредактируйте /etc/nginx/sites-available/vpn-bot (server_name)"
echo "  Nginx: server_name=$WEBHOOK_DOMAIN -> 127.0.0.1:$WEBHOOK_PORT"

# Обновить .env: WEBHOOK_BASE_URL
if [ -f "$INSTALL_DIR/.env" ] && [ "$WEBHOOK_DOMAIN" != "bot.example.com" ]; then
    WEBHOOK_URL="https://$WEBHOOK_DOMAIN"
    if grep -q "^WEBHOOK_BASE_URL=" "$INSTALL_DIR/.env" 2>/dev/null; then
        sed -i "s|^WEBHOOK_BASE_URL=.*|WEBHOOK_BASE_URL=$WEBHOOK_URL|" "$INSTALL_DIR/.env"
    else
        echo "WEBHOOK_BASE_URL=$WEBHOOK_URL" >> "$INSTALL_DIR/.env"
    fi
    echo "  .env: WEBHOOK_BASE_URL=$WEBHOOK_URL"
fi

# Certbot SSL (автоматически, если заданы WEBHOOK_DOMAIN и CERTBOT_EMAIL)
if [ "$WEBHOOK_DOMAIN" != "bot.example.com" ] && [ -n "$CERTBOT_EMAIL" ]; then
    echo "  Запуск certbot для $WEBHOOK_DOMAIN..."
    if certbot --nginx -d "$WEBHOOK_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" 2>/dev/null; then
        echo "  SSL: сертификат получен"
    else
        echo "  SSL: не удалось (проверьте DNS: $WEBHOOK_DOMAIN -> IP сервера)"
    fi
fi

# Обновить .env бота: REMNAWAVE_* (если панель установлена)
if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ] && [ -f "$INSTALL_DIR/.env" ]; then
    [ -n "$REMNAWAVE_API_URL" ] && (grep -q "^REMNAWAVE_API_URL=" "$INSTALL_DIR/.env" && sed -i "s|^REMNAWAVE_API_URL=.*|REMNAWAVE_API_URL=$REMNAWAVE_API_URL|" "$INSTALL_DIR/.env" || echo "REMNAWAVE_API_URL=$REMNAWAVE_API_URL" >> "$INSTALL_DIR/.env")
    [ -n "$REMNAWAVE_SUB_URL" ] && (grep -q "^REMNAWAVE_SUBSCRIPTION_URL=" "$INSTALL_DIR/.env" && sed -i "s|^REMNAWAVE_SUBSCRIPTION_URL=.*|REMNAWAVE_SUBSCRIPTION_URL=$REMNAWAVE_SUB_URL|" "$INSTALL_DIR/.env" || echo "REMNAWAVE_SUBSCRIPTION_URL=$REMNAWAVE_SUB_URL" >> "$INSTALL_DIR/.env")
fi

# 10. Systemd
echo "[8/10] Настройка systemd..."
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
echo "  Сервис включён"

# 11. Cron
echo "[9/10] Cron и завершение..."
CRON_CMD="0 4 * * * $BOT_USER cd $INSTALL_DIR && $INSTALL_DIR/venv/bin/python cleanup_expired.py >> $LOG_DIR/cleanup.log 2>&1"
(crontab -l -u $BOT_USER 2>/dev/null | grep -v "cleanup_expired.py" || true; echo "$CRON_CMD") | crontab -u $BOT_USER -

# Logrotate
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

# Автозапуск сервиса
echo "  Запуск сервиса..."
systemctl start $SERVICE_NAME 2>/dev/null || true

echo ""
echo -e "\n${GREEN}=====================================================${NC}"
echo -e "${GREEN}      🎉 Установка успешно завершена! 🎉      ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""
echo -e "Webhook бота доступен по адресу:"
echo -e "  - ${YELLOW}https://${WEBHOOK_DOMAIN}/webhook/yookassa${NC}"
echo ""
echo -e "${RED}ПЕРВЫЕ ШАГИ:${NC}"
echo -e "1. Отредактируйте .env — токены, пароли, REMNAWAVE_*:"
echo -e "   ${CYAN}sudo nano $INSTALL_DIR/.env${NC}"
echo ""
echo -e "2. В YooKassa укажите URL уведомлений:"
echo -e "   ${YELLOW}https://${WEBHOOK_DOMAIN}/webhook/yookassa${NC}"
echo ""
if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
echo -e "3. Remnawave Panel:"
if [ -n "$PANEL_DOMAIN" ]; then
echo -e "   - Панель: ${YELLOW}https://${PANEL_DOMAIN}${NC}"
else
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "   - Панель: ${YELLOW}http://${SERVER_IP:-IP}:${PANEL_PORT}${NC}"
fi
echo -e "   - Создайте админа, добавьте Node, Internal Squad"
echo -e "   - Settings -> API Tokens -> создайте токен"
echo -e "   - Добавьте токен в $REMNAWAVE_DIR/.env (REMNAWAVE_API_TOKEN)"
echo -e "   - ${CYAN}cd $REMNAWAVE_DIR && docker compose restart subscription-page${NC}"
echo ""
fi
echo -e "Логи бота: ${CYAN}sudo journalctl -u $SERVICE_NAME -f${NC}"
echo ""
echo -e "Админ-панель (ADMIN_PANEL_ENABLED=true):"
echo -e "  ${CYAN}ssh -L 8080:127.0.0.1:8080 user@server${NC} → http://127.0.0.1:8080"
echo ""
