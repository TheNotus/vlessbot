"""Клиент API Remnawave для управления пользователями VPN"""
import json
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Optional, TypeVar

import requests

from config import PlanConfig, RemnawaveConfig

logger = logging.getLogger(__name__)


def _safe_json(response: requests.Response) -> Optional[dict]:
    """Безопасно распарсить JSON из ответа; при ошибке — None или RemnawaveError для 4xx/5xx."""
    if not response.text or not response.text.strip():
        return None
    try:
        return response.json()
    except (json.JSONDecodeError, ValueError) as e:
        logger.warning("Ответ панели не JSON: %s", e)
        raise RemnawaveError(
            f"Ответ панели не JSON: {response.text[:200]}",
            status_code=response.status_code,
            response=None,
        )

T = TypeVar("T")


def _retry(
    func: Callable[..., T],
    max_attempts: int = 3,
    delay: float = 1.0,
    backoff: float = 2.0,
) -> Callable[..., T]:
    """Повторить вызов при временных ошибках"""
    def wrapper(*args: Any, **kwargs: Any) -> T:
        last_exc: Optional[Exception] = None
        current_delay = delay
        for attempt in range(max_attempts):
            try:
                return func(*args, **kwargs)
            except RemnawaveError as e:
                last_exc = e
                if e.status_code and e.status_code in (401, 500, 502, 503) and attempt < max_attempts - 1:
                    logger.warning(f"Remnawave retry {attempt + 1}/{max_attempts}: {e}")
                    time.sleep(current_delay)
                    current_delay *= backoff
                else:
                    raise
            except requests.RequestException as e:
                last_exc = e
                if attempt < max_attempts - 1:
                    logger.warning(f"Remnawave retry {attempt + 1}/{max_attempts}: {e}")
                    time.sleep(current_delay)
                    current_delay *= backoff
                else:
                    raise RemnawaveError(str(e)) from e
        raise last_exc or RemnawaveError("Unknown error")
    return wrapper


class RemnawaveError(Exception):
    """Ошибка API Remnawave"""
    def __init__(self, message: str, status_code: Optional[int] = None, response: Optional[dict] = None):
        super().__init__(message)
        self.status_code = status_code
        self.response = response


class RemnawaveClient:
    """Клиент для работы с API Remnawave"""

    def __init__(self, config: RemnawaveConfig):
        self.base_url = config.api_url.rstrip("/")
        self.username = config.username
        self.password = config.password
        self.default_squad_uuid = config.squad_uuid
        self._token: Optional[str] = None

    def _clear_token(self) -> None:
        """Сбросить токен (для переавторизации при 401)"""
        self._token = None

    def _get_token(self) -> str:
        """Получить JWT токен авторизации"""
        if self._token:
            return self._token
            
        response = requests.post(
            f"{self.base_url}/api/auth/login",
            json={"username": self.username, "password": self.password},
            headers={"Content-Type": "application/json"},
            timeout=30,
        )

        if response.status_code != 200:
            raise RemnawaveError(
                f"Ошибка авторизации: {response.text[:500] if response.text else 'пустой ответ'}",
                status_code=response.status_code,
                response=_safe_json(response),
            )

        data = _safe_json(response)
        if not data:
            raise RemnawaveError("Пустой ответ панели при логине", status_code=response.status_code, response=None)
        self._token = data.get("accessToken") or data.get("access_token")
        if not self._token:
            raise RemnawaveError("Токен не найден в ответе", response=data)

        return self._token

    def _request(
        self,
        method: str,
        path: str,
        json_data: Optional[dict] = None,
        params: Optional[dict] = None,
    ) -> dict:
        """Выполнить запрос к API (с retry и обновлением токена при 401)"""
        url = f"{self.base_url}{path}"
        headers = {
            "Authorization": f"Bearer {self._get_token()}",
            "Content-Type": "application/json",
        }

        response = requests.request(
            method=method,
            url=url,
            json=json_data,
            params=params,
            headers=headers,
            timeout=30,
        )

        if response.status_code == 401:
            self._clear_token()
            logger.info("Remnawave 401: токен сброшен, повторная авторизация")
            return self._request(method, path, json_data, params)

        if response.status_code >= 400:
            raise RemnawaveError(
                f"Ошибка API: {response.text[:500] if response.text else 'пустой ответ'}",
                status_code=response.status_code,
                response=_safe_json(response),
            )

        return _safe_json(response) or {}

    def get_internal_squads(self) -> list[dict]:
        """Получить список Internal Squads (групп подписок)"""
        response = self._request("GET", "/api/internal-squads")
        return response.get("squads", response) if isinstance(response, dict) else response

    def create_user(
        self,
        username: str,
        plan: PlanConfig,
        telegram_id: Optional[int] = None,
    ) -> dict:
        """
        Создать пользователя VPN в Remnawave.

        Args:
            username: Имя пользователя (уникальное)
            plan: Тарифный план
            telegram_id: ID Telegram для привязки

        Returns:
            Данные созданного пользователя с shortUuid для подписки
        """
        # Определяем группу подписок
        squad_uuid = plan.squad_uuid or self.default_squad_uuid
        internal_squad_uuids = [squad_uuid] if squad_uuid else []

        # Дата истечения подписки
        expiration_date = (datetime.utcnow() + timedelta(days=plan.duration_days)).isoformat() + "Z"

        # dataLimit: 0 = безлимит, иначе в байтах
        data_limit_bytes = (
            plan.data_limit_gb * 1024 * 1024 * 1024
            if plan.data_limit_gb > 0
            else 0
        )
        payload = {
            "username": username,
            "dataLimit": data_limit_bytes,
            "trafficResetStrategy": "no_reset",  # daily, monthly, no_reset
            "expirationTime": expiration_date,
            "internalSquadUuids": internal_squad_uuids,
        }

        if telegram_id:
            payload["telegramId"] = str(telegram_id)

        response = _retry(lambda: self._request("POST", "/api/users", json_data=payload))()

        return response

    def get_subscription_url(self, short_uuid: str, base_url: Optional[str] = None) -> str:
        """
        Получить URL подписки для пользователя.

        Args:
            short_uuid: Short UUID пользователя из Remnawave
            base_url: Базовый URL страницы подписок (если не указан - используется из конфига)
        """
        if base_url:
            return f"{base_url.rstrip('/')}/sub/{short_uuid}"
        return f"{short_uuid}"  # Возвращаем только short_uuid, полный URL формируется в конфиге

    def get_user_by_username(self, username: str) -> Optional[dict]:
        """Получить пользователя по имени"""
        try:
            return self._request("GET", f"/api/users/by-username/{username}")
        except RemnawaveError as e:
            if e.status_code == 404:
                return None
            raise

    def get_user_by_telegram_id(self, telegram_id: int) -> Optional[list]:
        """Получить пользователей по Telegram ID"""
        try:
            response = self._request("GET", f"/api/users/by-telegram-id/{telegram_id}")
            users = response.get("users", response)
            return users if isinstance(users, list) else [users] if users else []
        except RemnawaveError as e:
            if e.status_code == 404:
                return []
            raise

    def extend_user_subscription(
        self, user_uuid: str, additional_days: int
    ) -> dict:
        """
        Продлить подписку пользователя на N дней.
        Используется для реферальных бонусов.
        """
        from datetime import datetime, timedelta

        user = self._request("GET", f"/api/users/{user_uuid}")
        user_obj = user.get("user", user) if isinstance(user, dict) else user

        current_exp = user_obj.get("expirationTime") or user_obj.get("expiration_time")
        if current_exp and isinstance(current_exp, str):
            try:
                exp_dt = datetime.fromisoformat(current_exp.replace("Z", "+00:00"))
            except ValueError:
                exp_dt = datetime.utcnow()
        else:
            exp_dt = datetime.utcnow()

        new_exp = exp_dt + timedelta(days=additional_days)
        new_exp_str = new_exp.strftime("%Y-%m-%dT%H:%M:%S.000Z")

        return self._request("PATCH", "/api/users", json_data={
            "uuid": user_uuid,
            "expirationTime": new_exp_str,
        })

    def get_all_users(self, size: int = 500, start: int = 0) -> dict:
        """Получить список всех пользователей (с пагинацией)"""
        return self._request("GET", "/api/users", params={"size": size, "start": start})

    def delete_user(self, user_uuid: str) -> dict:
        """Удалить пользователя по UUID"""
        return self._request("DELETE", f"/api/users/{user_uuid}")

    def delete_expired_users(self, older_than_days: int = 7) -> int:
        """
        Удалить пользователей, подписка которых истекла более N дней назад.
        Возвращает количество удалённых.
        """
        from datetime import datetime, timedelta, timezone

        cutoff = datetime.now(timezone.utc) - timedelta(days=older_than_days)
        deleted = 0
        start = 0
        size = 100

        while True:
            resp = self.get_all_users(size=size, start=start)
            users = resp.get("users") or resp.get("data")
            if isinstance(users, dict):
                users = users.get("users", [])
            if not users or not isinstance(users, list):
                break
            for user in users:
                u = user.get("user", user) if isinstance(user, dict) else user
                exp = u.get("expirationTime") or u.get("expiration_time")
                if not exp:
                    continue
                try:
                    exp_dt = datetime.fromisoformat(exp.replace("Z", "+00:00"))
                    if exp_dt.tzinfo is None:
                        exp_dt = exp_dt.replace(tzinfo=timezone.utc)
                except (ValueError, TypeError):
                    continue
                if exp_dt < cutoff:
                    uid = u.get("uuid") or u.get("id")
                    if uid:
                        try:
                            self.delete_user(uid)
                            deleted += 1
                        except RemnawaveError:
                            pass
            if len(users) < size:
                break
            start += size

        return deleted

    def extend_user_by_telegram_id(
        self, telegram_id: int, additional_days: int
    ) -> bool:
        """
        Продлить подписку пользователя по Telegram ID (для реферальных бонусов).
        Возвращает True если успешно.
        """
        users = self.get_user_by_telegram_id(telegram_id)
        if not users:
            return False
        user = users[0] if isinstance(users, list) else users
        user_uuid = user.get("uuid") or user.get("id")
        if not user_uuid:
            return False
        try:
            self.extend_user_subscription(user_uuid, additional_days)
            return True
        except RemnawaveError:
            return False

    def revoke_user_by_telegram_id(self, telegram_id: int) -> tuple[int, list[str]]:
        """
        Отозвать ключи пользователя по Telegram ID (удалить из Remnawave).
        Возвращает (количество удалённых, список UUID).
        """
        users = self.get_user_by_telegram_id(telegram_id)
        if not users:
            return 0, []
        user_list = users if isinstance(users, list) else [users]
        deleted = 0
        uuids: list[str] = []
        for u in user_list:
            user_uuid = u.get("uuid") or u.get("id")
            if user_uuid:
                try:
                    self.delete_user(user_uuid)
                    deleted += 1
                    uuids.append(user_uuid)
                except RemnawaveError:
                    pass
        return deleted, uuids
