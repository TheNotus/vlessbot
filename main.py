"""Точка входа приложения — единый режим: webhook + nginx + админ-панель"""
import asyncio
import logging
import os
import sys
import threading

from config import Config
from bot import create_bot

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


async def run_bot(config: Config):
    """Запустить бота (polling)"""
    if not config.bot_token:
        logger.error("TELEGRAM_BOT_TOKEN не задан в .env")
        sys.exit(1)

    bot = create_bot(config)
    await bot.db.init()
    app = bot.build_application()
    await app.initialize()
    await app.start()
    logger.info("Бот запущен (polling)")

    await app.updater.start_polling(drop_pending_updates=True)
    stop_event = asyncio.Event()
    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass

    await app.updater.stop()
    await app.stop()
    await app.shutdown()


def run_admin_panel_thread(config: Config, db, remnawave):
    """Запуск админ-панели в отдельном потоке"""
    if not config.admin_panel_enabled or not config.admin_panel_password:
        return
    from admin_panel import run_admin_panel
    t = threading.Thread(target=run_admin_panel, args=(config, db, remnawave), daemon=True)
    t.start()
    logger.info("Админ-панель запущена в фоне (SSH-туннель)")


def run_webhook():
    """Запустить webhook, бота и админ-панель (nginx — reverse proxy)"""
    from webhook import run_webhook_server

    config = Config.from_env()

    if not config.bot_token:
        logger.error("TELEGRAM_BOT_TOKEN не задан")
        sys.exit(1)
    if not config.yookassa_shop_id or not config.yookassa_secret_key:
        logger.error("YOOKASSA_SHOP_ID и YOOKASSA_SECRET_KEY должны быть заданы")
        sys.exit(1)
    if not config.webhook_base_url or config.webhook_base_url in (
        "https://your-domain.com", "https://example.com"
    ):
        logger.error("Задайте WEBHOOK_BASE_URL в .env (например https://bot.your-domain.com)")
        sys.exit(1)

    # Админ-панель в отдельном потоке (до создания бота нужны db и remnawave)
    from database import Database
    from remnawave_client import RemnawaveClient
    db = Database()
    remnawave = RemnawaveClient(config.remnawave)

    def start_admin():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        loop.run_until_complete(db.init())
        from admin_panel import run_admin_panel
        run_admin_panel(config, db, remnawave)

    if config.admin_panel_enabled and config.admin_panel_password:
        admin_thread = threading.Thread(target=start_admin, daemon=True)
        admin_thread.start()
        logger.info(f"Админ-панель: ssh -L {config.admin_panel_port}:127.0.0.1:{config.admin_panel_port} user@server")

    # Webhook в отдельном потоке
    def start_webhook():
        run_webhook_server(config)

    webhook_thread = threading.Thread(target=start_webhook, daemon=True)
    webhook_thread.start()

    # Бот в main thread
    asyncio.run(run_bot(config))


if __name__ == "__main__":
    run_webhook()
