#!/bin/bash
# VPN Bot — единый скрипт полной установки (бот + Remnawave Panel)
# Использование: curl -sSL .../install.sh | sudo bash  или: sudo ./install.sh
# Режим выбирается автоматически: если проект уже установлен — обновление, иначе — чистая установка.
# Явно: sudo ./install.sh update  или  sudo ./install.sh install
# Автоматизация: WEBHOOK_DOMAIN=bot.example.com CERTBOT_EMAIL=admin@example.com sudo ./install.sh
# С панелью: PANEL_DOMAIN=panel.example.com SUB_DOMAIN=sub.domain.com (опционально)
# Режим Remnawave (как remnawave-reverse-proxy): REMNAWAVE_PANEL_INSTALL=true|false, REMNAWAVE_NODE_INSTALL=true, REMNAWAVE_ADD_NODE=true
# Данные: PANEL_DOMAIN, SUB_DOMAIN, SELFSTEAL_DOMAIN; для автоматизации ноды/токена: REMNAWAVE_ADMIN_USER, REMNAWAVE_ADMIN_PASS

set -e
# Ошибки и вывод команд установки показываются в консоли (без -qq и скрытия stderr)

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Безопасный read: при curl | bash /dev/tty может отсутствовать
read_prompt() {
  local silent=""
  [ "$1" = "-s" ] && { silent="-s"; shift; }
  if [ -c /dev/tty ] 2>/dev/null; then
    read -r $silent -p "$1" "$2" </dev/tty
  else
    read -r $silent -p "$1" "$2" 2>/dev/null || eval "$2=\"\""
  fi
}

REPO_URL="${VPN_BOT_REPO:-https://github.com/TheNotus/vlessbot.git}"
REPO_BRANCH="${VPN_BOT_BRANCH:-main}"
# Remnawave: выбор пользователя (1–4) или переменные REMNAWAVE_PANEL_INSTALL=true|false, REMNAWAVE_NODE_INSTALL=true|false
REMNAWAVE_PANEL_INSTALL="${REMNAWAVE_PANEL_INSTALL:-}"
REMNAWAVE_NODE_INSTALL="${REMNAWAVE_NODE_INSTALL:-false}"
REMNAWAVE_ADD_NODE="${REMNAWAVE_ADD_NODE:-false}"
SELFSTEAL_DOMAIN="${SELFSTEAL_DOMAIN:-}"
NODE_MANUAL_SETUP_NEEDED=""
REGISTRATION_SUCCEEDED=""

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

    # При заданных REMNAWAVE_ADMIN_USER и REMNAWAVE_ADMIN_PASS — создать API-токен и при необходимости подставить SECRET_KEY ноды (без повторной полной установки)
    if [ -n "${REMNAWAVE_ADMIN_USER:-}" ] && [ -n "${REMNAWAVE_ADMIN_PASS:-}" ] && [ -f "$REMNAWAVE_DIR/.env" ]; then
        PANEL_DOMAIN_UPDATE=$(grep -E "^FRONT_END_DOMAIN=" "$REMNAWAVE_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | head -1)
        if [ -n "$PANEL_DOMAIN_UPDATE" ] && [ "$PANEL_DOMAIN_UPDATE" != "*" ]; then
            domain_url="http://127.0.0.1:9080"
            api_host_header="Host: $PANEL_DOMAIN_UPDATE"
            if curl -s -f --max-time 5 -H "$api_host_header" "$domain_url/api/auth/status" >/dev/null 2>&1; then
                login_resp=$(curl -s --connect-timeout 5 --max-time 15 -X POST "$domain_url/api/auth/login" \
                    -H "$api_host_header" -H "Content-Type: application/json" \
                    -d "{\"username\":\"$REMNAWAVE_ADMIN_USER\",\"password\":\"$REMNAWAVE_ADMIN_PASS\"}") || true
                token=""
                if echo "$login_resp" | jq -e '.accessToken' >/dev/null 2>&1; then token=$(echo "$login_resp" | jq -r '.accessToken'); fi
                if [ -z "$token" ] && echo "$login_resp" | jq -e '.response.accessToken' >/dev/null 2>&1; then token=$(echo "$login_resp" | jq -r '.response.accessToken'); fi
                if [ -n "$token" ]; then
                    echo "  Вход в панель выполнен, создаём API-токен и при необходимости обновляем ноду..."
                    tok_resp=$(curl -s --connect-timeout 5 --max-time 15 -X POST -H "$api_host_header" -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/tokens" -d '{"tokenName":"subscription-page"}') || true
                    api_tok=$(echo "$tok_resp" | jq -r '.response.token // empty')
                    if [ -n "$api_tok" ]; then
                        grep -q "^REMNAWAVE_API_TOKEN=" "$REMNAWAVE_DIR/.env" 2>/dev/null && sed -i "s|^REMNAWAVE_API_TOKEN=.*|REMNAWAVE_API_TOKEN=$api_tok|" "$REMNAWAVE_DIR/.env" || echo "REMNAWAVE_API_TOKEN=$api_tok" >> "$REMNAWAVE_DIR/.env"
                        echo "  REMNAWAVE_API_TOKEN записан в $REMNAWAVE_DIR/.env"
                    fi
                    if [ -f "$REMNAWAVE_DIR/docker-compose-node.yml" ] && grep -q "REPLACE_PUBLIC_KEY_FROM_PANEL" "$REMNAWAVE_DIR/docker-compose-node.yml" 2>/dev/null; then
                        pubkey_resp=$(curl -s --connect-timeout 5 --max-time 15 -H "$api_host_header" -H "Authorization: Bearer $token" "$domain_url/api/keygen") || true
                        PUBLIC_KEY=$(echo "$pubkey_resp" | jq -r '.response.pubKey // .pubKey // empty')
                        if [ -n "$PUBLIC_KEY" ]; then
                            sed -i "s|SECRET_KEY=REPLACE_PUBLIC_KEY_FROM_PANEL|SECRET_KEY=$PUBLIC_KEY|" "$REMNAWAVE_DIR/docker-compose-node.yml"
                            echo "  SECRET_KEY ноды подставлен в docker-compose-node.yml"
                        fi
                    fi
                    DOCKER_COMPOSE_UPDATE="docker compose"
                    docker compose version &>/dev/null || DOCKER_COMPOSE_UPDATE="docker-compose"
                    (cd "$REMNAWAVE_DIR" 2>/dev/null && $DOCKER_COMPOSE_UPDATE -f docker-compose-prod.yml -f docker-compose-sub.yml -f docker-compose-node.yml up -d remnanode) 2>/dev/null || true
                    docker restart remnawave-subscription-page 2>/dev/null || true
                fi
            fi
        fi
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

# Выбор Remnawave — как в remnawave-reverse-proxy (Install Remnawave Components)
if [ -z "$REMNAWAVE_PANEL_INSTALL" ] && [ -z "$REMNAWAVE_ADD_NODE" ]; then
    echo -e "${CYAN}Установка компонентов Remnawave (как в remnawave-reverse-proxy):${NC}"
    echo "  1) Нет — только VPN Bot"
    echo "  2) Панель и нода на одном сервере (панель + Xray-нода + заглушка SelfSteal)"
    echo "  3) Только панель Remnawave"
    echo "  4) Добавить ноду в панель (запускать на сервере с уже установленной панелью)"
    echo "  5) Только нода Remnawave (на другом сервере; рекомендуется скрипт remnawave-reverse-proxy)"
    read_prompt "Выбор (1–5) [1]: " REMNAWAVE_CHOICE
    REMNAWAVE_CHOICE="${REMNAWAVE_CHOICE:-1}"
    case "$REMNAWAVE_CHOICE" in
        2) REMNAWAVE_PANEL_INSTALL=true; REMNAWAVE_NODE_INSTALL=true; REMNAWAVE_ADD_NODE=false ;;
        3) REMNAWAVE_PANEL_INSTALL=true; REMNAWAVE_NODE_INSTALL=false; REMNAWAVE_ADD_NODE=false ;;
        4) REMNAWAVE_PANEL_INSTALL=false; REMNAWAVE_NODE_INSTALL=false; REMNAWAVE_ADD_NODE=true ;;
        5) REMNAWAVE_PANEL_INSTALL=false; REMNAWAVE_NODE_INSTALL=true; REMNAWAVE_ADD_NODE=false ;;
        *) REMNAWAVE_PANEL_INSTALL=false; REMNAWAVE_NODE_INSTALL=false; REMNAWAVE_ADD_NODE=false ;;
    esac
    echo ""
fi

# Режим «только нода» (5) — предлагаем скрипт remnawave-reverse-proxy или продолжить установку бота
if [ "$REMNAWAVE_NODE_INSTALL" = "true" ] && [ "$REMNAWAVE_PANEL_INSTALL" != "true" ]; then
    echo -e "${YELLOW}Режим «Только нода»: установка только Xray-ноды Remnawave (SelfSteal).${NC}"
    RR_SCRIPT=""
    [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/remnawave-reverse-proxy-main/install_remnawave.sh" ] && RR_SCRIPT="${SCRIPT_DIR}/remnawave-reverse-proxy-main/install_remnawave.sh"
    if [ -n "$RR_SCRIPT" ]; then
        echo "В этом репозитории есть скрипт remnawave-reverse-proxy (панель/нода/сертификаты)."
        read_prompt "Запустить его сейчас? (y/N): " RUN_RR
        if [ "${RUN_RR:-n}" = "y" ] || [ "${RUN_RR:-n}" = "Y" ]; then
            exec bash "$RR_SCRIPT"
        fi
    fi
    echo "Рекомендуется: bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)"
    echo "  В меню выберите «Установка компонентов Remnawave» → «Установить только ноду»."
    read_prompt "Всё равно установить VPN Bot на этот сервер? (y/N): " INSTALL_BOT_ANYWAY
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
        read_prompt "SelfSteal домен (Enter — пропустить): " SELFSTEAL_DOMAIN
    fi
    echo ""
fi

# Запрос доменов (если не заданы переменными)
# </dev/tty — чтобы read работал при curl | bash (stdin иначе занят pipe)
if [ -z "$WEBHOOK_DOMAIN" ] || [ "$WEBHOOK_DOMAIN" = "bot.example.com" ]; then
    echo -e "${CYAN}Введите домен для webhook бота (например bot.example.com):${NC}"
    echo -e "  DNS должен указывать на IP этого сервера."
    read_prompt "Домен: " WEBHOOK_DOMAIN
    WEBHOOK_DOMAIN="${WEBHOOK_DOMAIN:-bot.example.com}"
    if [ "$WEBHOOK_DOMAIN" = "bot.example.com" ]; then
        echo -e "  ${YELLOW}Используется bot.example.com — замените вручную в nginx и .env${NC}"
    fi
fi
if [ -z "$CERTBOT_EMAIL" ]; then
    read_prompt "Email для SSL (Let's Encrypt) или Enter чтобы пропустить: " CERTBOT_EMAIL
fi
if [ -z "$PANEL_DOMAIN" ] && [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
    read_prompt "Домен для Remnawave Panel (Enter — только по IP): " PANEL_DOMAIN
fi
if [ -z "$SUB_DOMAIN" ] && [ "$REMNAWAVE_PANEL_INSTALL" = "true" ]; then
    read_prompt "Домен для Subscription Page (Enter — только по IP): " SUB_DOMAIN
fi
# Данные для «Добавить ноду в панель» (как в remnawave-reverse-proxy)
if [ "$REMNAWAVE_ADD_NODE" = "true" ]; then
    if [ ! -f "$REMNAWAVE_DIR/.env" ]; then
        echo -e "${RED}Панель Remnawave не найдена ($REMNAWAVE_DIR/.env). Запускайте этот пункт на сервере с установленной панелью.${NC}"
        exit 1
    fi
    PANEL_DOMAIN="${PANEL_DOMAIN:-$(grep -E '^FRONT_END_DOMAIN=' "$REMNAWAVE_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | head -1)}"
    [ -z "$PANEL_DOMAIN" ] && read_prompt "Домен панели (как в панели): " PANEL_DOMAIN
    [ -z "${REMNAWAVE_ADMIN_USER:-}" ] && read_prompt "Логин панели: " REMNAWAVE_ADMIN_USER
    [ -z "${REMNAWAVE_ADMIN_PASS:-}" ] && read_prompt -s "Пароль панели: " REMNAWAVE_ADMIN_PASS
    echo ""
    while true; do
        read_prompt "Имя ноды (латиница, цифры, дефис, 3–20 символов): " NODE_NAME
        NODE_NAME="${NODE_NAME:-}"
        if [[ "$NODE_NAME" =~ ^[a-zA-Z0-9-]+$ ]] && [ "${#NODE_NAME}" -ge 3 ] && [ "${#NODE_NAME}" -le 20 ]; then break; fi
        echo -e "  ${YELLOW}Некорректное имя.${NC}"
    done
    read_prompt "SelfSteal домен для ноды (например node.example.com): " SELFSTEAL_DOMAIN
    echo ""
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

# «Добавить ноду в панель» — API как в remnawave-reverse-proxy (логин, конфиг-профиль, нода, host, squad)
if [ "$REMNAWAVE_ADD_NODE" = "true" ]; then
    echo "[2a/10] Добавление ноды в панель Remnawave..."
    ADD_NODE_API="http://127.0.0.1:${REMNAWAVE_API_PROXY_PORT:-9080}"
    ADD_NODE_HOST="${PANEL_DOMAIN:-localhost}"
    if ! curl -s -f --max-time 5 -H "Host: $ADD_NODE_HOST" "$ADD_NODE_API/api/auth/status" >/dev/null 2>&1; then
        echo -e "${YELLOW}  API панели недоступен (127.0.0.1:9080). Убедитесь, что панель запущена и прокси настроен.${NC}"
    else
        login_resp=$(curl -s --connect-timeout 10 --max-time 20 -X POST "$ADD_NODE_API/api/auth/login" \
            -H "Host: $ADD_NODE_HOST" -H "Content-Type: application/json" \
            -d "{\"username\":\"$REMNAWAVE_ADMIN_USER\",\"password\":\"$REMNAWAVE_ADMIN_PASS\"}") || true
        ADD_TOKEN=""
        echo "$login_resp" | jq -e '.accessToken' >/dev/null 2>&1 && ADD_TOKEN=$(echo "$login_resp" | jq -r '.accessToken')
        echo "$login_resp" | jq -e '.response.accessToken' >/dev/null 2>&1 && ADD_TOKEN=$(echo "$login_resp" | jq -r '.response.accessToken')
        if [ -z "$ADD_TOKEN" ] || [ "$ADD_TOKEN" = "null" ]; then
            echo -e "${RED}  Не удалось войти в панель. Проверьте логин и пароль.${NC}"
        else
            nodes_resp=$(curl -s --connect-timeout 5 --max-time 15 -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" "$ADD_NODE_API/api/nodes") || true
            if echo "$nodes_resp" | jq -e --arg d "$SELFSTEAL_DOMAIN" '.response[]? | select(.address == $d)' >/dev/null 2>&1; then
                echo -e "${YELLOW}  Домен ноды уже есть в панели: $SELFSTEAL_DOMAIN. Выберите другой домен.${NC}"
            else
                keys_resp=$(curl -s --connect-timeout 10 --max-time 20 -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" "$ADD_NODE_API/api/system/tools/x25519/generate") || true
                PRIVATE_KEY=$(echo "$keys_resp" | jq -r '.response.keypairs[0].privateKey // empty')
                if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "null" ]; then
                    echo -e "${RED}  Не удалось сгенерировать x25519 ключи.${NC}"
                else
                    SHORT_ID=$(openssl rand -hex 8)
                    PROFILE_BODY=$(jq -n --arg name "$NODE_NAME" --arg domain "$SELFSTEAL_DOMAIN" --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg tag "$NODE_NAME" '{
                        name: $name,
                        config: {
                            log: { loglevel: "warning" },
                            dns: { queryStrategy: "UseIPv4", servers: [{ address: "https://dns.google/dns-query", skipFallback: false }] },
                            inbounds: [{
                                tag: $tag,
                                port: 443,
                                protocol: "vless",
                                settings: { clients: [], decryption: "none" },
                                sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
                                streamSettings: {
                                    network: "tcp",
                                    security: "reality",
                                    realitySettings: {
                                        show: false, xver: 1, dest: "/dev/shm/nginx.sock", spiderX: "", shortIds: [$sid],
                                        privateKey: $pk, serverNames: [$domain]
                                    }
                                }
                            }],
                            outbounds: [{ tag: "DIRECT", protocol: "freedom" }, { tag: "BLOCK", protocol: "blackhole" }],
                            routing: { rules: [
                                { ip: ["geoip:private"], type: "field", outboundTag: "BLOCK" },
                                { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
                            ]}
                        }
                    }')
                    profile_resp=$(curl -s --connect-timeout 10 --max-time 25 -X POST -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" -H "Content-Type: application/json" "$ADD_NODE_API/api/config-profiles" -d "$PROFILE_BODY") || true
                    config_uuid=$(echo "$profile_resp" | jq -r '.response.uuid // empty')
                    inbound_uuid=$(echo "$profile_resp" | jq -r '.response.inbounds[0].uuid // empty')
                    if [ -z "$config_uuid" ] || [ -z "$inbound_uuid" ]; then
                        echo -e "${RED}  Не удалось создать конфиг-профиль. Имя «$NODE_NAME» может быть занято.${NC}"
                    else
                        node_payload=$(jq -n --arg name "$NODE_NAME" --arg addr "$SELFSTEAL_DOMAIN" --arg cu "$config_uuid" --arg iu "$inbound_uuid" '{
                            name: $name, address: $addr, port: 2222,
                            configProfile: { activeConfigProfileUuid: $cu, activeInbounds: [$iu] },
                            isTrafficTrackingActive: false, trafficLimitBytes: 0, notifyPercent: 0, trafficResetDay: 31,
                            excludedInbounds: [], countryCode: "XX", consumptionMultiplier: 1.0
                        }')
                        curl -s -X POST -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" -H "Content-Type: application/json" "$ADD_NODE_API/api/nodes" -d "$node_payload" >/dev/null || true
                        host_payload=$(jq -n --arg cu "$config_uuid" --arg iu "$inbound_uuid" --arg remark "$NODE_NAME" --arg addr "$SELFSTEAL_DOMAIN" '{
                            inbound: { configProfileUuid: $cu, configProfileInboundUuid: $iu },
                            remark: $remark, address: $addr, port: 443, path: "", sni: $addr, host: "", alpn: null,
                            fingerprint: "chrome", allowInsecure: false, isDisabled: false, securityLayer: "DEFAULT"
                        }')
                        curl -s -X POST -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" -H "Content-Type: application/json" "$ADD_NODE_API/api/hosts" -d "$host_payload" >/dev/null || true
                        squads=$(curl -s --connect-timeout 5 --max-time 15 -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" "$ADD_NODE_API/api/internal-squads") || true
                        squad_uuid=$(echo "$squads" | jq -r '.response.internalSquads[0].uuid // empty' 2>/dev/null)
                        if [ -n "$squad_uuid" ]; then
                            curl -s -X PATCH -H "Host: $ADD_NODE_HOST" -H "Authorization: Bearer $ADD_TOKEN" -H "Content-Type: application/json" "$ADD_NODE_API/api/internal-squads" -d "{\"uuid\":\"$squad_uuid\",\"inbounds\":[\"$inbound_uuid\"]}" >/dev/null || true
                        fi
                        echo -e "${GREEN}  Нода «$NODE_NAME» ($SELFSTEAL_DOMAIN) добавлена в панель.${NC}"
                        echo "  Для установки ноды на другом сервере: remnawave-reverse-proxy → «Установить только ноду» (укажите IP панели и ключ из панели)."
                    fi
                fi
            fi
        fi
    fi
    REMNAWAVE_ADD_NODE=false
    echo ""
fi

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
    read_prompt "Выбор (0–3) [1]: " TPL_CHOICE
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
    # Определить команду после установки Docker: docker compose (v2) или docker-compose (v1)
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null && docker-compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        DOCKER_COMPOSE_CMD="docker compose"
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

    # REMNAWAVE_PANEL_URL: внутренний URL панели (Subscription Page в той же Docker-сети) — без Nginx и cookie, без 502
    panel_url="http://remnawave:3000"
    if grep -q "^REMNAWAVE_PANEL_URL=" .env 2>/dev/null; then
        sed -i "s|^REMNAWAVE_PANEL_URL=.*|REMNAWAVE_PANEL_URL=$panel_url|" .env
    else
        echo "" >> .env
        echo "# Subscription Page: URL панели (внутри Docker — remnawave:3000)" >> .env
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

    # Локальный прокси для API панели (только 127.0.0.1): панель отдаёт ответ только при Host и X-Forwarded-Proto
    REMNAWAVE_API_PROXY_PORT="${REMNAWAVE_API_PROXY_PORT:-9080}"
    PANEL_API_HOST="${PANEL_DOMAIN:-localhost}"
    cat > /etc/nginx/sites-available/remnawave-panel-api-local << NGINXAPILOCALEOF
server {
    listen 127.0.0.1:${REMNAWAVE_API_PROXY_PORT};
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host ${PANEL_API_HOST};
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINXAPILOCALEOF
    ln -sf /etc/nginx/sites-available/remnawave-panel-api-local /etc/nginx/sites-enabled/ 2>/dev/null || true

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

        # API панели — через локальный прокси 9080 (без cookie), иначе запросы режутся
        domain_url="http://127.0.0.1:${REMNAWAVE_API_PROXY_PORT:-9080}"
        api_host_header="Host: $PANEL_DOMAIN"
        echo "  Ожидание API панели..."
        api_ready=""
        attempt=1
        while [ "$attempt" -le 20 ]; do
            if curl -s -f --max-time 5 -H "$api_host_header" "$domain_url/api/auth/status" >/dev/null 2>&1; then
                api_ready=1
                break
            fi
            if [ "$attempt" -eq 20 ]; then
                echo -e "${RED}  API панели недоступен после 20 попыток. Настройте ноду вручную (инструкция в конце установки).${NC}"
                NODE_MANUAL_SETUP_NEEDED="true"
            fi
            sleep 10
            attempt=$((attempt + 1))
        done

        # Регистрация или логин, затем создание ноды и API-токена
        SUPERADMIN_USER=$(openssl rand -hex 4)
        SUPERADMIN_PASS=$(openssl rand -hex 12)
        token=""
        if [ -n "$api_ready" ]; then
            api_register() {
                curl -s --connect-timeout 5 --max-time 15 -X POST "$domain_url/api/auth/register" \
                    -H "$api_host_header" -H "Content-Type: application/json" \
                    -d "{\"username\":\"$SUPERADMIN_USER\",\"password\":\"$SUPERADMIN_PASS\"}"
            }
            resp=$(api_register) || true
            if echo "$resp" | jq -e '.response.accessToken' >/dev/null 2>&1; then
                token=$(echo "$resp" | jq -r '.response.accessToken')
                REGISTRATION_SUCCEEDED="true"
            elif echo "$resp" | jq -e '.accessToken' >/dev/null 2>&1; then
                token=$(echo "$resp" | jq -r '.accessToken')
                REGISTRATION_SUCCEEDED="true"
            fi
        fi
        # Если регистрация не удалась — пробуем логин по REMNAWAVE_ADMIN_USER / REMNAWAVE_ADMIN_PASS
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            if [ -n "$api_ready" ] && [ -n "${REMNAWAVE_ADMIN_USER:-}" ] && [ -n "${REMNAWAVE_ADMIN_PASS:-}" ]; then
                echo "  Попытка входа по REMNAWAVE_ADMIN_USER..."
                login_resp=$(curl -s --connect-timeout 5 --max-time 15 -X POST "$domain_url/api/auth/login" \
                    -H "$api_host_header" -H "Content-Type: application/json" \
                    -d "{\"username\":\"$REMNAWAVE_ADMIN_USER\",\"password\":\"$REMNAWAVE_ADMIN_PASS\"}") || true
                if echo "$login_resp" | jq -e '.accessToken' >/dev/null 2>&1; then
                    token=$(echo "$login_resp" | jq -r '.accessToken')
                elif echo "$login_resp" | jq -e '.response.accessToken' >/dev/null 2>&1; then
                    token=$(echo "$login_resp" | jq -r '.response.accessToken')
                fi
                [ -n "$token" ] && echo "  Вход выполнен, создаём ноду и API-токен..."
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            echo -e "${YELLOW}  Регистрация через API не удалась (возможно, первый пользователь уже создан).${NC}"
            echo -e "  ${YELLOW}Задайте REMNAWAVE_ADMIN_USER и REMNAWAVE_ADMIN_PASS и запустите обновление (sudo ./install.sh), либо настройте ноду по инструкции в конце.${NC}"
            NODE_MANUAL_SETUP_NEEDED="true"
        else
            [ "$REGISTRATION_SUCCEEDED" = "true" ] && echo "  Регистрация в панели выполнена." || true

            # Публичный ключ для ноды
            pubkey_resp=$(curl -s --connect-timeout 5 --max-time 15 -H "$api_host_header" -H "Authorization: Bearer $token" "$domain_url/api/keygen") || true
            PUBLIC_KEY=$(echo "$pubkey_resp" | jq -r '.response.pubKey // .pubKey // empty')
            if [ -z "$PUBLIC_KEY" ]; then
                echo -e "${YELLOW}  Не удалось получить публичный ключ. Ноду нужно настроить вручную.${NC}"
            else
                sed -i "s|SECRET_KEY=REPLACE_PUBLIC_KEY_FROM_PANEL|SECRET_KEY=$PUBLIC_KEY|" "$REMNAWAVE_DIR/docker-compose-node.yml"

                # x25519 ключи и конфиг-профиль
                keys_resp=$(curl -s --connect-timeout 5 --max-time 15 -H "$api_host_header" -H "Authorization: Bearer $token" "$domain_url/api/system/tools/x25519/generate") || true
                PRIVATE_KEY=$(echo "$keys_resp" | jq -r '.response.keypairs[0].privateKey // empty')
                if [ -z "$PRIVATE_KEY" ]; then
                    echo -e "${YELLOW}  Не удалось сгенерировать x25519. Профиль создайте в панели.${NC}"
                else
                    # Удалить дефолтный профиль (если есть)
                    profiles=$(curl -s --connect-timeout 5 --max-time 15 -H "$api_host_header" -H "Authorization: Bearer $token" "$domain_url/api/config-profiles") || true
                    def_uuid=$(echo "$profiles" | jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid' 2>/dev/null)
                    [ -n "$def_uuid" ] && curl -s -X DELETE -H "$api_host_header" -H "Authorization: Bearer $token" "$domain_url/api/config-profiles/$def_uuid" >/dev/null || true

                    SHORT_ID=$(openssl rand -hex 8)
                    # Reality на 8443, dest — облако для маскировки (панель на 443 через host nginx)
                    create_profile=$(curl -s --connect-timeout 5 --max-time 30 -X POST -H "$api_host_header" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
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
                        curl -s -X POST -H "$api_host_header" -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/nodes" -d "$node_payload" >/dev/null || true

                        # Host для подписок: порт 8443, SNI cloudflare
                        host_payload="{\"inbound\":{\"configProfileUuid\":\"$config_uuid\",\"configProfileInboundUuid\":\"$inbound_uuid\"},\"remark\":\"Steal\",\"address\":\"$SELFSTEAL_DOMAIN\",\"port\":8443,\"path\":\"\",\"sni\":\"www.cloudflare.com\",\"host\":\"\",\"fingerprint\":\"chrome\",\"allowInsecure\":false,\"isDisabled\":false,\"securityLayer\":\"DEFAULT\"}"
                        curl -s -X POST -H "$api_host_header" -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/hosts" -d "$host_payload" >/dev/null || true

                        # Internal Squad — привязать inbound
                        squads=$(curl -s --connect-timeout 5 --max-time 15 -H "$api_host_header" -H "Authorization: Bearer $token" "$domain_url/api/internal-squads") || true
                        squad_uuid=$(echo "$squads" | jq -r '.response.internalSquads[0].uuid // empty' 2>/dev/null)
                        if [ -n "$squad_uuid" ]; then
                            update_squad=$(curl -s -X PATCH -H "$api_host_header" -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/internal-squads" \
                                -d "{\"uuid\":\"$squad_uuid\",\"inbounds\":[\"$inbound_uuid\"]}") || true
                        fi

                        # API-токен для Subscription Page
                        tok_resp=$(curl -s --connect-timeout 5 --max-time 15 -X POST -H "$api_host_header" -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$domain_url/api/tokens" -d '{"tokenName":"subscription-page"}') || true
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
    # API панели — через локальный nginx-прокси (Host + X-Forwarded-Proto), только 127.0.0.1
    REMNAWAVE_API_URL="http://127.0.0.1:${REMNAWAVE_API_PROXY_PORT:-9080}"
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

# Обновить .env: WEBHOOK_BASE_URL (при панель+нода 443 занят под панель — webhook можно оставить на 443, т.к. другой server_name)
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
# Резерв: если когда-либо понадобится вешать webhook на 8443 (один домен с панелью), выставить NEED_WEBHOOK_8443=1 и раскомментировать блок ниже
# if [ -n "$NEED_WEBHOOK_8443" ] && [ -f /etc/nginx/sites-available/vpn-bot ] && grep -q "listen 443" /etc/nginx/sites-available/vpn-bot 2>/dev/null; then
#     sed -i 's/listen 443 ssl;/listen 8443 ssl;/' /etc/nginx/sites-available/vpn-bot
#     sed -i 's/listen \[::\]:443 ssl;/listen [::]:8443 ssl;/' /etc/nginx/sites-available/vpn-bot
#     nginx -t && systemctl reload nginx
#     echo "  Webhook на 8443, WEBHOOK_BASE_URL=https://$WEBHOOK_DOMAIN:8443"
# fi

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

# Команда vlessbot — управление через консоль (меню: перезагрузка, логи, удаление бота)
if [ -d "$(dirname "$INSTALL_DIR")" ] && [ -f "$INSTALL_DIR/cli.py" ]; then
    cat > /usr/local/bin/vlessbot << VLBEOF
#!/bin/sh
INSTALL_DIR='$INSTALL_DIR'
exec "\$INSTALL_DIR/venv/bin/python" "\$INSTALL_DIR/cli.py" "\$@"
VLBEOF
    chmod 755 /usr/local/bin/vlessbot 2>/dev/null || true
    echo "  Команда управления: ${CYAN}vlessbot${NC} (меню по цифрам)"
fi

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
if [ "$REGISTRATION_SUCCEEDED" = "true" ] && [ -n "$SUPERADMIN_USER" ] && [ -n "$SUPERADMIN_PASS" ]; then
echo -e "   Логин:  ${CYAN}${SUPERADMIN_USER}${NC}"
echo -e "   Пароль: ${CYAN}${SUPERADMIN_PASS}${NC}"
else
echo -e "   Логин и пароль — учётные данные, созданные при первом входе в панель (или при ручной регистрации)."
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
[ "$REMNAWAVE_NODE_INSTALL" != "true" ] && echo -e "   • Если позже добавите ноду на этом же сервере (Nodes → Add Node): Domain or IP: ${CYAN}172.30.0.1${NC}, Node Port: ${CYAN}2222${NC}; SECRET_KEY скопируйте из формы в docker-compose ноды."
echo -e "   • Создайте Internal Squad (группу подписок) и привяжите ноду, если ещё не сделано"
echo -e "   • Зайдите в Settings → API Tokens → создайте токен"
echo -e "   • Вставьте токен в файл: ${CYAN}sudo nano $REMNAWAVE_DIR/.env${NC}"
echo -e "     (строка REMNAWAVE_API_TOKEN=). Сохранить: Ctrl+O, Enter. Выход: Ctrl+X"
echo -e "   • Перезапустите: ${CYAN}cd $REMNAWAVE_DIR && sudo $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml -f docker-compose-sub.yml restart remnawave-subscription-page${NC}"
echo ""
if [ "$REMNAWAVE_NODE_INSTALL" = "true" ]; then
echo -e "${CYAN}--- Если нода не настроилась автоматически (было «Ожидание API панели» или «Регистрация через API не удалась») ---${NC}"
echo -e "   ${GREEN}Вариант А:${NC} Задайте REMNAWAVE_ADMIN_USER и REMNAWAVE_ADMIN_PASS и запустите обновление: ${CYAN}REMNAWAVE_ADMIN_USER=логин REMNAWAVE_ADMIN_PASS=пароль sudo ./install.sh${NC} — API-токен и при необходимости SECRET_KEY ноды подставятся автоматически."
echo -e "   ${GREEN}Вариант Б:${NC} Настройте вручную по шагам:"
echo -e "   ${YELLOW}1.${NC} Откройте панель по ссылке выше, войдите (или создайте первого пользователя при первом входе)."
echo -e "   ${YELLOW}2.${NC} В панели: Nodes → Add Node. В форме укажите:"
echo -e "      • Internal name — любое (например Node1)"
echo -e "      • Domain or IP: ${CYAN}172.30.0.1${NC} (всё на одном сервере — так панель достучится до ноды)"
echo -e "      • Node Port: ${CYAN}2222${NC}"
echo -e "      Скопируйте Secret Key (SECRET_KEY) из формы — понадобится в п.4."
echo -e "   ${YELLOW}3.${NC} На сервере откройте: ${CYAN}sudo nano $REMNAWAVE_DIR/docker-compose-node.yml${NC}"
echo -e "   ${YELLOW}4.${NC} Замените строку ${CYAN}SECRET_KEY=REPLACE_PUBLIC_KEY_FROM_PANEL${NC} на ${CYAN}SECRET_KEY=<ваш_скопированный_ключ>${NC}"
echo -e "   ${YELLOW}5.${NC} Перезапустите ноду: ${CYAN}cd $REMNAWAVE_DIR && sudo $DOCKER_COMPOSE_CMD -f docker-compose-prod.yml -f docker-compose-sub.yml -f docker-compose-node.yml up -d remnanode${NC}"
echo ""
fi
echo -e "${CYAN}Шаг 2. Файл настроек бота (.env)${NC}"
echo -e "   Откройте: ${CYAN}sudo nano $INSTALL_DIR/.env${NC}"
echo -e "   Заполните (где взять — в скобках):"
echo -e "   • TELEGRAM_BOT_TOKEN — токен от @BotFather в Telegram"
echo -e "   • ADMIN_IDS — ваш Telegram ID (число, можно узнать у @userinfobot)"
echo -e "   • YOOKASSA_SHOP_ID и YOOKASSA_SECRET_KEY — из личного кабинета ЮKassa"
echo -e "   • REMNAWAVE_USERNAME и REMNAWAVE_PASSWORD — логин и пароль из шага 1"
echo -e "   • REMNAWAVE_API_URL — для панели на этом сервере оставьте ${CYAN}http://127.0.0.1:9080${NC} (локальный прокси API)"
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
echo -e "Управление (меню): ${CYAN}vlessbot${NC} (перезапуск, логи, удаление бота)"
echo ""
