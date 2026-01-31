#!/usr/bin/env python3
"""Скрипт удаления истёкших VPN-ключей из Remnawave (> N дней)"""
import logging
import os
import sys

# Настройка логирования до импорта других модулей
LOG_DIR = os.getenv("VPN_BOT_LOG_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "logs"
)
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(os.path.join(LOG_DIR, "cleanup.log"), encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)


def main():
    from config import Config
    from remnawave_client import RemnawaveClient, RemnawaveError

    config = Config.from_env()
    if config.expired_cleanup_days <= 0:
        logger.info("Очистка отключена (EXPIRED_CLEANUP_DAYS=0)")
        return 0

    try:
        client = RemnawaveClient(config.remnawave)
        deleted = client.delete_expired_users(config.expired_cleanup_days)
        logger.info(f"Удалено истёкших ключей: {deleted}")
        return 0
    except RemnawaveError as e:
        logger.error(f"Ошибка Remnawave: {e}")
        return 1
    except Exception as e:
        logger.exception(f"Ошибка: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
