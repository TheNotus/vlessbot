"""Общие утилиты для VPN Bot"""
from typing import Optional


def get_subscription_url(short_uuid: str, base_url: Optional[str] = None) -> str:
    """
    Сформировать полный URL подписки.

    Args:
        short_uuid: Short UUID из Remnawave
        base_url: Базовый URL страницы подписок (REMNAWAVE_SUBSCRIPTION_URL)

    Returns:
        Полный URL вида {base_url}/sub/{short_uuid}
    """
    if base_url and base_url.strip():
        return f"{base_url.rstrip('/')}/sub/{short_uuid}"
    return f"https://[REMNAWAVE_DOMAIN]/sub/{short_uuid}"


def extract_short_uuid(user_data: Optional[dict]) -> Optional[str]:
    """Извлечь shortUuid из ответа Remnawave API"""
    if not user_data or not isinstance(user_data, dict):
        return None
    short_uuid = user_data.get("shortUuid") or user_data.get("short_uuid")
    if not short_uuid:
        user_obj = user_data.get("user", user_data)
        short_uuid = (
            (user_obj.get("shortUuid") or user_obj.get("short_uuid"))
            if isinstance(user_obj, dict)
            else None
        )
    return short_uuid
