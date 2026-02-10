"""Telegram бот для продажи VPN подписок"""
import asyncio
import logging
from typing import Optional

from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    KeyboardButton,
    ReplyKeyboardMarkup,
    Update,
)
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from config import Config, PlanConfig
from database import Database
from remnawave_client import RemnawaveClient, RemnawaveError
from utils import extract_short_uuid, get_subscription_url
from yookassa_client import create_payment, init_yookassa

from bot_messages import (
    BACK_BUTTON,
    BLOCKED,
    BTN_INFO,
    BTN_MY_SUBSCRIPTION,
    BTN_REFERRAL,
    BTN_TARIFFS,
    CHOOSE_TARIFF,
    INFO_NOT_CONFIGURED,
    NO_SUBSCRIPTION,
    PAY_BUTTON,
    PAYMENT_CREATED,
    PAYMENT_ERROR,
    PLAN_NOT_FOUND,
    REFERRAL_BONUS_EXTENDED,
    REFERRAL_BONUS_PENDING,
    REFERRAL_DISABLED,
    REFERRAL_TEXT,
    STATS_NO_ACCESS,
    STATS_TEXT,
    SUBSCRIBE_BUTTON,
    SUBSCRIBE_CHECK_BUTTON,
    SUBSCRIBE_TEXT,
    SUBSCRIPTION_ACTIVE_NO_LINK,
    SUBSCRIPTION_HEADER,
    SUBSCRIPTION_LINK_ONLY,
    SUBSCRIPTION_LOAD_ERROR,
    SUBSCRIPTION_SHORT,
    SUBSCRIPTION_WITH_PLAN,
    SUPPORT_HEADING,
    TRIAL_ACTIVATED,
    TRIAL_ALREADY_USED,
    TRIAL_BUTTON,
    TRIAL_CREATED_FALLBACK,
    TRIAL_DISABLED,
    TRIAL_ERROR,
    WELCOME_PREFIX,
)

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

    async def _check_blocked(self, update: Update, user_id: int) -> bool:
        """Проверить блокировку. Возвращает True если заблокирован."""
        if await self.db.is_blocked(user_id):
            text = BLOCKED
            if update.message:
                await update.message.reply_text(text)
            elif update.callback_query:
                await update.callback_query.answer()
                await update.callback_query.edit_message_text(text)
            return True
        return False

    async def _check_subscription(self, update: Update, user_id: int, bot) -> bool:
        """Проверить подписку на канал. Возвращает True если нужно подписаться."""
        if not self.config.forced_channel_enabled:
            return False
        channel_id = self.config.forced_channel_id
        if not channel_id:
            return False
        try:
            member = await bot.get_chat_member(chat_id=channel_id, user_id=user_id)
            if member.status in ("left", "kicked"):
                username = self.config.forced_channel_username or ""
                link = f"https://t.me/{username.lstrip('@')}" if username else f"https://t.me/c/{str(channel_id).replace('-100', '')}"
                text = SUBSCRIBE_TEXT.format(link=link)
                keyboard = [[InlineKeyboardButton(SUBSCRIBE_BUTTON, url=link)], [InlineKeyboardButton(SUBSCRIBE_CHECK_BUTTON, callback_data="check_sub")]]
                if update.message:
                    await update.message.reply_text(text, parse_mode="Markdown", reply_markup=InlineKeyboardMarkup(keyboard))
                elif update.callback_query:
                    await update.callback_query.answer()
                    await update.callback_query.edit_message_text(text, parse_mode="Markdown", reply_markup=InlineKeyboardMarkup(keyboard))
                return True
        except Exception as e:
            logger.warning(f"Ошибка проверки подписки: {e}")
        return False

    def _get_main_reply_keyboard(self) -> ReplyKeyboardMarkup:
        """Постоянные кнопки главного меню (рядом с полем ввода)"""
        buttons = [
            [KeyboardButton(BTN_TARIFFS), KeyboardButton(BTN_MY_SUBSCRIPTION)],
        ]
        if self.config.main_menu_info:
            buttons.append([KeyboardButton(BTN_INFO)])
        if self.config.referral_days > 0:
            buttons.append([KeyboardButton(BTN_REFERRAL)])
        return ReplyKeyboardMarkup(
            buttons,
            resize_keyboard=True,
            one_time_keyboard=False,
        )

    def _build_main_menu(
        self, user_first_name: str, full_welcome: bool = True
    ) -> tuple[str, list[list[InlineKeyboardButton]]]:
        """Собрать текст и клавиатуру главного меню"""
        vpn = self.config.vpn_name
        text = WELCOME_PREFIX.format(vpn_name=vpn) + "\n\n"
        if self.config.welcome_message:
            welcome = self.config.welcome_message.replace("{name}", user_first_name)
            text += f"{welcome}\n\n"
        text += f"{self.config.keyboard_info}\n\n"
        if self.config.support_link:
            text += SUPPORT_HEADING + "\n\n"
        if full_welcome:
            text += TARIFFS_HEADING + "\n"
            for plan in self.config.plans:
                text += f"• *{plan.name}* — {plan.price:.0f} ₽\n"
            text += "\n" + CHOOSE_TARIFF
        else:
            text += CHOOSE_TARIFF
        keyboard: list[list[InlineKeyboardButton]] = []
        if self.config.support_link:
            link = self.config.support_link
            if link.startswith("t.me/"):
                link = "https://" + link
            elif not link.startswith("http"):
                link = "https://t.me/" + link.lstrip("@")
            keyboard.append([
                InlineKeyboardButton(
                    self.config.support_button_text,
                    url=link,
                )
            ])
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
                    TRIAL_BUTTON.format(days=self.config.trial_days),
                    callback_data="trial",
                )
            ])
        return text, keyboard

    async def start(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        """Обработка команды /start"""
        user = update.effective_user
        if not user:
            return
        if await self._check_blocked(update, user.id):
            return
        if await self._check_subscription(update, user.id, context.bot):
            return

        # Реферальная ссылка: /start ref_12345 — бонус за переход нового пользователя
        referrer_id = self._parse_referrer_from_start(context)
        if referrer_id and referrer_id != user.id and self.config.referral_days > 0:
            self._save_referrer(context, referrer_id)
            if await self.db.user_is_new(user.id):
                try:
                    extended = self.remnawave.extend_user_by_telegram_id(
                        referrer_id, self.config.referral_days
                    )
                    await self.db.add_referral(referrer_id, user.id, order_id=None)
                    if extended and self.config.referral_days > 0:
                        await context.bot.send_message(
                            chat_id=referrer_id,
                            text=REFERRAL_BONUS_EXTENDED.format(days=self.config.referral_days),
                        )
                    else:
                        await context.bot.send_message(
                            chat_id=referrer_id,
                            text=REFERRAL_BONUS_PENDING,
                        )
                except Exception as e:
                    logger.error(f"Ошибка реферального бонуса: {e}")

        welcome_text, keyboard = self._build_main_menu(user.first_name or "User", full_welcome=True)
        reply_markup = InlineKeyboardMarkup(keyboard)
        reply_kbd = self._get_main_reply_keyboard()

        await update.message.reply_text(
            welcome_text,
            parse_mode="Markdown",
            reply_markup=reply_markup,
        )
        # Reply-клавиатура (кнопки снизу) — минимальный текст
        await update.message.reply_text(" ", reply_markup=reply_kbd)

    async def buy_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Обработка нажатия на кнопку покупки"""
        query = update.callback_query
        await query.answer()
        user = query.from_user
        if user and (await self._check_blocked(update, user.id) or await self._check_subscription(update, user.id, context.bot)):
            return

        if not query.data or not query.data.startswith("buy:"):
            return

        plan_id = query.data.split(":")[1]
        plan = next((p for p in self.config.plans if p.id == plan_id), None)
        if not plan:
            await query.edit_message_text(PLAN_NOT_FOUND)
            return
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

            confirmation_url = payment.get("confirmation_url")
            if not confirmation_url:
                logger.error("Yookassa не вернула confirmation_url: %s", payment)
                await query.edit_message_text(PAYMENT_ERROR)
                return

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
                [InlineKeyboardButton(PAY_BUTTON, url=confirmation_url)],
                [InlineKeyboardButton(BACK_BUTTON, callback_data="back")],
            ]
            text = PAYMENT_CREATED.format(plan_name=plan.name, plan_price=plan.price)
            await query.edit_message_text(
                text,
                parse_mode="Markdown",
                reply_markup=InlineKeyboardMarkup(keyboard),
            )

        except Exception as e:
            logger.exception("Ошибка создания платежа: %s", e)
            await query.edit_message_text(PAYMENT_ERROR)

    async def my_subscription_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Показать информацию о подписке пользователя"""
        query = update.callback_query
        await query.answer()
        user = query.from_user
        if not user:
            return
        if await self._check_blocked(update, user.id) or await self._check_subscription(update, user.id, context.bot):
            return

        try:
            users = self.remnawave.get_user_by_telegram_id(user.id)

            if not users or (isinstance(users, list) and len(users) == 0):
                # Проверяем в наших заказах
                orders = await self.db.get_user_orders(user.id)
                active_orders = [o for o in orders if o.status == "succeeded" and o.short_uuid]

                if not active_orders:
                    keyboard = [[InlineKeyboardButton(BACK_BUTTON, callback_data="back")]]
                    await query.edit_message_text(
                        NO_SUBSCRIPTION,
                        reply_markup=InlineKeyboardMarkup(keyboard),
                    )
                    return

                # Берём последний активный заказ
                order = active_orders[0]
                subscription_url = get_subscription_url(
                    order.short_uuid, self.config.remnawave.subscription_base_url
                )

                text = SUBSCRIPTION_WITH_PLAN.format(
                    plan_name=order.plan_name,
                    subscription_url=subscription_url,
                )
            else:
                # Пользователь найден в Remnawave
                rw_user = users[0] if isinstance(users, list) else users
                short_uuid = extract_short_uuid(rw_user)
                if short_uuid:
                    subscription_url = get_subscription_url(
                        short_uuid, self.config.remnawave.subscription_base_url
                    )
                    text = SUBSCRIPTION_LINK_ONLY.format(subscription_url=subscription_url)
                else:
                    text = SUBSCRIPTION_ACTIVE_NO_LINK

            keyboard = [[InlineKeyboardButton(BACK_BUTTON, callback_data="back")]]
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
                sub_url = get_subscription_url(
                    order.short_uuid, self.config.remnawave.subscription_base_url
                )
                await query.edit_message_text(
                    SUBSCRIPTION_SHORT.format(subscription_url=sub_url),
                    parse_mode="Markdown",
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
                    ]),
                )
            else:
                await query.edit_message_text(
                    SUBSCRIPTION_LOAD_ERROR,
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
                    ]),
                )

    async def trial_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Обработка запроса пробного периода"""
        query = update.callback_query
        await query.answer()
        user = query.from_user
        if not user:
            return
        if await self._check_blocked(update, user.id) or await self._check_subscription(update, user.id, context.bot):
            return

        if self.config.trial_days <= 0:
            await query.edit_message_text(
                TRIAL_DISABLED,
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
                ]),
            )
            return

        used = await self.db.has_used_trial(user.id)
        if used:
            await query.edit_message_text(
                TRIAL_ALREADY_USED,
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
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

            short_uuid = extract_short_uuid(user_data)

            if short_uuid:
                sub_url = get_subscription_url(
                    short_uuid, self.config.remnawave.subscription_base_url
                )
                traffic_str = f"{self.config.trial_data_limit_gb} ГБ" if self.config.trial_data_limit_gb else "безлимит"
                text = TRIAL_ACTIVATED.format(
                    days=self.config.trial_days,
                    traffic=traffic_str,
                    subscription_url=sub_url,
                )
            else:
                text = TRIAL_CREATED_FALLBACK

            await query.edit_message_text(
                text,
                parse_mode="Markdown",
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
                ]),
            )
        except RemnawaveError as e:
            logger.exception("Ошибка создания trial: %s", e)
            await query.edit_message_text(
                TRIAL_ERROR,
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
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
        if await self._check_blocked(update, user.id) or await self._check_subscription(update, user.id, context.bot):
            return

        if self.config.referral_days <= 0:
            await query.edit_message_text(
                REFERRAL_DISABLED,
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
                ]),
            )
            return

        bot_info = await context.bot.get_me()
        bot_username = bot_info.username
        ref_link = f"https://t.me/{bot_username}?start=ref_{user.id}"
        text = REFERRAL_TEXT.format(
            referral_days=self.config.referral_days,
            ref_link=ref_link,
        )
        await query.edit_message_text(
            text,
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton(BACK_BUTTON, callback_data="back")]
            ]),
        )

    async def check_sub_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Проверка подписки — если подписался, показать меню"""
        query = update.callback_query
        await query.answer()
        user = query.from_user
        if not user:
            return
        if await self._check_subscription(update, user.id, context.bot):
            return
        welcome_text, keyboard = self._build_main_menu(user.first_name or "User", full_welcome=True)
        await query.edit_message_text(
            welcome_text,
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(keyboard),
        )
        await context.bot.send_message(
            chat_id=query.message.chat_id,
            text=" ",
            reply_markup=self._get_main_reply_keyboard(),
        )

    async def main_menu_message(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Обработка нажатия кнопок главного меню (ReplyKeyboard)"""
        text = (update.message and update.message.text) or ""
        user = update.effective_user
        if not user:
            return
        if await self._check_blocked(update, user.id):
            return
        if await self._check_subscription(update, user.id, context.bot):
            return
        if text == BTN_TARIFFS:
            welcome_text, keyboard = self._build_main_menu(
                user.first_name or "User", full_welcome=False
            )
            await update.message.reply_text(
                welcome_text,
                parse_mode="Markdown",
                reply_markup=InlineKeyboardMarkup(keyboard),
            )
        elif text == BTN_MY_SUBSCRIPTION:
            await self._handle_my_subscription_via_message(update, context)
        elif text == BTN_INFO:
            await self._handle_info_via_message(update, context)
        elif text == BTN_REFERRAL:
            await self._handle_referral_via_message(update, context)

    async def _handle_my_subscription_via_message(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Показать подписку (вызвано из ReplyKeyboard)"""
        user = update.effective_user
        if not user:
            return
        try:
            users = self.remnawave.get_user_by_telegram_id(user.id)
            if not users or (isinstance(users, list) and len(users) == 0):
                orders = await self.db.get_user_orders(user.id)
                active_orders = [o for o in orders if o.status == "succeeded" and o.short_uuid]
                if not active_orders:
                    await update.message.reply_text(
                        NO_SUBSCRIPTION,
                        reply_markup=self._get_main_reply_keyboard(),
                    )
                    return
                order = active_orders[0]
                subscription_url = get_subscription_url(
                    order.short_uuid, self.config.remnawave.subscription_base_url
                )
                msg = SUBSCRIPTION_WITH_PLAN.format(
                    plan_name=order.plan_name,
                    subscription_url=subscription_url,
                )
            else:
                rw_user = users[0] if isinstance(users, list) else users
                short_uuid = extract_short_uuid(rw_user)
                if short_uuid:
                    subscription_url = get_subscription_url(
                        short_uuid, self.config.remnawave.subscription_base_url
                    )
                    msg = SUBSCRIPTION_LINK_ONLY.format(subscription_url=subscription_url)
                else:
                    msg = SUBSCRIPTION_ACTIVE_NO_LINK
            await update.message.reply_text(
                msg,
                parse_mode="Markdown",
                reply_markup=self._get_main_reply_keyboard(),
            )
        except RemnawaveError as e:
            logger.error(f"Ошибка Remnawave: {e}")
            orders = await self.db.get_user_orders(user.id)
            active = [o for o in orders if o.status == "succeeded" and o.short_uuid]
            if active:
                sub_url = get_subscription_url(
                    active[0].short_uuid, self.config.remnawave.subscription_base_url
                )
                await update.message.reply_text(
                    SUBSCRIPTION_SHORT.format(subscription_url=sub_url),
                    parse_mode="Markdown",
                    reply_markup=self._get_main_reply_keyboard(),
                )
            else:
                await update.message.reply_text(
                    SUBSCRIPTION_LOAD_ERROR,
                    reply_markup=self._get_main_reply_keyboard(),
                )

    async def _handle_info_via_message(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Показать информацию (кнопка «ℹ️ Информация»)"""
        if not self.config.main_menu_info:
            await update.message.reply_text(
                INFO_NOT_CONFIGURED,
                reply_markup=self._get_main_reply_keyboard(),
            )
            return
        await update.message.reply_text(
            self.config.main_menu_info,
            reply_markup=self._get_main_reply_keyboard(),
        )

    async def _handle_referral_via_message(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Показать реферальную ссылку (вызвано из ReplyKeyboard)"""
        user = update.effective_user
        if not user:
            return
        if self.config.referral_days <= 0:
            await update.message.reply_text(
                REFERRAL_DISABLED,
                reply_markup=self._get_main_reply_keyboard(),
            )
            return
        bot_info = await context.bot.get_me()
        ref_link = f"https://t.me/{bot_info.username}?start=ref_{user.id}"
        text = REFERRAL_TEXT.format(
            referral_days=self.config.referral_days,
            ref_link=ref_link,
        )
        await update.message.reply_text(
            text,
            parse_mode="Markdown",
            reply_markup=self._get_main_reply_keyboard(),
        )

    async def back_callback(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Возврат в главное меню"""
        query = update.callback_query
        await query.answer()
        user = query.from_user
        if not user:
            return
        if await self._check_blocked(update, user.id) or await self._check_subscription(update, user.id, context.bot):
            return
        welcome_text, keyboard = self._build_main_menu(
            user.first_name or "User", full_welcome=False
        )

        await query.edit_message_text(
            welcome_text,
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(keyboard),
        )

    async def stats_command(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Команда /stats для администраторов"""
        user = update.effective_user
        if not user or user.id not in self.config.admin_ids:
            await update.message.reply_text(STATS_NO_ACCESS)
            return

        stats = await self.db.get_stats()
        text = STATS_TEXT.format(
            orders_succeeded=stats["orders_succeeded"],
            orders_pending=stats["orders_pending"],
            revenue=stats["revenue"],
            trial_users=stats["trial_users"],
            referrals=stats["referrals"],
        )
        await update.message.reply_text(text, parse_mode="Markdown")

    def build_application(self) -> Application:
        """Создать приложение бота"""
        app = Application.builder().token(self.config.bot_token).build()

        app.add_handler(CommandHandler("start", self.start))
        app.add_handler(CommandHandler("stats", self.stats_command))
        app.add_handler(CallbackQueryHandler(self.buy_callback, pattern="^buy:"))
        app.add_handler(
            CallbackQueryHandler(self.my_subscription_callback, pattern="^my_subscription$")
        )
        app.add_handler(CallbackQueryHandler(self.trial_callback, pattern="^trial$"))
        app.add_handler(CallbackQueryHandler(self.referral_callback, pattern="^referral$"))
        app.add_handler(CallbackQueryHandler(self.check_sub_callback, pattern="^check_sub$"))
        app.add_handler(CallbackQueryHandler(self.back_callback, pattern="^back$"))
        patterns = rf"^({BTN_TARIFFS}|{BTN_MY_SUBSCRIPTION}|{BTN_INFO}|{BTN_REFERRAL})$"
        app.add_handler(
            MessageHandler(filters.Regex(patterns), self.main_menu_message),
        )

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
