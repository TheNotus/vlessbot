"""Конфигурация приложения"""
import logging
import os
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger(__name__)


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
    # ID администраторов (через запятую) для команды /stats
    admin_ids: tuple[int, ...] = ()
    # Yookassa
    yookassa_shop_id: str = ""
    yookassa_secret_key: str = ""
    # URL для webhook Yookassa (должен быть доступен из интернета)
    webhook_base_url: str = "https://your-domain.com"
    # Host и порт webhook сервера
    webhook_host: str = "0.0.0.0"
    webhook_port: int = 8000
    # Пробный режим: 0 = отключен, >0 = количество дней
    trial_days: int = 0
    # Лимит трафика для пробного периода (ГБ), 0 = безлимит
    trial_data_limit_gb: int = 0
    # Реферальная программа: дни к подписке реферера за каждого приглашённого
    referral_days: int = 0
    # Название VPN сервиса
    vpn_name: str = "RealityVPN"
    # Информация о клавиатуре
    keyboard_info: str = "Ниже доступны кнопки для выбора тарифа, подписки и других действий."
    # Ссылка на поддержку (пусто — блок скрыт)
    support_link: str = ""
    support_button_text: str = "НАПИСАТЬ"
    # Ссылка для сотрудничества (показывается в разделе «Контакты»)
    cooperation_link: str = ""
    # Информация — кнопка «ℹ️ Информация»
    main_menu_info: str = ""
    expired_cleanup_days: int = 7  # 0 = отключено
    # Принудительная подписка на канал: вкл/выкл (FORCED_CHANNEL_ENABLED)
    forced_channel_enabled: bool = False
    # ID канала (@channel → -100xxxxxxxxxx)
    forced_channel_id: Optional[str] = None
    # Username канала для ссылки (например @mychannel)
    forced_channel_username: Optional[str] = None
    # Админ-панель: только через SSH (127.0.0.1)
    admin_panel_enabled: bool = False
    admin_panel_port: int = 8080
    admin_panel_password: str = ""
    # Remnawave
    remnawave: RemnawaveConfig = field(default_factory=RemnawaveConfig)
    # Тарифы
    plans: list[PlanConfig] = field(default_factory=lambda: [
        PlanConfig("monthly", "1 месяц", 199.0, 30),
        PlanConfig("3months", "3 месяца", 499.0, 90),
        PlanConfig("yearly", "12 месяцев", 1499.0, 365),
    ])

    @classmethod
    def _int_env(cls, key: str, default: int) -> int:
        """Прочитать целое из env; при ошибке — default."""
        try:
            return int(os.getenv(key, str(default)))
        except (ValueError, TypeError):
            return default

    @classmethod
    def from_env(cls) -> "Config":
        """Загрузка из переменных окружения"""
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
            # Формат: id:name:price:days[:gb][:squad_uuid] — gb и squad опциональны
            plans = []
            for p in plans_str.split(";"):
                parts = p.split(":")
                if len(parts) < 4:
                    logger.warning("PLANS: пропущен невалидный тариф (нужно id:name:price:days): %r", p.strip())
                    continue
                try:
                    gb = int(parts[4]) if len(parts) > 4 and str(parts[4]).strip() else 0
                except (ValueError, IndexError):
                    gb = 0
                squad = (parts[5].strip() or None) if len(parts) > 5 else None
                try:
                    plans.append(PlanConfig(
                        id=parts[0].strip(), name=parts[1].strip(),
                        price=float(parts[2]), duration_days=int(parts[3]),
                        data_limit_gb=gb, squad_uuid=squad
                    ))
                except (ValueError, IndexError) as e:
                    logger.warning("PLANS: пропущен тариф %r — %s", p.strip(), e)
                    continue

        admin_ids_str = os.getenv("ADMIN_IDS", "")
        admin_ids: tuple[int, ...] = ()
        if admin_ids_str:
            try:
                admin_ids = tuple(int(x.strip()) for x in admin_ids_str.split(",") if x.strip())
            except ValueError:
                pass

        return cls(
            bot_token=os.getenv("TELEGRAM_BOT_TOKEN", ""),
            admin_ids=admin_ids,
            yookassa_shop_id=os.getenv("YOOKASSA_SHOP_ID", ""),
            yookassa_secret_key=os.getenv("YOOKASSA_SECRET_KEY", ""),
            webhook_base_url=os.getenv("WEBHOOK_BASE_URL", "https://your-domain.com"),
            webhook_host=os.getenv("WEBHOOK_HOST", "0.0.0.0"),
            webhook_port=cls._int_env("WEBHOOK_PORT", 8000),
            trial_days=cls._int_env("TRIAL_DAYS", 0),
            trial_data_limit_gb=cls._int_env("TRIAL_DATA_LIMIT_GB", 0),
            referral_days=cls._int_env("REFERRAL_DAYS", 0),
            vpn_name=os.getenv("VPN_NAME", "RealityVPN"),
            keyboard_info=(os.getenv("KEYBOARD_INFO") or "Ниже доступны кнопки для выбора тарифа, подписки и других действий.").replace("\\n", "\n"),
            support_link=(os.getenv("SUPPORT_LINK") or "").strip(),
            support_button_text=os.getenv("SUPPORT_BUTTON_TEXT", "НАПИСАТЬ"),
            cooperation_link=(os.getenv("COOPERATION_LINK") or "").strip(),
            main_menu_info=(os.getenv("MAIN_MENU_INFO") or "").replace("\\n", "\n"),
            expired_cleanup_days=cls._int_env("EXPIRED_CLEANUP_DAYS", 7),
            forced_channel_enabled=os.getenv("FORCED_CHANNEL_ENABLED", "false").lower() in ("1", "true", "yes"),
            forced_channel_id=os.getenv("FORCED_CHANNEL_ID") or None,
            forced_channel_username=os.getenv("FORCED_CHANNEL_USERNAME") or None,
            admin_panel_enabled=os.getenv("ADMIN_PANEL_ENABLED", "false").lower() in ("1", "true", "yes", "enable"),
            admin_panel_port=cls._int_env("ADMIN_PANEL_PORT", 8080),
            admin_panel_password=os.getenv("ADMIN_PANEL_PASSWORD", ""),
            remnawave=remnawave,
            plans=plans,
        )
