"""База данных для хранения заказов и привязки пользователей"""
import asyncio
from dataclasses import dataclass
from datetime import datetime
from typing import Optional

import aiosqlite


@dataclass
class Order:
    """Заказ на покупку VPN"""
    id: int
    payment_id: str
    telegram_id: int
    plan_id: str
    plan_name: str
    amount: float
    status: str  # pending, succeeded, failed, refunded
    created_at: datetime
    completed_at: Optional[datetime]
    username: Optional[str]  # Username в Remnawave
    short_uuid: Optional[str]  # Short UUID для подписки
    referrer_id: Optional[int] = None


class Database:
    """Работа с SQLite базой данных"""

    def __init__(self, db_path: str = "vpn_bot.db"):
        self.db_path = db_path
        self._lock = asyncio.Lock()

    async def init(self) -> None:
        """Инициализировать таблицы"""
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("""
                CREATE TABLE IF NOT EXISTS orders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    payment_id TEXT UNIQUE NOT NULL,
                    telegram_id INTEGER NOT NULL,
                    plan_id TEXT NOT NULL,
                    plan_name TEXT NOT NULL,
                    amount REAL NOT NULL,
                    status TEXT DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP,
                    username TEXT,
                    short_uuid TEXT,
                    referrer_id INTEGER
                )
            """)
            await db.execute("""
                CREATE TABLE IF NOT EXISTS trial_users (
                    telegram_id INTEGER PRIMARY KEY,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            await db.execute("""
                CREATE TABLE IF NOT EXISTS referrals (
                    referrer_id INTEGER NOT NULL,
                    referral_id INTEGER NOT NULL,
                    order_id INTEGER,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (referrer_id, referral_id)
                )
            """)
            await db.execute("""
                CREATE INDEX IF NOT EXISTS idx_orders_payment ON orders(payment_id)
            """)
            await db.execute("""
                CREATE INDEX IF NOT EXISTS idx_orders_telegram ON orders(telegram_id)
            """)
            try:
                await db.execute("ALTER TABLE orders ADD COLUMN referrer_id INTEGER")
            except Exception:
                pass  # Колонка уже существует
            await db.commit()

    async def create_order(
        self,
        payment_id: str,
        telegram_id: int,
        plan_id: str,
        plan_name: str,
        amount: float,
        referrer_id: Optional[int] = None,
    ) -> int:
        """Создать заказ"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                cursor = await db.execute(
                    """
                    INSERT INTO orders (payment_id, telegram_id, plan_id, plan_name, amount, status, referrer_id)
                    VALUES (?, ?, ?, ?, ?, 'pending', ?)
                    """,
                    (payment_id, telegram_id, plan_id, plan_name, amount, referrer_id),
                )
                await db.commit()
                return cursor.lastrowid or 0

    async def get_order_by_payment(self, payment_id: str) -> Optional[Order]:
        """Получить заказ по ID платежа"""
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM orders WHERE payment_id = ?",
                (payment_id,),
            ) as cursor:
                row = await cursor.fetchone()
                if row:
                    return self._row_to_order(row)
        return None

    async def update_order_success(
        self,
        payment_id: str,
        username: str,
        short_uuid: str,
    ) -> bool:
        """Обновить заказ при успешной оплате"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                await db.execute(
                    """
                    UPDATE orders SET status = 'succeeded', completed_at = ?,
                    username = ?, short_uuid = ? WHERE payment_id = ?
                    """,
                    (datetime.utcnow().isoformat(), username, short_uuid, payment_id),
                )
                await db.commit()
                return db.total_changes > 0

    async def update_order_status(self, payment_id: str, status: str) -> bool:
        """Обновить статус заказа"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                completed_at = (
                    datetime.utcnow().isoformat() if status == "succeeded" else None
                )
                await db.execute(
                    """
                    UPDATE orders SET status = ?, completed_at = ?
                    WHERE payment_id = ?
                    """,
                    (status, completed_at, payment_id),
                )
                await db.commit()
                return db.total_changes > 0

    async def get_user_orders(self, telegram_id: int) -> list[Order]:
        """Получить заказы пользователя"""
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM orders WHERE telegram_id = ? ORDER BY created_at DESC",
                (telegram_id,),
            ) as cursor:
                rows = await cursor.fetchall()
                return [self._row_to_order(row) for row in rows]

    async def has_used_trial(self, telegram_id: int) -> bool:
        """Проверить, использовал ли пользователь пробный период"""
        async with aiosqlite.connect(self.db_path) as db:
            async with db.execute(
                "SELECT 1 FROM trial_users WHERE telegram_id = ?",
                (telegram_id,),
            ) as cursor:
                return await cursor.fetchone() is not None

    async def add_trial_user(self, telegram_id: int) -> bool:
        """Записать использование пробного периода"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                try:
                    await db.execute(
                        "INSERT INTO trial_users (telegram_id) VALUES (?)",
                        (telegram_id,),
                    )
                    await db.commit()
                    return True
                except Exception:
                    return False

    async def add_referral(self, referrer_id: int, referral_id: int, order_id: Optional[int] = None) -> bool:
        """Записать реферала"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                try:
                    await db.execute(
                        """
                        INSERT OR REPLACE INTO referrals (referrer_id, referral_id, order_id)
                        VALUES (?, ?, ?)
                        """,
                        (referrer_id, referral_id, order_id),
                    )
                    await db.commit()
                    return True
                except Exception:
                    return False

    async def get_order_referrer(self, payment_id: str) -> Optional[int]:
        """Получить referrer_id по payment_id"""
        order = await self.get_order_by_payment(payment_id)
        return order.referrer_id if order else None

    def _row_to_order(self, row: aiosqlite.Row) -> Order:
        """Преобразовать строку в Order"""
        return Order(
            id=row["id"],
            payment_id=row["payment_id"],
            telegram_id=row["telegram_id"],
            plan_id=row["plan_id"],
            plan_name=row["plan_name"],
            amount=row["amount"],
            status=row["status"],
            created_at=datetime.fromisoformat(row["created_at"])
            if row["created_at"] else datetime.utcnow(),
            completed_at=datetime.fromisoformat(row["completed_at"])
            if row["completed_at"] else None,
            username=row["username"],
            short_uuid=row["short_uuid"],
            referrer_id=row["referrer_id"] if "referrer_id" in row.keys() and row["referrer_id"] else None,
        )
