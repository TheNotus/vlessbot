"""Клиент Yookassa для приёма платежей"""
import uuid
from typing import Optional

from yookassa import Configuration, Payment

from config import Config, PlanConfig


def init_yookassa(shop_id: str, secret_key: str) -> None:
    """Инициализировать Yookassa"""
    Configuration.configure(shop_id, secret_key)


def create_payment(
    amount: float,
    description: str,
    return_url: str,
    metadata: Optional[dict] = None,
) -> dict:
    """
    Создать платёж в Yookassa.

    Args:
        amount: Сумма в рублях
        description: Описание заказа
        return_url: URL для возврата после оплаты
        metadata: Дополнительные данные (telegram_id, plan_id и т.д.)

    Returns:
        Данные платежа с confirmation_url для редиректа
    """
    idempotence_key = str(uuid.uuid4())

    payment = Payment.create(
        {
            "amount": {
                "value": f"{amount:.2f}",
                "currency": "RUB",
            },
            "capture": True,
            "confirmation": {
                "type": "redirect",
                "return_url": return_url,
            },
            "description": description,
            "metadata": metadata or {},
        },
        idempotence_key,
    )

    return {
        "id": payment.id,
        "status": payment.status,
        "amount": float(payment.amount.value),
        "confirmation_url": payment.confirmation.confirmation_url if payment.confirmation else None,
        "metadata": payment.metadata or {},
    }


def get_payment(payment_id: str) -> dict:
    """Получить информацию о платеже"""
    payment = Payment.find_one(payment_id)
    return {
        "id": payment.id,
        "status": payment.status,
        "paid": payment.paid,
        "amount": float(payment.amount.value),
        "metadata": payment.metadata or {},
    }
