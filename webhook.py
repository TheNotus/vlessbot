"""Webhook сервер для приёма уведомлений Yookassa"""
import asyncio
import logging
from typing import Optional

import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse
from telegram import Bot

from config import Config
from database import Database
from remnawave_client import RemnawaveClient, RemnawaveError
from utils import extract_short_uuid, get_subscription_url

logger = logging.getLogger(__name__)

app = FastAPI(title="VPN Bot Webhook")

# Глобальные объекты (инициализируются в main)
config: Optional[Config] = None
db: Optional[Database] = None
remnawave: Optional[RemnawaveClient] = None
telegram_bot: Optional[Bot] = None


@app.post("/webhook/yookassa")
async def yookassa_webhook(request: Request) -> Response:
    """
    Webhook для приёма уведомлений от Yookassa о статусе платежа.

    В личном кабинете Yookassa нужно указать URL:
    https://your-domain.com/webhook/yookassa
    """
    try:
        body = await request.json()
    except Exception as e:
        logger.error(f"Ошибка парсинга тела запроса: {e}")
        return Response(status_code=400)

    # Yookassa отправляет объект с полем "object" - данные платежа
    payment_object = body.get("object", body)
    payment_id = payment_object.get("id")
    status = payment_object.get("status")
    metadata = payment_object.get("metadata", {})

    if not payment_id:
        logger.warning("Webhook без payment_id")
        return Response(status_code=400)

    logger.info(f"Webhook Yookassa: payment_id={payment_id}, status={status}")

    if status != "succeeded":
        # Для отменённых/неуспешных платежей просто логируем
        if status in ("canceled", "pending"):
            return Response(status_code=200)
        return Response(status_code=200)

    # Обрабатываем успешный платёж
    await process_successful_payment(payment_id, metadata)

    return Response(status_code=200)


async def process_successful_payment(payment_id: str, metadata: dict) -> None:
    """
    Обработать успешный платёж:
    1. Создать пользователя в Remnawave
    2. Сохранить заказ в БД
    3. Отправить подписку пользователю в Telegram
    """
    if not db or not remnawave or not config:
        logger.error("Сервисы не инициализированы")
        return

    # Проверяем, не обработан ли уже платёж
    order = await db.get_order_by_payment(payment_id)
    if order and order.status == "succeeded":
        logger.info(f"Платёж {payment_id} уже обработан")
        return

    telegram_id = metadata.get("telegram_id")
    plan_id = metadata.get("plan_id")

    if not telegram_id or not plan_id:
        logger.error(f"Нет telegram_id или plan_id в metadata: {metadata}")
        return

    telegram_id = int(telegram_id)
    plan = next((p for p in config.plans if p.id == plan_id), None)
    if not plan:
        logger.error(f"Тариф {plan_id} не найден")
        return

    # Генерируем уникальный username
    username = f"tg_{telegram_id}_{payment_id[:8]}"

    try:
        # Создаём пользователя в Remnawave
        user_data = remnawave.create_user(
            username=username,
            plan=plan,
            telegram_id=telegram_id,
        )

        short_uuid = extract_short_uuid(user_data)

        if not short_uuid:
            logger.error(f"Short UUID не найден в ответе Remnawave: {user_data}")
            return

        # Обновляем заказ в БД
        await db.update_order_success(
            payment_id=payment_id,
            username=username,
            short_uuid=short_uuid,
        )

        # Реферальный бонус: добавляем дни рефереру
        referrer_id = metadata.get("referrer_id")
        if referrer_id and config.referral_days > 0:
            referrer_id = int(referrer_id)
            if referrer_id != telegram_id:
                try:
                    if remnawave.extend_user_by_telegram_id(referrer_id, config.referral_days):
                        await db.add_referral(referrer_id, telegram_id)
                        if telegram_bot:
                            try:
                                await telegram_bot.send_message(
                                    chat_id=referrer_id,
                                    text=f"🎉 Ваш реферал оплатил подписку! Вам добавлено +{config.referral_days} дней к подписке.",
                                )
                            except Exception:
                                pass
                except Exception as e:
                    logger.error(f"Ошибка начисления реферального бонуса: {e}")

        # Формируем URL подписки
        subscription_url = get_subscription_url(
            short_uuid, config.remnawave.subscription_base_url
        )

        # Отправляем сообщение пользователю в Telegram
        if telegram_bot:
            message_text = f"""
✅ *Оплата прошла успешно!*

Ваша VPN подписка активирована.

*Тариф:* {plan.name}
*Срок:* {plan.duration_days} дней

*Ссылка для подписки:*
`{subscription_url}`

📲 *Как использовать:*
1. Скопируйте ссылку выше
2. Откройте приложение VPN (Clash, V2Ray, Shadowrocket, Streisand и др.)
3. Добавьте подписку по ссылке

Приятного использования! 🚀
"""
            try:
                await telegram_bot.send_message(
                    chat_id=telegram_id,
                    text=message_text,
                    parse_mode="Markdown",
                )
                logger.info(f"Подписка отправлена пользователю {telegram_id}")
            except Exception as e:
                logger.error(f"Ошибка отправки в Telegram: {e}")

    except RemnawaveError as e:
        logger.error(f"Ошибка Remnawave при создании пользователя: {e}")
        await db.update_order_status(payment_id, "failed")
        await _notify_payment_failure(telegram_id, plan.name, str(e))
    except Exception as e:
        logger.exception(f"Ошибка обработки платежа {payment_id}")
        await db.update_order_status(payment_id, "failed")
        await _notify_payment_failure(telegram_id, plan.name, str(e))


async def _notify_payment_failure(
    telegram_id: int, plan_name: str, error_msg: str
) -> None:
    """Уведомить пользователя об ошибке обработки платежа"""
    if not telegram_bot:
        return
    try:
        await telegram_bot.send_message(
            chat_id=telegram_id,
            text=(
                "❌ *Оплата получена, но возникла ошибка при активации подписки.*\n\n"
                f"Тариф: {plan_name}\n\n"
                "Обратитесь в поддержку — мы исправим ситуацию в ближайшее время."
            ),
            parse_mode="Markdown",
        )
    except Exception as e:
        logger.error(f"Не удалось отправить уведомление об ошибке: {e}")


@app.get("/return")
async def payment_return(request: Request):
    """
    Страница возврата после оплаты.
    Пользователь попадает сюда после оплаты в Yookassa.
    """
    # Простая страница с информацией - подписка придёт в Telegram
    html_content = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><title>Оплата прошла</title></head>
    <body style="font-family:sans-serif;text-align:center;padding:50px;">
        <h1>✅ Оплата прошла успешно!</h1>
        <p>Ваша VPN подписка будет отправлена в Telegram в течение минуты.</p>
        <p>Проверьте чат с ботом.</p>
    </body>
    </html>
    """
    return HTMLResponse(html_content)


@app.get("/health")
async def health():
    """Проверка работоспособности"""
    return {"status": "ok"}


def run_webhook_server(
    cfg: Config,
    host: Optional[str] = None,
    port: Optional[int] = None,
) -> None:
    """Запустить webhook сервер"""
    global config, db, remnawave, telegram_bot

    # Логирование настраивается в main.py до вызова
    config = cfg
    db = Database()
    remnawave = RemnawaveClient(cfg.remnawave)
    telegram_bot = Bot(token=cfg.bot_token) if cfg.bot_token else None

    host = host or cfg.webhook_host
    port = port if port is not None else cfg.webhook_port

    # Инициализация БД
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(db.init())

    uvicorn.run(app, host=host, port=port)
