#!/bin/bash
# VPN Bot — единый скрипт полной установки (бот + Remnawave Panel)
# Использование: curl -sSL .../install.sh | sudo bash  или: sudo ./install.sh
# Режим выбирается автоматически: если проект уже установлен — обновление, иначе — чистая установка.
# Явно: sudo ./install.sh update  или  sudo ./install.sh install
# Автоматизация: WEBHOOK_DOMAIN=bot.example.com CERTBOT_EMAIL=admin@example.com sudo ./install.sh
# С панелью: PANEL_DOMAIN=panel.example.com SUB_DOMAIN=sub.domain.com (опционально)
# Режим Remnawave без запроса: REMNAWAVE_PANEL_INSTALL=true|false; для ноды: REMNAWAVE_NODE_INSTALL=true SELFSTEAL_DOMAIN=node.example.com

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
# Remnawave: задаётся выбором пользователя или REMNAWAVE_MODE=panel_only | panel_and_node | node_only | skip
REMNAWAVE_PANEL_INSTALL="${REMNAWAVE_PANEL_INSTALL:-}"
REMNAWAVE_NODE_INSTALL="${REMNAWAVE_NODE_INSTALL:-false}"
SELFSTEAL_DOMAIN="${SELFSTEAL_DOMAIN:-}"

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

    # Добавить REMNAWAVE_API_TOKEN в /opt/remnawave/.env если отсутствует (для Subscription Page)
    if [ -f "$REMNAWAVE_DIR/.env" ] && ! grep -q "^REMNAWAVE_API_TOKEN=" "$REMNAWAVE_DIR/.env" 2>/dev/null; then
        echo "" >> "$REMNAWAVE_DIR/.env"
        echo "# Subscription Page: токен из Remnawave Panel → Settings → API Tokens" >> "$REMNAWAVE_DIR/.env"
        echo "REMNAWAVE_API_TOKEN=" >> "$REMNAWAVE_DIR/.env"
        echo "  Добавлено REMNAWAVE_API_TOKEN= в $REMNAWAVE_DIR/.env — заполните и перезапустите Subscription Page"
    fi

    # Разрешить перезапуск из админ-панели (если ещё нет)
    if [ ! -f /etc/sudoers.d/vpn-bot-restart ]; then
        echo "$BOT_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $SERVICE_NAME" > /etc/sudoers.d/vpn-bot-restart
        chmod 440 /etc/sudoers.d/vpn-bot-restart
    fi

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

# Выбор Remnawave (как в https://github.com/eGamesAPI/remnawave-reverse-proxy)
if [ -z "$REMNAWAVE_PANEL_INSTALL" ]; then
    echo -e "${CYAN}Установить Remnawave на этот сервер?${NC}"
    echo "  1) Нет — только VPN Bot"
    echo "  2) Панель и нода на одном сервере (панель + Xray-нода + заглушка SelfSteal)"
    echo "  3) Только панель Remnawave"
    echo "  4) Только нода Remnawave (бот не ставим; ноду ставьте скриптом remnawave-reverse-proxy)"
    read -r -p "Выбор (1–4) [1]: " REMNAWAVE_CHOICE </dev/tty
    REMNAWAVE_CHOICE="${REMNAWAVE_CHOICE:-1}"
    case "$REMNAWAVE_CHOICE" in
        2) REMNAWAVE_PANEL_INSTALL=true; REMNAWAVE_NODE_INSTALL=true ;;
        3) REMNAWAVE_PANEL_INSTALL=true; REMNAWAVE_NODE_INSTALL=false ;;
        4) REMNAWAVE_PANEL_INSTALL=false; REMNAWAVE_NODE_INSTALL=true ;;
        *) REMNAWAVE_PANEL_INSTALL=false; REMNAWAVE_NODE_INSTALL=false ;;
    esac
    echo ""
fi

# Режим «только нода» — выводим инструкцию и выходим (бот не ставим)
if [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && [ "$REMNAWAVE_PANEL_INSTALL" != "true" ]; then
    echo -e "${YELLOW}Режим «Только нода»: этот скрипт ставит VPN Bot и опционально панель.${NC}"
    echo "Для установки только ноды Remnawave (Xray, SelfSteal) используйте:"
    echo -e "  ${CYAN}bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)${NC}"
    echo ""
    read -r -p "Всё равно установить VPN Bot на этот сервер? (y/N): " INSTALL_BOT_ANYWAY </dev/tty
    if [ "${INSTALL_BOT_ANYWAY:-n}" != "y" ] && [ "${INSTALL_BOT_ANYWAY:-n}" != "Y" ]; then
        echo "Выход. Для ноды запустите скрипт по ссылке выше."
        exit 0
    fi
    REMNAWAVE_NODE_INSTALL=false
fi

# SelfSteal домен для ноды (только при выборе «Панель и нода на одном сервере»)
if [ "$REMNAWAVE_PANEL_INSTALL" = "true" ] && [ "$REMNAWAVE_NODE_INSTALL" = "true" ]; then
    if [ -z "$SELFSTEAL_DOMAIN" ]; then
        echo -e "${CYAN}Домен для SelfSteal (нода, маскировка):${NC}"
        echo "  Например node.example.com — на этот домен будет отдаваться заглушка сайта."
        read -r -p "SelfSteal домен (Enter — пропустить): " SELFSTEAL_DOMAIN </dev/tty
    fi
    echo ""
fi

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
    python3-certbot-nginx \
    unzip \
    jq

# Установка заглушки для SelfSteal (как в remnawave-reverse-proxy: simple/sni/nothing)
install_selfsteal_template() {
    [ -n "$SELFSTEAL_DOMAIN" ] || return 0
    [ -d /var/www/html ] || mkdir -p /var/www/html
    echo ""
    echo -e "${CYAN}Заглушка для SelfSteal ($SELFSTEAL_DOMAIN):${NC}"
    echo "  1) Simple web templates (eGamesAPI)"
    echo "  2) SNI templates (distillium)"
    echo "  3) Nothing Sni templates (prettyleaf)"
    echo "  0) Пропустить (минимальная страница)"
    read -r -p "Выбор (0–3) [1]: " TPL_CHOICE </dev/tty
    TPL_CHOICE="${TPL_CHOICE:-1}"
    case "$TPL_CHOICE" in
        0) echo "<!DOCTYPE html><html><head><meta charset=utf-8><title>Site</title></head><body><p>Welcome.</p></body></html>" > /var/www/html/index.html; echo "  Установлена минимальная страница."; return 0 ;;
        1) TPL_URL="https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"; TPL_DIR="simple-web-templates-main" ;;
        2) TPL_URL="https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"; TPL_DIR="sni-templates-main" ;;
        3) TPL_URL="https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"; TPL_DIR="nothing-sni-main" ;;
        *) TPL_URL="https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"; TPL_DIR="simple-web-templates-main" ;;
    esac
    echo "  Загрузка шаблона..."
    cd /opt || { echo "  Ошибка: /opt недоступен"; return 1; }
    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main 2>/dev/null
    for i in 1 2 3; do
        wget -q --timeout=30 -O main.zip "$TPL_URL" && break
        echo "  Повтор загрузки ($i/3)..."
        sleep 3
    done
    if [ ! -f main.zip ] || [ ! -s main.zip ]; then
        echo -e "  ${YELLOW}Не удалось загрузить шаблон. Создана минимальная страница.${NC}"
        echo "<!DOCTYPE html><html><head><meta charset=utf-8><title>Site</title></head><body><p>Welcome.</p></body></html>" > /var/www/html/index.html
        rm -f main.zip
        return 0
    fi
    unzip -o -q main.zip 2>/dev/null || { echo "  Ошибка распаковки"; rm -f main.zip; return 1; }
    rm -f main.zip
    if [ "$TPL_CHOICE" = "3" ]; then
        N=$((RANDOM % 8 + 1))
        [ -f "$TPL_DIR/$N.html" ] && cp "$TPL_DIR/$N.html" /var/www/html/index.html || cp "$TPL_DIR/"*.html /var/www/html/ 2>/dev/null || true
    else
        if [ -d "$TPL_DIR" ]; then
            if [ "$TPL_CHOICE" = "1" ]; then
                rm -rf "$TPL_DIR/assets" "$TPL_DIR/.gitattributes" "$TPL_DIR/README.md" "$TPL_DIR/_config.yml" 2>/dev/null
            elif [ "$TPL_CHOICE" = "2" ]; then
                rm -rf "$TPL_DIR/assets" "$TPL_DIR/README.md" "$TPL_DIR/index.html" 2>/dev/null
            fi
            SUBDIR=$(find "./$TPL_DIR" -maxdepth 1 -type d ! -path "./$TPL_DIR" | shuf -n 1 | sed 's|.*/||')
            if [ -n "$SUBDIR" ] && [ -d "$TPL_DIR/$SUBDIR" ]; then
                rm -rf /var/www/html/*
                cp -a "$TPL_DIR/$SUBDIR"/. /var/www/html/
            else
                rm -rf /var/www/html/*
                cp -a "$TPL_DIR"/. /var/www/html/ 2>/dev/null || true
            fi
        fi
    fi
    if [ ! -f /var/www/html/index.html ] && [ -n "$(ls -A /var/www/html 2>/dev/null)" ]; then
        FIRST_HTML=$(find /var/www/html -maxdepth 2 -name "*.html" -type f | head -n 1)
        [ -n "$FIRST_HTML" ] && cp "$FIRST_HTML" /var/www/html/index.html
    fi
    if [ ! -f /var/www/html/index.html ]; then
        echo "<!DOCTYPE html><html><head><meta charset=utf-8><title>Site</title></head><body><p>Welcome.</p></body></html>" > /var/www/html/index.html
    fi
    chown -R www-data:www-data /var/www/html 2>/dev/null || true
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main 2>/dev/null
    echo -e "  ${GREEN}Заглушка установлена в /var/www/html${NC}"
}

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

    # Subscription Page (merge с основным compose). REMNAWAVE_PANEL_URL и REMNAWAVE_API_TOKEN из .env,
    # чтобы панель получала запросы через Nginx (X-Forwarded-Proto: https) и токен не перезаписывался пустым.
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
    ports:
      - "127.0.0.1:${SUB_PORT}:3010"
    networks:
      - remnawave-network
    depends_on:
      remnawave:
        condition: service_healthy
REMNAWAVESUB

    # REMNAWAVE_PANEL_URL: через HTTPS (Nginx) — иначе ProxyCheckMiddleware панели отклоняет запросы Subscription Page
    if [ -n "$PANEL_DOMAIN" ]; then
        panel_url="https://$PANEL_DOMAIN"
    else
        panel_url="http://remnawave:3000"
    fi
    if grep -q "^REMNAWAVE_PANEL_URL=" .env 2>/dev/null; then
        sed -i "s|^REMNAWAVE_PANEL_URL=.*|REMNAWAVE_PANEL_URL=$panel_url|" .env
    else
        echo "" >> .env
        echo "# Subscription Page: URL панели (HTTPS через Nginx обязателен для ProxyCheck)" >> .env
        echo "REMNAWAVE_PANEL_URL=$panel_url" >> .env
    fi

    # REMNAWAVE_API_TOKEN — обязательно для Subscription Page. Панель → Settings → API Tokens
    if grep -q "^REMNAWAVE_API_TOKEN=" .env 2>/dev/null; then
        :  # уже есть
    else
        echo "" >> .env
        echo "# Subscription Page: токен из Remnawave Panel → Settings → API Tokens" >> .env
        echo "REMNAWAVE_API_TOKEN=" >> .env
    fi

    # Панель + нода: фиксированная подсеть для доступа панели к ноде (172.30.0.1 = host)
    if [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && [ -n "$SELFSTEAL_DOMAIN" ]; then
        if ! grep -q "subnet: 172.30" docker-compose-prod.yml 2>/dev/null; then
            python3 << 'PYEOF'
with open('docker-compose-prod.yml') as f:
    content = f.read()
# Вставить ipam после блока remnawave-network driver: bridge
if "ipam:" not in content and "remnawave-network" in content:
    old = "remnawave-network:\n    name: remnawave-network\n    driver: bridge\n    external: false"
    new = "remnawave-network:\n    name: remnawave-network\n    driver: bridge\n    ipam:\n      config:\n        - subnet: 172.30.0.0/16\n    external: false"
    if old in content:
        content = content.replace(old, new, 1)
    else:
        # Альтернативный отступ (пробелы)
        old2 = "remnawave-network:\n name: remnawave-network\n driver: bridge\n external: false"
        new2 = "remnawave-network:\n name: remnawave-network\n driver: bridge\n ipam:\n   config:\n     - subnet: 172.30.0.0/16\n external: false"
        content = content.replace(old2, new2, 1) if old2 in content else content
    with open('docker-compose-prod.yml', 'w') as f:
        f.write(content)
PYEOF
        fi
    fi

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
    # SelfSteal: отдельный домен только для заглушки (не проксируем на панель)
    if [ -n "$SELFSTEAL_DOMAIN" ]; then
        mkdir -p /var/www/html
        cat > /etc/nginx/sites-available/remnawave-selfsteal << NGINXSELFSTEALEOF
server {
    listen 80;
    server_name $SELFSTEAL_DOMAIN;
    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    location / { try_files \$uri \$uri/ =404; }
}
NGINXSELFSTEALEOF
        ln -sf /etc/nginx/sites-available/remnawave-selfsteal /etc/nginx/sites-enabled/ 2>/dev/null || true
        [ -n "$CERTBOT_EMAIL" ] && certbot --nginx -d "$SELFSTEAL_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" || true
        echo "  SelfSteal (заглушка): https://$SELFSTEAL_DOMAIN"
        install_selfsteal_template
    fi
    nginx -t && systemctl reload nginx || true

    # ---------- Панель + нода: панель по обычному HTTPS (443), нода Reality на 8443 ----------
    if [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && [ -n "$SELFSTEAL_DOMAIN" ]; then
        if [ -z "$PANEL_DOMAIN" ] || [ -z "$SUB_DOMAIN" ]; then
            echo -e "${YELLOW}  Для режима «Панель и нода» нужны домены панели и подписки. Нода не установлена.${NC}"
        else
        echo ""
        echo -e "${CYAN}[Remnawave] Установка ноды (Xray) на порту 8443. Панель остаётся на 443 (обычный HTTPS).${NC}"

        # Host nginx для panel/sub/selfsteal НЕ убираем — панель доступна по https://PANEL_DOMAIN в браузере
        # Cookie для входа по секретной ссылке
        COOKIES_R1=$(openssl rand -hex 4)
        COOKIES_R2=$(openssl rand -hex 4)
        mkdir -p /etc/nginx/conf.d
        cat > /etc/nginx/conf.d/remnawave-panel-cookie.conf << NGINXMAPEOF
map \$http_cookie \$auth_cookie {
    default 0;
    "~*${COOKIES_R1}=${COOKIES_R2}" 1;
}
map \$arg_${COOKIES_R1} \$auth_query {
    default 0;
    "${COOKIES_R2}" 1;
}
map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}
map \$arg_${COOKIES_R1} \$set_cookie_header {
    "${COOKIES_R2}" "${COOKIES_R1}=${COOKIES_R2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}
NGINXMAPEOF
        PANEL_CERT_DOMAIN="${PANEL_DOMAIN}"
        [ -z "$PANEL_DOMAIN" ] && PANEL_CERT_DOMAIN="panel.local"
        # Обновить конфиг панели: cookie-доступ + SSL (certbot уже мог добавить listen 443)
        cat > /etc/nginx/sites-available/remnawave-panel << NGINXPANELEOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $PANEL_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$PANEL_CERT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_CERT_DOMAIN/privkey.pem;
    add_header Set-Cookie \$set_cookie_header;
    location / {
        if (\$authorized = 0) { return 302 https://\$host/auth/login?${COOKIES_R1}=${COOKIES_R2}; }
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
        nginx -t && systemctl reload nginx || true

        # docker-compose-node.yml: только remnanode (без nginx на сокете)
        cat > "$REMNAWAVE_DIR/docker-compose-node.yml" << COMPOSENODEEOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    network_mode: host
    restart: always
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=REPLACE_PUBLIC_KEY_FROM_PANEL
COMPOSENODEEOF

        # Дождаться готовности API панели через Nginx (HTTPS), иначе ProxyCheckMiddleware даёт Empty reply
        echo "  Ожидание API панели..."
        domain_url="https://$PANEL_DOMAIN"
        api_ready=""
        attempt=1
        while [ "$attempt" -le 20 ]; do
            if curl -k -s -f --max-time 5 "$domain_url/api/auth/status" >/dev/null 2>&1; then
                api_ready=1
                break
            fi
            [ "$attempt" -eq 20 ] && echo -e "${RED}  API панели недоступен после 20 попыток. Настройте ноду вручную.${NC}"
            sleep 10
            attempt=$((attempt + 1))
        done

        # Регистрация и настройка через API (как в remnawave-reverse-proxy). Не выходить при сбое curl (set -e).
        SUPERADMIN_USER=$(openssl rand -hex 4)
        SUPERADMIN_PASS=$(openssl rand -hex 12)
        api_register() {
            curl -k -s --connect-timeout 5 --max-time 15 -X POST "$domain_url/api/auth/register" \
                -H "Content-Type: application/json" \
                -d "{\"username\":\"$SUPERADMIN_USER\",\"password\":\"$SUPERADMIN_PASS\"}"
        }
        resp=""
        if [ -n "$api_ready" ]; then
            resp=$(api_register) || true
        fi
        token=""
        if echo "$resp" | jq -e '.response.accessToken' >/dev/null 2>&1; then
            token=$(echo "$resp" | jq -r '.response.accessToken')
        elif echo "$resp" | jq -e '.accessToken' >/dev/null 2>&1; then
            token=$(echo "$resp" | jq -r '.accessToken')
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            echo -e "${YELLOW}  Регистрация через API не удалась (возможно, первый пользователь уже создан).${NC}"
            echo -e "  Создайте ноду вручную в панели и добавьте SECRET_KEY в $REMNAWAVE_DIR/docker-compose-node.yml"
        else
            echo "  Регистрация в панели выполнена."

            # Публичный ключ для ноды
            pubkey_resp=$(curl -k -s --connect-timeout 5 --max-time 15 -H "Authorization: Bearer $token" "$domain_url/api/keygen") || true
            PUBLIC_KEY=$(echo "$pubkey_resp" | jq -r '.response.pubKey // .pubKey // empty')
            if [ -z "$PUBLIC_KEY" ]; then
                echo -e "${YELLOW}  Не удалось получить публичный ключ. Ноду нужно настроить вручную.${NC}"
            else
                sed -i "s|SECRET_KEY=REPLACE_PUBLIC_KEY_FROM_PANEL|SECRET_KEY=$PUBLIC_KEY|" "$REMNAWAVE_DIR/docker-compose-node.yml"

                # x25519 ключи и конфиг-профиль
                keys_resp=$(curl -k -s --connect-timeout 5 --max-time 15 -H "Authorization: Bearer $token" "$domain_url/api/system/tools/x25519/generate") || true
                PRIVATE_KEY=$(echo "$keys_resp" | jq -r '.response.keypairs[0].privateKey // empty')
                if [ -z "$PRIVATE_KEY" ]; then
                    echo -e "${YELLOW}  Не удалось сгенерировать x25519. Профиль создайте в панели.${NC}"
                else
                    # Удалить дефолтный профиль (если есть)
                    profiles=$(curl -k -s --connect-timeout 5 --max-time 15 -H "Authorization: Bearer $token" "$domain_url/api/config-profiles") || true
                    def_uuid=$(echo "$profiles" | jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid' 2>/dev/null)
                    [ -n "$def_uuid" ] && curl -k -s -X DELETE -H "Authorization: Bearer $token" "$domain_url/api/config-profiles/$def_uuid" >/dev/null || true

                    SHORT_ID=$(openssl rand -hex 8)
                    # Reality на 8443, dest — облако для маскировки (панель на 443 через host nginx)
                    create_profile=$(curl -k -s --connect-timeout 5 --max-time 30 -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
                        "$domain_url/api/config-profiles" \
                        -d "{
                          \"name\": \"StealConfig\",
                          \"config\": {
                            \"log\": {\"loglevel\": \"warning\"},
                            \"inbounds\": [{
                              \"tag\": \"Steal\",
                              \"port\": 8443,
                              \"protocol\": \"vless\",
                              \"settings\": {\"clients\": [], \"decryption\": \"none\"},
                              \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"]},
                              \"streamSettings\": {
                                \"network\": \"tcp\",
                                \"security\": \"reality\",
                                \"realitySettings\": {
                                  \"show\": false,
                                  \"xver\": 1,
                                  \"dest\": \"www.cloudflare.com:443\",
                                  \"serverNames\": [\"www.cloudflare.com\"],
                                  \"privateKey\": \"$PRIVATE_KEY\",
                                  \"shortIds\": [\"$SHORT_ID\"]
                                }
                              }
                            }],
                            \"outbounds\": [
                              {\"tag\": \"DIRECT\", \"protocol\": \"freedom\"},
                              {\"tag\": \"BLOCK\", \"protocol\": \"blackhole\"}
                            ],
                            \"routing\": {
                              \"rules\": [
                                {\"ip\": [\"geoip:private\"], \"type\": \"field\", \"outboundTag\": \"BLOCK\"},
                                {\"type\": \"field\", \"protocol\": [\"bittorrent\"], \"outboundTag\": \"BLOCK\"}
                              ]
                            }
                          }
                        }") || true
                    config_uuid=$(echo "$create_profile" | jq -r '.response.uuid // empty')
                    inbound_uuid=$(echo "$create_profile" | jq -r '.response.inbounds[0].uuid // empty')
                    if [ -z "$config_uuid" ] || [ -z "$inbound_uuid" ]; then
                        echo -e "${YELLOW}  Создание конфиг-профиля не удалось. Создайте в панели вручную.${NC}"
                    else
                        # Нода в панели (адрес 172.30.0.1 — host с точки зрения docker-сети)
                        node_payload="{\"name\":\"Node1\",\"address\":\"172.30.0.1\",\"port\":2222,\"configProfile\":{\"activeConfigProfileUuid\":\"$config_uuid\",\"activeInbounds\":[\"$inbound_uuid\"]},\"isTrafficTrackingActive\":false,\"trafficLimitBytes\":0,\"notifyPercent\":0,\"trafficResetDay\":31,\"excludedInbounds\":[],\"countryCode\":\"XX\",\"consumptionMultiplier\":1.0}"
                        curl -k -s -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/nodes" -d "$node_payload" >/dev/null || true

                        # Host для подписок: порт 8443, SNI cloudflare
                        host_payload="{\"inbound\":{\"configProfileUuid\":\"$config_uuid\",\"configProfileInboundUuid\":\"$inbound_uuid\"},\"remark\":\"Steal\",\"address\":\"$SELFSTEAL_DOMAIN\",\"port\":8443,\"path\":\"\",\"sni\":\"www.cloudflare.com\",\"host\":\"\",\"fingerprint\":\"chrome\",\"allowInsecure\":false,\"isDisabled\":false,\"securityLayer\":\"DEFAULT\"}"
                        curl -k -s -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/hosts" -d "$host_payload" >/dev/null || true

                        # Internal Squad — привязать inbound
                        squads=$(curl -k -s --connect-timeout 5 --max-time 15 -H "Authorization: Bearer $token" "$domain_url/api/internal-squads") || true
                        squad_uuid=$(echo "$squads" | jq -r '.response.internalSquads[0].uuid // empty' 2>/dev/null)
                        if [ -n "$squad_uuid" ]; then
                            update_squad=$(curl -k -s -X PATCH -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/internal-squads" \
                                -d "{\"uuid\":\"$squad_uuid\",\"inbounds\":[\"$inbound_uuid\"]}") || true
                        fi

                        # API-токен для Subscription Page
                        tok_resp=$(curl -k -s --connect-timeout 5 --max-time 15 -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/tokens" -d '{"tokenName":"subscription-page"}') || true
                        api_tok=$(echo "$tok_resp" | jq -r '.response.token // empty')
                        if [ -n "$api_tok" ]; then
                            sed -i "s|^REMNAWAVE_API_TOKEN=.*|REMNAWAVE_API_TOKEN=$api_tok|" "$REMNAWAVE_DIR/.env"
                        fi
                        echo -e "  ${GREEN}Конфиг-профиль, нода и host созданы в панели.${NC}"
                    fi
                fi
            fi
        fi

        # Запуск только remnanode (панель уже на host nginx 443)
        cd "$REMNAWAVE_DIR"
        $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml -f docker-compose-sub.yml -f docker-compose-node.yml up -d remnanode
        docker restart remnawave-subscription-page 2>/dev/null || true

        echo ""
        echo -e "${GREEN}  Нода (remnanode) запущена на порту 8443. Панель по обычному HTTPS: https://${PANEL_DOMAIN}${NC}"
        echo -e "  Ссылка с секретом и учётные данные — в конце установки."
        echo ""
        fi
    fi

    # Обновить .env бота (если ещё не создан, будет ниже)
    # API панели — через HTTPS (Nginx), иначе ProxyCheckMiddleware отклоняет запросы
    if [ -n "$PANEL_DOMAIN" ]; then
        REMNAWAVE_API_URL="https://$PANEL_DOMAIN"
    else
        REMNAWAVE_API_URL="http://127.0.0.1:$PANEL_PORT"
    fi
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
    [ -n "$NEED_WEBHOOK_8443" ] && WEBHOOK_URL="https://$WEBHOOK_DOMAIN:8443" || WEBHOOK_URL="https://$WEBHOOK_DOMAIN"
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
# Если установлена нода, 443 занят Xray — перевести webhook на 8443 (если ещё не сделано в блоке Remnawave)
if [ -n "$NEED_WEBHOOK_8443" ] && [ -f /etc/nginx/sites-available/vpn-bot ] && grep -q "listen 443" /etc/nginx/sites-available/vpn-bot 2>/dev/null; then
    sed -i 's/listen 443 ssl;/listen 8443 ssl;/' /etc/nginx/sites-available/vpn-bot
    sed -i 's/listen \[::\]:443 ssl;/listen [::]:8443 ssl;/' /etc/nginx/sites-available/vpn-bot
    nginx -t && systemctl reload nginx
    echo "  Webhook (443 занят Xray): порт 8443, WEBHOOK_BASE_URL=https://$WEBHOOK_DOMAIN:8443"
fi

# Открытие портов (UFW): все нужные для работы
echo ""
echo "[UFW] Открытие портов..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
    ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
    ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
    if [ "$REMNAWAVE_NODE_INSTALL" = "true" ]; then
        ufw allow 8443/tcp comment 'Reality/VLESS' 2>/dev/null || true
        ufw allow from 172.30.0.0/16 to any port 2222 proto tcp comment 'Remnawave panel->node' 2>/dev/null || true
    fi
    ufw reload 2>/dev/null || true
    echo -e "  ${GREEN}UFW: порты 22, 80, 443 открыты.${NC}"
    [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && echo -e "  ${GREEN}  + 8443 (Reality), 2222 (из 172.30.0.0/16). Проверка: sudo ufw status${NC}"
else
    echo -e "  ${YELLOW}UFW не установлен. Откройте порты вручную (iptables или панель хостинга):${NC}"
    echo -e "  ${YELLOW}  22/tcp (SSH), 80/tcp (HTTP), 443/tcp (HTTPS)${NC}"
    [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && echo -e "  ${YELLOW}  8443/tcp (Reality), 2222/tcp (доступ с 172.30.0.0/16 — панель->нода)${NC}"
fi
echo ""

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

# Разрешить vpnbot перезапускать сервис без пароля (для кнопки в админ-панели)
echo "$BOT_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $SERVICE_NAME" > /etc/sudoers.d/vpn-bot-restart
chmod 440 /etc/sudoers.d/vpn-bot-restart

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
if [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && [ -n "$PANEL_DOMAIN" ] && [ -n "$COOKIES_R1" ] && [ -n "$COOKIES_R2" ]; then
echo -e "   Панель по ссылке с секретом (сохраните):"
echo -e "   ${YELLOW}https://${PANEL_DOMAIN}/auth/login?${COOKIES_R1}=${COOKIES_R2}${NC}"
if [ -n "$SUPERADMIN_USER" ] && [ -n "$SUPERADMIN_PASS" ]; then
echo -e "   Логин:  ${CYAN}${SUPERADMIN_USER}${NC}"
echo -e "   Пароль: ${CYAN}${SUPERADMIN_PASS}${NC}"
else
echo -e "   Логин и пароль — учётные данные, созданные при первом входе в панель."
fi
elif [ -n "$PANEL_DOMAIN" ]; then
echo -e "   Откройте в браузере: ${YELLOW}https://${PANEL_DOMAIN}${NC}"
else
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "   Откройте в браузере: ${YELLOW}http://${SERVER_IP:-IP}:${PANEL_PORT}${NC}"
fi
[ "$REMNAWAVE_NODE_INSTALL" != "true" ] && echo -e "   • Создайте учётную запись администратора (логин и пароль — запомните)"
[ -n "$SELFSTEAL_DOMAIN" ] && [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && echo -e "   • Нода и заглушка SelfSteal: ${YELLOW}$SELFSTEAL_DOMAIN${NC} (уже установлены скриптом)"
[ -n "$SELFSTEAL_DOMAIN" ] && [ "$REMNAWAVE_NODE_INSTALL" != "true" ] && echo -e "   • SelfSteal домен для ноды: ${YELLOW}$SELFSTEAL_DOMAIN${NC} (ноду настройте скриптом remnawave-reverse-proxy)"
echo -e "   • Создайте Internal Squad (группу подписок) и привяжите ноду, если ещё не сделано"
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
[ -n "$NEED_WEBHOOK_8443" ] && echo -e "   ${YELLOW}https://${WEBHOOK_DOMAIN}:8443/webhook/yookassa${NC}" || echo -e "   ${YELLOW}https://${WEBHOOK_DOMAIN}/webhook/yookassa${NC}"
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
