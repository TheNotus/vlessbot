"""Telegram бот для продажи VPN подписок"""
import asyncio
import logging
from typing import Optional

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
)

from config import Config, PlanConfig
from database import Database
from remnawave_client import RemnawaveClient, RemnawaveError
from yookassa_client import create_payment, init_yookassa

# Настройка логирования
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)


class VPNBot:
    """Бот для продажи VPN подписок"""

    def __init__(self, config: Config):
        self.config = config
        self.db = Database()
        self.remnawave = RemnawaveClient(config.remnawave)

        if config.yookassa_shop_id and config.yookassa_secret_key:
            init_yookassa(config.yookassa_shop_id, config.yookassa_secret_key)

    def _parse_referrer_from_start(self, context: ContextTypes.DEFAULT_TYPE) -> Optional[int]:
        """Извлечь referrer_id из /start ref_12345"""
        if not context.args:
            return None
        args = " ".join(context.args)
        if args.startswith("ref_"):
            try:
                return int(args[4:])
            except ValueError:
                return None
        return None

    def _save_referrer(self, context: ContextTypes.DEFAULT_TYPE, referrer_id: int) -> None:
        """Сохранить реферера в user_data"""
        if context.user_data is not None:
            context.user_data["referrer_id"] = referrer_id

    def _get_referrer(self, context: ContextTypes.DEFAULT_TYPE) -> Optional[int]:
        """Получить referrer_id из user_data"""
        return (context.user_data or {}).get("referrer_id")

    async def start(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        """Обработка команды /start"""
        user = update.effective_user
        if not user:
            return

        # Обработка реферальной ссылки: /start ref_12345
        referrer_id = self._parse_referrer_from_start(context)
        if referrer_id and referrer_id != user.id:
            self._save_referrer(context, referrer_id)

        welcome_text = f"""
🔐 *Добро пожаловать в VPN сервис!*

Привет, {user.first_name}! Здесь вы можете приобрести VPN подписку для безопасного и свободного доступа в интернет.

*Доступные тарифы:*
"""
        for plan in self.config.plans:
            welcome_text += f"\n• *{plan.name}* — {plan.price:.0f} ₽"

        welcome_text += "\n\nВыберите тариф или действие 👇"

        keyboard = []
        for plan in self.config.plans:
            keyboard.append([
                InlineKeyboardButton(
                    f"{plan.name} — {plan.price:.0f} ₽",
                    callback_data=f"buy:{plan.id}",
                )
            ])
        if self.config.trial_days > 0:
            keyboard.append([
                InlineKeyboardButton(
                    f"🎁 Попробовать бесплатно ({self.config.trial_days} дн.)",
                    callback_data="trial",
                )
            ])
        keyboard.append([
            InlineKeyboardButton("📋 Моя подписка", callback_data="my_subscription"),
        ])
        if self.config.referral_days > 0:
            keyboard.append([
                InlineKeyboardButton("👥 Реферальная программа", callback_data="referral"),
            ])

        reply_markup = InlineKeyboardMarkup(keyboard)

        await update.message.reply_text(
            welcome_text,
            parse_mode="Markdown",
            reply_markup=reply_markup,
        )

    async def buy_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Обработка нажатия на кнопку покупки"""
        query = update.callback_query
        await query.answer()

        if not query.data or not query.data.startswith("buy:"):
            return

        plan_id = query.data.split(":")[1]
        plan = next((p for p in self.config.plans if p.id == plan_id), None)
        if not plan:
            await query.edit_message_text("❌ Тариф не найден.")
            return

        user = query.from_user
        if not user:
            return

        telegram_id = user.id

        try:
            # Создаём платёж в Yookassa
            return_url = f"{self.config.webhook_base_url}/return"
            description = f"VPN подписка: {plan.name}"

            referrer_id = self._get_referrer(context)
            metadata = {
                "telegram_id": str(telegram_id),
                "plan_id": plan_id,
            }
            if referrer_id:
                metadata["referrer_id"] = str(referrer_id)

            payment = create_payment(
                amount=plan.price,
                description=description,
                return_url=return_url,
                metadata=metadata,
            )

            # Сохраняем заказ в БД
            await self.db.create_order(
                payment_id=payment["id"],
                telegram_id=telegram_id,
                plan_id=plan_id,
                plan_name=plan.name,
                amount=plan.price,
                referrer_id=referrer_id,
            )

            # Отправляем ссылку на оплату
            keyboard = [
                [
                    InlineKeyboardButton(
                        "💳 Оплатить",
                        url=payment["confirmation_url"],
                    )
                ],
                [InlineKeyboardButton("◀️ Назад", callback_data="back")],
            ]

            await query.edit_message_text(
                f"""
✅ *Платёж создан!*

*Тариф:* {plan.name}
*Сумма:* {plan.price:.0f} ₽

Нажмите кнопку ниже для оплаты. После успешной оплаты подписка будет автоматически выдана в этот чат.
""",
                parse_mode="Markdown",
                reply_markup=InlineKeyboardMarkup(keyboard),
            )

        except Exception as e:
            logger.exception("Ошибка создания платежа")
            await query.edit_message_text(
                f"❌ Ошибка при создании платежа. Попробуйте позже.\n\n{str(e)}"
            )

    async def my_subscription_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Показать информацию о подписке пользователя"""
        query = update.callback_query
        await query.answer()

        user = query.from_user
        if not user:
            return

        try:
            # Проверяем в Remnawave по Telegram ID
            users = self.remnawave.get_user_by_telegram_id(user.id)

            if not users or (isinstance(users, list) and len(users) == 0):
                # Проверяем в наших заказах
                orders = await self.db.get_user_orders(user.id)
                active_orders = [o for o in orders if o.status == "succeeded" and o.short_uuid]

                if not active_orders:
                    keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back")]]
                    await query.edit_message_text(
                        "📋 У вас пока нет активной подписки.\n\n"
                        "Приобретите тариф, чтобы получить доступ к VPN.",
                        reply_markup=InlineKeyboardMarkup(keyboard),
                    )
                    return

                # Берём последний активный заказ
                order = active_orders[0]
                subscription_url = self._get_subscription_url(order.short_uuid)

                text = f"""
📋 *Ваша подписка*

*Тариф:* {order.plan_name}
*Статус:* Активна ✅

*Ссылка для подписки:*
`{subscription_url}`

Скопируйте ссылку и добавьте её в приложение VPN (Clash, V2Ray, Shadowrocket и др.)
"""
            else:
                # Пользователь найден в Remnawave
                rw_user = users[0] if isinstance(users, list) else users
                short_uuid = rw_user.get("shortUuid") or rw_user.get("short_uuid")
                if short_uuid:
                    subscription_url = self._get_subscription_url(short_uuid)
                    text = f"""
📋 *Ваша подписка*

*Ссылка для подписки:*
`{subscription_url}`

Скопируйте ссылку и добавьте её в приложение VPN.
"""
                else:
                    text = "📋 Ваша подписка активна. Обратитесь в поддержку для получения ссылки."

            keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back")]]
            await query.edit_message_text(
                text,
                parse_mode="Markdown",
                reply_markup=InlineKeyboardMarkup(keyboard),
            )

        except RemnawaveError as e:
            logger.error(f"Ошибка Remnawave: {e}")
            # Показываем из наших заказов
            orders = await self.db.get_user_orders(user.id)
            active = [o for o in orders if o.status == "succeeded" and o.short_uuid]
            if active:
                order = active[0]
                sub_url = self._get_subscription_url(order.short_uuid)
                await query.edit_message_text(
                    f"📋 *Ваша подписка*\n\n`{sub_url}`",
                    parse_mode="Markdown",
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                    ]),
                )
            else:
                await query.edit_message_text(
                    "❌ Не удалось загрузить подписку. Попробуйте позже.",
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                    ]),
                )

    def _get_subscription_url(self, short_uuid: str) -> str:
        """Получить полный URL подписки"""
        base = self.config.remnawave.subscription_base_url
        if base:
            return f"{base.rstrip('/')}/sub/{short_uuid}"
        return f"https://[REMNAWAVE_DOMAIN]/sub/{short_uuid}"

    async def trial_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Обработка запроса пробного периода"""
        query = update.callback_query
        await query.answer()

        user = query.from_user
        if not user:
            return

        if self.config.trial_days <= 0:
            await query.edit_message_text(
                "Пробный период отключен.",
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                ]),
            )
            return

        used = await self.db.has_used_trial(user.id)
        if used:
            await query.edit_message_text(
                "Вы уже использовали пробный период ранее.",
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                ]),
            )
            return

        try:
            trial_plan = PlanConfig(
                id="trial",
                name="Пробный период",
                price=0,
                duration_days=self.config.trial_days,
                data_limit_gb=self.config.trial_data_limit_gb,
            )
            username = f"trial_{user.id}"
            user_data = self.remnawave.create_user(
                username=username,
                plan=trial_plan,
                telegram_id=user.id,
            )
            await self.db.add_trial_user(user.id)

            short_uuid = user_data.get("shortUuid") or user_data.get("short_uuid")
            user_obj = user_data.get("user", user_data)
            if not short_uuid:
                short_uuid = user_obj.get("shortUuid") or user_obj.get("short_uuid")

            if short_uuid:
                sub_url = self._get_subscription_url(short_uuid)
                traffic_str = f"{self.config.trial_data_limit_gb} ГБ" if self.config.trial_data_limit_gb else "безлимит"
                text = f"""
✅ *Пробный период активирован!*

*Срок:* {self.config.trial_days} дней
*Трафик:* {traffic_str}

*Ссылка для подписки:*
`{sub_url}`

Скопируйте ссылку и добавьте в приложение VPN.
"""
            else:
                text = "Пробный период создан. Проверьте панель Remnawave."

            await query.edit_message_text(
                text,
                parse_mode="Markdown",
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                ]),
            )
        except RemnawaveError as e:
            logger.exception("Ошибка создания trial")
            await query.edit_message_text(
                f"❌ Ошибка: {e}. Возможно, пользователь уже существует.",
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                ]),
            )

    async def referral_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Показать реферальную ссылку"""
        query = update.callback_query
        await query.answer()

        user = query.from_user
        if not user:
            return

        if self.config.referral_days <= 0:
            await query.edit_message_text(
                "Реферальная программа отключена.",
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton("◀️ Назад", callback_data="back")]
                ]),
            )
            return

        bot_info = await context.bot.get_me()
        bot_username = bot_info.username
        ref_link = f"https://t.me/{bot_username}?start=ref_{user.id}"

        text = f"""
👥 *Реферальная программа*

Приглашайте друзей и получайте *+{self.config.referral_days} дней* к подписке за каждого, кто оплатит тариф!

*Ваша реферальная ссылка:*
`{ref_link}`

Поделитесь ссылкой. Когда приглашённый друг совершит покупку — вам автоматически добавятся дни.
"""
        await query.edit_message_text(
            text,
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("◀️ Назад", callback_data="back")]
            ]),
        )

    async def back_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Возврат в главное меню"""
        query = update.callback_query
        await query.answer()

        user = query.from_user
        welcome_text = f"""
🔐 *VPN сервис*

Привет, {user.first_name}! Выберите тариф или действие.
"""
        keyboard = []
        for plan in self.config.plans:
            keyboard.append([
                InlineKeyboardButton(
                    f"{plan.name} — {plan.price:.0f} ₽",
                    callback_data=f"buy:{plan.id}",
                )
            ])
        if self.config.trial_days > 0:
            keyboard.append([
                InlineKeyboardButton(
                    f"🎁 Попробовать бесплатно ({self.config.trial_days} дн.)",
                    callback_data="trial",
                )
            ])
        keyboard.append([
            InlineKeyboardButton("📋 Моя подписка", callback_data="my_subscription"),
        ])
        if self.config.referral_days > 0:
            keyboard.append([
                InlineKeyboardButton("👥 Реферальная программа", callback_data="referral"),
            ])

        await query.edit_message_text(
            welcome_text,
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(keyboard),
        )

    def build_application(self) -> Application:
        """Создать приложение бота"""
        app = Application.builder().token(self.config.bot_token).build()

        app.add_handler(CommandHandler("start", self.start))
        app.add_handler(CallbackQueryHandler(self.buy_callback, pattern="^buy:"))
        app.add_handler(
            CallbackQueryHandler(self.my_subscription_callback, pattern="^my_subscription$")
        )
        app.add_handler(CallbackQueryHandler(self.trial_callback, pattern="^trial$"))
        app.add_handler(CallbackQueryHandler(self.referral_callback, pattern="^referral$"))
        app.add_handler(CallbackQueryHandler(self.back_callback, pattern="^back$"))

        return app

    async def run(self) -> None:
        """Запустить бота"""
        await self.db.init()
        app = self.build_application()

        await app.initialize()
        await app.start()
        logger.info("Бот запущен")

        # Ожидание остановки
        stop_event = asyncio.Event()
        try:
            await stop_event.wait()
        except asyncio.CancelledError:
            pass

        await app.stop()
        await app.shutdown()


def create_bot(config: Config) -> VPNBot:
    """Создать экземпляр бота"""
    return VPNBot(config)
