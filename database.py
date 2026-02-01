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
            await db.execute("""
                CREATE TABLE IF NOT EXISTS blocked_users (
                    telegram_id INTEGER PRIMARY KEY,
                    reason TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
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

    async def user_is_new(self, telegram_id: int) -> bool:
        """Проверить, был ли пользователь раньше в базе (заказы или trial)"""
        async with aiosqlite.connect(self.db_path) as db:
            async with db.execute(
                "SELECT 1 FROM orders WHERE telegram_id = ? LIMIT 1",
                (telegram_id,),
            ) as cur:
                if await cur.fetchone():
                    return False
            async with db.execute(
                "SELECT 1 FROM trial_users WHERE telegram_id = ? LIMIT 1",
                (telegram_id,),
            ) as cur:
                if await cur.fetchone():
                    return False
            async with db.execute(
                "SELECT 1 FROM referrals WHERE referral_id = ? LIMIT 1",
                (telegram_id,),
            ) as cur:
                if await cur.fetchone():
                    return False  # уже приходил по реф-ссылке
        return True

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

    async def get_stats(self) -> dict:
        """Получить статистику для админки"""
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            stats: dict = {}
            async with db.execute(
                "SELECT COUNT(*) as cnt FROM orders WHERE status = 'succeeded'"
            ) as cur:
                row = await cur.fetchone()
                stats["orders_succeeded"] = int(row["cnt"]) if row else 0
            async with db.execute(
                "SELECT COALESCE(SUM(amount), 0) as total FROM orders WHERE status = 'succeeded'"
            ) as cur:
                row = await cur.fetchone()
                stats["revenue"] = float(row["total"]) if row and row["total"] is not None else 0.0
            async with db.execute("SELECT COUNT(*) as cnt FROM trial_users") as cur:
                row = await cur.fetchone()
                stats["trial_users"] = int(row["cnt"]) if row else 0
            async with db.execute("SELECT COUNT(*) as cnt FROM referrals") as cur:
                row = await cur.fetchone()
                stats["referrals"] = int(row["cnt"]) if row else 0
            async with db.execute(
                "SELECT COUNT(*) as cnt FROM orders WHERE status = 'pending'"
            ) as cur:
                row = await cur.fetchone()
                stats["orders_pending"] = int(row["cnt"]) if row else 0
            return stats

    async def get_stats_chart_data(self, days: int = 14) -> dict:
        """Данные для графика: покупки и выручка по дням за последние N дней"""
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            result: dict = {"labels": [], "orders": [], "revenue": []}
            async with db.execute(
                """
                SELECT date(created_at) as d, COUNT(*) as cnt, COALESCE(SUM(amount), 0) as rev
                FROM orders
                WHERE status = 'succeeded' AND created_at >= date('now', ?)
                GROUP BY date(created_at)
                ORDER BY d
                """,
                (f"-{days} days",),
            ) as cur:
                rows = await cur.fetchall()
                by_date = {r["d"]: {"orders": r["cnt"], "revenue": float(r["rev"])} for r in rows}
            from datetime import datetime, timedelta
            for i in range(days - 1, -1, -1):
                d = (datetime.utcnow() - timedelta(days=i)).strftime("%Y-%m-%d")
                result["labels"].append(d[5:] if len(d) >= 5 else d)
                result["orders"].append(by_date.get(d, {}).get("orders", 0))
                result["revenue"].append(by_date.get(d, {}).get("revenue", 0))
            return result

    async def is_blocked(self, telegram_id: int) -> bool:
        """Проверить, заблокирован ли пользователь"""
        async with aiosqlite.connect(self.db_path) as db:
            async with db.execute(
                "SELECT 1 FROM blocked_users WHERE telegram_id = ?",
                (telegram_id,),
            ) as cur:
                return await cur.fetchone() is not None

    async def block_user(self, telegram_id: int, reason: Optional[str] = None) -> bool:
        """Заблокировать пользователя"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                try:
                    await db.execute(
                        "INSERT OR REPLACE INTO blocked_users (telegram_id, reason) VALUES (?, ?)",
                        (telegram_id, reason or ""),
                    )
                    await db.commit()
                    return True
                except Exception:
                    return False

    async def unblock_user(self, telegram_id: int) -> bool:
        """Разблокировать пользователя"""
        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                await db.execute("DELETE FROM blocked_users WHERE telegram_id = ?", (telegram_id,))
                await db.commit()
                return db.total_changes > 0

    async def get_all_users_for_admin(self) -> list[dict]:
        """Список пользователей для админ-панели (orders + trial)"""
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            users_map: dict[int, dict] = {}
            async with db.execute(
                """SELECT telegram_id, plan_name, status, short_uuid, username, created_at
                   FROM orders ORDER BY created_at DESC"""
            ) as cur:
                async for row in cur:
                    tid = row["telegram_id"]
                    if tid not in users_map:
                        users_map[tid] = {
                            "telegram_id": tid,
                            "type": "order",
                            "plan": row["plan_name"],
                            "status": row["status"],
                            "short_uuid": row["short_uuid"],
                            "username": row["username"],
                            "created_at": row["created_at"],
                        }
            async with db.execute("SELECT telegram_id, created_at FROM trial_users") as cur:
                async for row in cur:
                    tid = row["telegram_id"]
                    if tid not in users_map:
                        users_map[tid] = {
                            "telegram_id": tid,
                            "type": "trial",
                            "plan": "Trial",
                            "status": "trial",
                            "short_uuid": None,
                            "username": None,
                            "created_at": row["created_at"],
                        }
            async with db.execute("SELECT telegram_id FROM blocked_users") as cur:
                async for row in cur:
                    tid = row["telegram_id"]
                    if tid in users_map:
                        users_map[tid]["blocked"] = True
                    else:
                        users_map[tid] = {
                            "telegram_id": tid,
                            "type": "blocked",
                            "plan": "-",
                            "status": "blocked",
                            "short_uuid": None,
                            "username": None,
                            "created_at": None,
                            "blocked": True,
                        }
            for u in users_map.values():
                if "blocked" not in u:
                    u["blocked"] = False
            return sorted(users_map.values(), key=lambda u: (u.get("created_at") or "") or "0", reverse=True)

    async def get_order_referrer(self, payment_id: str) -> Optional[int]:
        """Получить referrer_id по payment_id"""
        order = await self.get_order_by_payment(payment_id)
        return order.referrer_id if order else None

    def _get_referrer_from_row(self, row: aiosqlite.Row) -> Optional[int]:
        """Безопасно извлечь referrer_id из строки (колонка может отсутствовать)"""
        try:
            val = row["referrer_id"]
            return int(val) if val is not None else None
        except (KeyError, ValueError, TypeError):
            return None

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
            referrer_id=self._get_referrer_from_row(row),
        )
