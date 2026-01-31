"""Конфигурация приложения"""
import os
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class RemnawaveConfig:
    """Настройки Remnawave панели"""
    api_url: str = "https://panel.example.com"
    username: str = ""
    password: str = ""
    # UUID группы подписок (Internal Squad) - указывается в панели Remnawave
    squad_uuid: str = ""
    # URL страницы подписок (для формирования ссылки пользователю)
    subscription_base_url: str = ""


@dataclass
class PlanConfig:
    """Конфигурация тарифа"""
    id: str
    name: str
    price: float
    duration_days: int
    data_limit_gb: int = 0  # 0 = безлимит
    # UUID группы подписок для этого тарифа (переопределяет общий)
    squad_uuid: Optional[str] = None


@dataclass
class Config:
    """Главная конфигурация"""
    # Telegram
    bot_token: str = ""
    # Yookassa
    yookassa_shop_id: str = ""
    yookassa_secret_key: str = ""
    # URL для webhook Yookassa (должен быть доступен из интернета)
    webhook_base_url: str = "https://your-domain.com"
    # Пробный режим: 0 = отключен, >0 = количество дней
    trial_days: int = 0
    # Лимит трафика для пробного периода (ГБ), 0 = безлимит
    trial_data_limit_gb: int = 0
    # Реферальная программа: дни к подписке реферера за каждого приглашённого
    referral_days: int = 0
    expired_cleanup_days: int = 7  # 0 = отключено
    # Remnawave
    remnawave: RemnawaveConfig = field(default_factory=RemnawaveConfig)
    # Тарифы
    plans: list[PlanConfig] = field(default_factory=lambda: [
        PlanConfig("monthly", "1 месяц", 199.0, 30),
        PlanConfig("3months", "3 месяца", 499.0, 90),
        PlanConfig("yearly", "12 месяцев", 1499.0, 365),
    ])

    @classmethod
    def from_env(cls) -> "Config":
        """Загрузка из переменных окружения"""
        import os
        from dotenv import load_dotenv
        load_dotenv()

        remnawave = RemnawaveConfig(
            api_url=os.getenv("REMNAWAVE_API_URL", "https://panel.example.com"),
            username=os.getenv("REMNAWAVE_USERNAME", ""),
            password=os.getenv("REMNAWAVE_PASSWORD", ""),
            squad_uuid=os.getenv("REMNAWAVE_SQUAD_UUID", ""),
            subscription_base_url=os.getenv("REMNAWAVE_SUBSCRIPTION_URL", ""),
        )

        plans_str = os.getenv("PLANS", "")
        plans = cls().plans
        if plans_str:
            # Формат: id:name:price:days:gb,squad_uuid (опционально)
            plans = []
            for p in plans_str.split(";"):
                parts = p.split(":")
                if len(parts) >= 4:
                    gb = int(parts[4]) if len(parts) > 4 else 0
                    squad = parts[5] if len(parts) > 5 else None
                    plans.append(PlanConfig(
                        id=parts[0], name=parts[1],
                        price=float(parts[2]), duration_days=int(parts[3]),
                        data_limit_gb=gb, squad_uuid=squad
                    ))

        return cls(
            bot_token=os.getenv("TELEGRAM_BOT_TOKEN", ""),
            yookassa_shop_id=os.getenv("YOOKASSA_SHOP_ID", ""),
            yookassa_secret_key=os.getenv("YOOKASSA_SECRET_KEY", ""),
            webhook_base_url=os.getenv("WEBHOOK_BASE_URL", "https://your-domain.com"),
            trial_days=int(os.getenv("TRIAL_DAYS", "0")),
            trial_data_limit_gb=int(os.getenv("TRIAL_DATA_LIMIT_GB", "0")),
            referral_days=int(os.getenv("REFERRAL_DAYS", "0")),
            expired_cleanup_days=int(os.getenv("EXPIRED_CLEANUP_DAYS", "7")),
            remnawave=remnawave,
            plans=plans,
        )
