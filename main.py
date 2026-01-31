"""Точка входа приложения"""
import asyncio
import logging
import os
import sys
import threading

from config import Config
from bot import create_bot

# Настройка логирования (файл + консоль)
from logging_config import setup_logging

log_dir = os.getenv("VPN_BOT_LOG_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
try:
    setup_logging(log_dir)
except Exception:
    logging.basicConfig(
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        level=logging.INFO,
        stream=sys.stdout,
    )

logger = logging.getLogger(__name__)


async def run_bot():
    """Запустить бота (polling)"""
    config = Config.from_env()

    if not config.bot_token:
        logger.error("TELEGRAM_BOT_TOKEN не задан в .env")
        sys.exit(1)

    bot = create_bot(config)
    await bot.db.init()
    app = bot.build_application()
    await app.initialize()
    await app.start()
    logger.info("Бот запущен (polling)")

    # Запуск polling
    await app.updater.start_polling(drop_pending_updates=True)
    stop_event = asyncio.Event()
    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass

    await app.updater.stop()
    await app.stop()
    await app.shutdown()


def run_webhook():
    """Запустить webhook сервер и бота вместе"""
    from webhook import run_webhook_server

    config = Config.from_env()

    if not config.bot_token:
        logger.error("TELEGRAM_BOT_TOKEN не задан")
        sys.exit(1)
    if not config.yookassa_shop_id or not config.yookassa_secret_key:
        logger.error("YOOKASSA_SHOP_ID и YOOKASSA_SECRET_KEY должны быть заданы")
        sys.exit(1)

    # Запуск webhook в отдельном потоке
    def start_webhook():
        run_webhook_server(config)

    webhook_thread = threading.Thread(target=start_webhook, daemon=True)
    webhook_thread.start()

    # Запуск бота в main thread (polling)
    asyncio.run(run_bot())


if __name__ == "__main__":
    import os

    # Режим: bot - только бот (без оплаты), webhook - webhook + бот
    mode = os.getenv("MODE", "webhook")

    if mode == "bot":
        asyncio.run(run_bot())
    else:
        run_webhook()
