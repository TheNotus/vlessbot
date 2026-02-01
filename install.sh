#!/bin/bash
# VPN Bot — единый скрипт полной установки (бот + Remnawave Panel)
# Использование: curl -sSL .../install.sh | sudo bash  или: sudo ./install.sh
# Режим выбирается автоматически: если проект уже установлен — обновление, иначе — чистая установка.
# Явно: sudo ./install.sh update  или  sudo ./install.sh install
# Автоматизация: WEBHOOK_DOMAIN=bot.example.com CERTBOT_EMAIL=admin@example.com sudo ./install.sh
# С панелью: PANEL_DOMAIN=panel.example.com SUB_DOMAIN=sub.domain.com (опционально)

set -e
# Ошибки и вывод команд установки показываются в консоли (без -qq и скрытия stderr)

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

# Рабочая директория — всегда корень (избегаем getcwd: cannot access parent directories при запуске из удалённой/недоступной папки)
cd /

INSTALL_DIR="${VPN_BOT_INSTALL_DIR:-/opt/vpn-bot}"
BOT_USER="${VPN_BOT_USER:-vpnbot}"
LOG_DIR="/var/log/vpn-bot"
SERVICE_NAME="vpn-bot"
REMNAWAVE_DIR="${REMNAWAVE_DIR:-/opt/remnawave}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
SUB_DOMAIN="${SUB_DOMAIN:-}"
PANEL_PORT="${PANEL_PORT:-8080}"
SUB_PORT="${SUB_PORT:-8081}"

# Автоопределение режима: обновление или чистая установка
# Явно: update / install | VPN_BOT_UPDATE=1 / VPN_BOT_INSTALL=1
# Авто: если /opt/vpn-bot существует и содержит main.py — режим обновления
UPDATE_MODE=false
INSTALL_MODE=false
if [ "${1:-}" = "update" ] || [ "${VPN_BOT_UPDATE:-0}" = "1" ] || [ "${VPN_BOT_UPDATE:-}" = "true" ]; then
    UPDATE_MODE=true
elif [ "${1:-}" = "install" ] || [ "${VPN_BOT_INSTALL:-0}" = "1" ] || [ "${VPN_BOT_INSTALL:-}" = "true" ]; then
    INSTALL_MODE=true
else
    # Автопроверка: проект уже установлен?
    if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/main.py" ]; then
        UPDATE_MODE=true
    fi
fi

if [ "$UPDATE_MODE" = "true" ]; then
    echo "=========================================="
    echo "  VPN Bot — Обновление (данные сохранены)"
    echo "=========================================="
    echo ""
    if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/main.py" ]; then
        echo -e "${RED}Проект не установлен. Сначала выполните полную установку.${NC}"
        echo -e "  (явно: ${CYAN}sudo ./install.sh install${NC})"
        exit 1
    fi
    echo "Директория: $INSTALL_DIR"
    echo ""

    # Обновление кода из git (если есть .git) или curl
    cd "$INSTALL_DIR"
    if [ -d ".git" ]; then
        echo "[1/4] Обновление из git..."
        git fetch origin
        git checkout -q "$REPO_BRANCH" 2>/dev/null || true
        git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || git pull origin "$REPO_BRANCH" || true
    else
        echo "[1/4] Скачивание обновлений..."
        TMP_CLONE=$(mktemp -d)
        trap "rm -rf $TMP_CLONE" EXIT
        git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMP_CLONE"
        rsync -a --exclude='.env' --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' \
            --exclude='vpn_bot.db' --exclude='*.db' --exclude='.git' \
            "$TMP_CLONE/" "$INSTALL_DIR/"
    fi

    echo "[2/4] Обновление Python-зависимостей..."
    PY_VENV="$INSTALL_DIR/venv/bin/python"
    if [ ! -f "$PY_VENV" ]; then
        echo "  Создание venv..."
        python3 -m venv "$INSTALL_DIR/venv"
    fi
    "$PY_VENV" -m pip install -q --upgrade pip 2>/dev/null || true
    "$PY_VENV" -m pip install -r "$INSTALL_DIR/requirements.txt"

    echo "[3/4] Проверка БД..."
    "$PY_VENV" -c "
import asyncio
from database import Database
asyncio.run(Database().init())
print('  БД в порядке')
" 2>/dev/null || echo "  (БД — проверьте вручную)"

    chown -R "$BOT_USER:$BOT_USER" "$INSTALL_DIR"
    echo "[4/4] Перезапуск сервиса..."
    systemctl restart "$SERVICE_NAME"
    echo ""
    echo -e "${GREEN}Обновление завершено. Данные (.env, БД) сохранены.${NC}"
    echo "Логи: sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    exit 0
fi

echo "=========================================="
echo "  VPN Bot — Полная установка"
echo "=========================================="
echo ""
echo "Директория: $INSTALL_DIR | Пользователь: $BOT_USER"
echo -e "  (Обновление при следующем запуске: ${CYAN}sudo ./install.sh${NC})"
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
apt-get update
apt-get upgrade -y

# 2. Установка зависимостей
echo "[2/10] Установка Python, nginx и зависимостей..."
apt-get install -y \
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

# 2b. Установка Remnawave Panel (официальный remnawave/backend + Subscription Page)
if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
    # Определить команду: docker compose (v2) или docker-compose (v1/standalone)
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null && docker-compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        DOCKER_COMPOSE_CMD="docker-compose"
    fi
    echo "[2b/10] Установка Remnawave Panel..."
    if ! command -v docker &>/dev/null; then
        echo "  Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    if ! command -v docker &>/dev/null; then
        apt-get install -y docker.io docker-compose-v2
        systemctl enable docker
        systemctl start docker
    fi
    mkdir -p "$REMNAWAVE_DIR"
    cd "$REMNAWAVE_DIR"

    echo "  Скачивание официальных файлов Remnawave..."
    curl -fsSL -o docker-compose-prod.yml "https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml"
    curl -fsSL -o .env "https://raw.githubusercontent.com/remnawave/backend/main/.env.sample"

    # Генерация секретов
    JWT_AUTH=$(openssl rand -hex 64)
    JWT_API=$(openssl rand -hex 64)
    PG_PASS=$(openssl rand -hex 24)
    METRICS_PASS=$(openssl rand -hex 16)
    WEBHOOK_SECRET=$(openssl rand -hex 32)

    sed -i "s|^JWT_AUTH_SECRET=.*|JWT_AUTH_SECRET=$JWT_AUTH|" .env
    sed -i "s|^JWT_API_TOKENS_SECRET=.*|JWT_API_TOKENS_SECRET=$JWT_API|" .env
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG_PASS|" .env
    sed -i "s|^METRICS_PASS=.*|METRICS_PASS=$METRICS_PASS|" .env
    sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET|" .env
    sed -i "s|postgresql://postgres:[^@]*@|postgresql://postgres:$PG_PASS@|" .env

    # Домены (без http/https, без / в конце)
    FRONT_DOMAIN="${PANEL_DOMAIN:-*}"
    SUB_PUBLIC="${SUB_DOMAIN:-${PANEL_DOMAIN:-panel.local}}"
    sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$FRONT_DOMAIN|" .env
    sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_PUBLIC|" .env

    # Порт панели: host PANEL_PORT -> container 3000
    sed -i "s|- 127.0.0.1:3000:\${APP_PORT:-3000}|- 127.0.0.1:${PANEL_PORT}:3000|" docker-compose-prod.yml

    # Патч healthcheck remnawave-db: упрощение и start_period (обход race при инициализации Postgres)
    sed -i "s|pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}|pg_isready -U postgres -d postgres|" docker-compose-prod.yml
    python3 << 'PYEOF'
with open('docker-compose-prod.yml') as f:
    lines = f.readlines()
out = []
for i, line in enumerate(lines):
    if 'retries: 3' in line and i > 0 and 'timeout: 10s' in lines[i - 1]:
        indent = len(line) - len(line.lstrip())
        out.append(line.replace('retries: 3', 'retries: 5'))
        out.append(' ' * indent + 'start_period: 30s\n')
    else:
        out.append(line)
with open('docker-compose-prod.yml', 'w') as f:
    f.writelines(out)
PYEOF

    # Subscription Page (merge с основным compose)
    cat > docker-compose-sub.yml << REMNAWAVESUB
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    env_file: .env
    environment:
      - APP_PORT=3010
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - REMNAWAVE_API_TOKEN=\${REMNAWAVE_API_TOKEN:-}
    ports:
      - "127.0.0.1:${SUB_PORT}:3010"
    networks:
      - remnawave-network
    depends_on:
      remnawave:
        condition: service_healthy
REMNAWAVESUB

    # Пустой REMNAWAVE_API_TOKEN (добавить после создания в панели)
    grep -q "^REMNAWAVE_API_TOKEN=" .env || echo "REMNAWAVE_API_TOKEN=" >> .env

    # Остановить старые контейнеры (если была установка с remnawave/panel)
    docker stop remnawave-panel remnawave-subscription 2>/dev/null || true
    docker rm remnawave-panel remnawave-subscription 2>/dev/null || true

    echo "  Запуск контейнеров Remnawave..."
    $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml -f docker-compose-sub.yml up -d
    sleep 8
    if ! docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo "  ⚠ Контейнер remnawave не запущен, повторный запуск..."
        $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml -f docker-compose-sub.yml up -d
        sleep 5
    fi
    if docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo "  Remnawave Panel: http://127.0.0.1:$PANEL_PORT (nginx ниже)"
    else
        echo "  ⚠ Remnawave Panel: контейнер не запущен. Проверьте: cd $REMNAWAVE_DIR && sudo $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml logs -f"
    fi
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
        [ -n "$CERTBOT_EMAIL" ] && certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" || true
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
        [ -n "$CERTBOT_EMAIL" ] && certbot --nginx -d "$SUB_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" || true
        echo "  Subscription: https://$SUB_DOMAIN"
    fi
    nginx -t && systemctl reload nginx || true

    # Обновить .env бота (если ещё не создан, будет ниже)
    # API — всегда localhost (бот и панель на одном сервере, без зависимости от DNS)
    REMNAWAVE_API_URL="http://127.0.0.1:$PANEL_PORT"
    REMNAWAVE_SUB_URL="http://127.0.0.1:$SUB_PORT"
    [ -n "$SUB_DOMAIN" ] && REMNAWAVE_SUB_URL="https://$SUB_DOMAIN"
fi
cd /

# 3. Python 3.10+
echo "[3/10] Проверка Python..."
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0")
if [[ "$(printf '%s\n' "3.10" "$PYTHON_VERSION" | sort -V | head -n1)" != "3.10" ]] && [[ "$PYTHON_VERSION" != "0" ]]; then
    echo "  Добавление PPA для Python 3.10..."
    add-apt-repository -y ppa:deadsnakes/ppa || true
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-dev
    PYTHON_CMD=python3.10
else
    PYTHON_CMD=python3
fi
echo "  Python: $($PYTHON_CMD --version)"

# 4. Пользователь и директории
echo "[4/10] Создание пользователя и директорий..."
if ! id "$BOT_USER" &>/dev/null; then
    if getent group "$BOT_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash -g "$BOT_USER" "$BOT_USER"
    else
        useradd -r -m -s /bin/bash "$BOT_USER"
    fi
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
pip install --upgrade pip
pip install -r requirements.txt
echo "  Зависимости установлены"

$PYTHON_CMD -c "
import asyncio
from database import Database
asyncio.run(Database().init())
print('  БД инициализирована')
" || echo "  (БД при первом запуске — проверьте логи выше)"

# 7. .env
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    echo ""
    echo "  ⚠ Создан .env — ОБЯЗАТЕЛЬНО отредактируйте!"
fi

# Пароль админ-панели: если пустой — сгенерировать и вывести в конце
GENERATED_ADMIN_PASSWORD=""
if [ -f "$INSTALL_DIR/.env" ]; then
    if ! grep -q '^ADMIN_PANEL_PASSWORD=.\+' "$INSTALL_DIR/.env" 2>/dev/null; then
        GENERATED_ADMIN_PASSWORD=$(openssl rand -hex 8)
        if grep -q '^ADMIN_PANEL_PASSWORD=' "$INSTALL_DIR/.env" 2>/dev/null; then
            sed -i "s|^ADMIN_PANEL_PASSWORD=.*|ADMIN_PANEL_PASSWORD=$GENERATED_ADMIN_PASSWORD|" "$INSTALL_DIR/.env"
        else
            echo "ADMIN_PANEL_PASSWORD=$GENERATED_ADMIN_PASSWORD" >> "$INSTALL_DIR/.env"
        fi
    fi
    # Админ-панель: включить по умолчанию, если не задано иначе переменной окружения
    if [ "${ADMIN_PANEL_ENABLED}" != "false" ]; then
        if grep -q '^ADMIN_PANEL_ENABLED=' "$INSTALL_DIR/.env" 2>/dev/null; then
            sed -i "s|^ADMIN_PANEL_ENABLED=.*|ADMIN_PANEL_ENABLED=true|" "$INSTALL_DIR/.env"
        else
            echo "ADMIN_PANEL_ENABLED=true" >> "$INSTALL_DIR/.env"
        fi
    fi
    # Конфликт портов: Remnawave Panel на 8080 — админ-панель бота на 8082
    if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
        if grep -q '^ADMIN_PANEL_PORT=' "$INSTALL_DIR/.env" 2>/dev/null; then
            sed -i "s|^ADMIN_PANEL_PORT=.*|ADMIN_PANEL_PORT=8082|" "$INSTALL_DIR/.env"
        else
            echo "ADMIN_PANEL_PORT=8082" >> "$INSTALL_DIR/.env"
        fi
    fi
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
nginx -t && systemctl reload nginx || echo "  Nginx: отредактируйте /etc/nginx/sites-available/vpn-bot (server_name) и выполните: sudo nginx -t"
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
    if certbot --nginx -d "$WEBHOOK_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
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
systemctl start $SERVICE_NAME || true

echo ""
echo -e "\n${GREEN}=====================================================${NC}"
echo -e "${GREEN}      🎉 Установка успешно завершена! 🎉      ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""
echo -e "${RED}СДЕЛАЙТЕ ПО ПОРЯДКУ (скопируйте команды):${NC}"
echo ""

if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
echo -e "${CYAN}Шаг 1. Remnawave Panel (панель VPN)${NC}"
if [ -n "$PANEL_DOMAIN" ]; then
echo -e "   Откройте в браузере: ${YELLOW}https://${PANEL_DOMAIN}${NC}"
else
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "   Откройте в браузере: ${YELLOW}http://${SERVER_IP:-IP}:${PANEL_PORT}${NC}"
fi
echo -e "   • Создайте учётную запись администратора (логин и пароль — запомните)"
echo -e "   • Добавьте Node (VPN-сервер), создайте Internal Squad (группу подписок)"
echo -e "   • Зайдите в Settings → API Tokens → создайте токен"
echo -e "   • Вставьте токен в файл: ${CYAN}sudo nano $REMNAWAVE_DIR/.env${NC}"
echo -e "     (строка REMNAWAVE_API_TOKEN=). Сохранить: Ctrl+O, Enter. Выход: Ctrl+X"
echo -e "   • Перезапустите: ${CYAN}cd $REMNAWAVE_DIR && sudo $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml -f docker-compose-sub.yml restart remnawave-subscription-page${NC}"
echo ""
echo -e "${CYAN}Шаг 2. Файл настроек бота (.env)${NC}"
echo -e "   Откройте: ${CYAN}sudo nano $INSTALL_DIR/.env${NC}"
echo -e "   Заполните (где взять — в скобках):"
echo -e "   • TELEGRAM_BOT_TOKEN — токен от @BotFather в Telegram"
echo -e "   • ADMIN_IDS — ваш Telegram ID (число, можно узнать у @userinfobot)"
echo -e "   • YOOKASSA_SHOP_ID и YOOKASSA_SECRET_KEY — из личного кабинета ЮKassa"
echo -e "   • REMNAWAVE_USERNAME и REMNAWAVE_PASSWORD — логин и пароль из шага 1"
echo -e "   • REMNAWAVE_SQUAD_UUID — UUID группы (Internal Squad) из Remnawave"
echo -e "   • REMNAWAVE_SUBSCRIPTION_URL — уже подставлен; если меняли домен — поправьте"
echo -e "   Сохранить: Ctrl+O, Enter. Выход: Ctrl+X"
echo ""
echo -e "${CYAN}Шаг 3. ЮKassa${NC}"
echo -e "   В личном кабинете ЮKassa → Настройки → Уведомления укажите URL:"
echo -e "   ${YELLOW}https://${WEBHOOK_DOMAIN}/webhook/yookassa${NC}"
echo ""
echo -e "${CYAN}Шаг 4. Перезапуск бота${NC}"
echo -e "   ${CYAN}sudo systemctl restart vpn-bot${NC}"
echo ""
else
echo -e "${CYAN}Шаг 1. Файл настроек бота (.env)${NC}"
echo -e "   Откройте: ${CYAN}sudo nano $INSTALL_DIR/.env${NC}"
echo -e "   Заполните: TELEGRAM_BOT_TOKEN (от @BotFather), ADMIN_IDS, YOOKASSA_*, REMNAWAVE_*"
echo -e "   Сохранить: Ctrl+O, Enter. Выход: Ctrl+X"
echo ""
echo -e "${CYAN}Шаг 2. ЮKassa${NC}"
echo -e "   URL уведомлений: ${YELLOW}https://${WEBHOOK_DOMAIN}/webhook/yookassa${NC}"
echo ""
echo -e "${CYAN}Шаг 3. Перезапуск бота${NC}"
echo -e "   ${CYAN}sudo systemctl restart vpn-bot${NC}"
echo ""
fi

ADMIN_PORT_FINAL=8080
[ "$REMNAWAVE_PANEL_INSTALL" = "true" ] && ADMIN_PORT_FINAL=8082
echo -e "${CYAN}Админ-панель бота${NC} (управление пользователями, .env):"
echo -e "   С вашего компьютера: ${CYAN}ssh -L ${ADMIN_PORT_FINAL}:127.0.0.1:${ADMIN_PORT_FINAL} ВАШ_ЛОГИН@IP_ЭТОГО_СЕРВЕРА${NC}"
echo -e "   Затем в браузере откройте: ${YELLOW}http://127.0.0.1:${ADMIN_PORT_FINAL}${NC}"
if [ -n "$GENERATED_ADMIN_PASSWORD" ]; then
    echo -e "   Пароль для входа: ${YELLOW}${GENERATED_ADMIN_PASSWORD}${NC} (смените в панели в Настройках)"
fi
echo ""
echo -e "Логи бота: ${CYAN}sudo journalctl -u $SERVICE_NAME -f${NC}"
echo ""
