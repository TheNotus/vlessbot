"""Веб-админ-панель — только через SSH-туннель (127.0.0.1)"""
import asyncio
import logging
import os
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, Form, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
import uvicorn

from config import Config
from database import Database
from remnawave_client import RemnawaveClient, RemnawaveError

logger = logging.getLogger(__name__)

security = HTTPBasic()

# Глобальные (инициализируются при запуске)
config: Optional[Config] = None
db: Optional[Database] = None
remnawave: Optional[RemnawaveClient] = None


def verify_admin(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    """Проверка пароля админ-панели"""
    if not config or not config.admin_panel_password:
        raise HTTPException(status_code=503, detail="Админ-панель не настроена")
    import secrets
    correct = secrets.compare_digest(
        credentials.password.encode("utf-8"),
        config.admin_panel_password.encode("utf-8"),
    )
    if not correct:
        raise HTTPException(status_code=401, detail="Неверный пароль")
    return credentials.username


def load_env_vars() -> list[tuple[str, str, bool]]:
    """Загрузить переменные из .env (имя, значение, маскировать)"""
    base = Path(os.getcwd())
    env_path = base / ".env"
    if not env_path.exists():
        env_path = Path(__file__).parent / ".env"
    vars_list: list[tuple[str, str, bool]] = []
    if env_path.exists():
        content = env_path.read_text(encoding="utf-8", errors="replace")
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                secret_keys = ("TOKEN", "PASSWORD", "SECRET", "KEY")
                mask = any(s in key.upper() for s in secret_keys)
                vars_list.append((key, val, mask))
    # Добавить отсутствующие из .env.example
    example_path = Path(__file__).parent / ".env.example"
    if example_path.exists():
        content = example_path.read_text(encoding="utf-8", errors="replace")
        existing_keys = {v[0] for v in vars_list}
        for line in content.splitlines():
            if "=" in line and not line.strip().startswith("#"):
                key = line.split("=")[0].strip()
                if key and key not in existing_keys:
                    vars_list.append((key, "", any(s in key.upper() for s in ("TOKEN", "PASSWORD", "SECRET", "KEY"))))
    return vars_list


def save_env_var(key: str, value: str) -> bool:
    """Сохранить переменную в .env"""
    base = Path(os.getcwd())
    env_path = base / ".env"
    if not env_path.exists():
        env_path = Path(__file__).parent / ".env"
    if not env_path.exists():
        return False
    content = env_path.read_text(encoding="utf-8", errors="replace")
    lines = content.splitlines()
    found = False
    for i, line in enumerate(lines):
        if line.strip().startswith(key + "="):
            lines[i] = f'{key}="{value}"' if " " in value or not value else f"{key}={value}"
            found = True
            break
    if not found:
        lines.append(f'{key}="{value}"' if " " in value or not value else f"{key}={value}")
    env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


app = FastAPI(title="VPN Bot Admin", docs_url=None, redoc_url=None)

BASE_HTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>VPN Bot — Админ-панель</title>
<style>
*{box-sizing:border-box}body{font-family:system-ui,sans-serif;margin:0;padding:20px;background:#1a1a2e;color:#eee}
a{color:#4fc3f7}nav{margin-bottom:20px;border-bottom:1px solid #333;padding-bottom:10px}
nav a{margin-right:15px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #444;padding:8px;text-align:left}
th{background:#16213e}.btn{padding:6px 12px;border:none;border-radius:4px;cursor:pointer;text-decoration:none;display:inline-block}
.btn-danger{background:#e53935;color:#fff}.btn-success{background:#43a047;color:#fff}.msg{padding:10px;margin:10px 0;border-radius:4px}
.msg-ok{background:#1b5e20}.msg-err{background:#b71c1c}
</style>
</head>
<body>
<nav><a href="/">Дашборд</a> <a href="/users">Пользователи</a> <a href="/settings">Настройки</a></nav>
{{ content }}
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request, _: str = Depends(verify_admin)):
    """Главная страница — статистика"""
    if not db:
        return BASE_HTML.replace("{{ content }}", "<p>БД не инициализирована</p>")
    stats = await db.get_stats()
    content = f"""
    <h1>Дашборд</h1>
    <table>
    <tr><th>Метрика</th><th>Значение</th></tr>
    <tr><td>Оплаченных заказов</td><td>{stats['orders_succeeded']}</td></tr>
    <tr><td>Ожидают оплаты</td><td>{stats['orders_pending']}</td></tr>
    <tr><td>Выручка</td><td>{stats['revenue']:.0f} ₽</td></tr>
    <tr><td>Trial пользователей</td><td>{stats['trial_users']}</td></tr>
    <tr><td>Рефералов</td><td>{stats['referrals']}</td></tr>
    </table>
    <p><small>Доступ только через SSH-туннель: <code>ssh -L 8080:127.0.0.1:8080 user@server</code></small></p>
    """
    return BASE_HTML.replace("{{ content }}", content)


@app.get("/users", response_class=HTMLResponse)
async def users_page(request: Request, _: str = Depends(verify_admin)):
    """Список пользователей"""
    if not db:
        return BASE_HTML.replace("{{ content }}", "<p>БД не инициализирована</p>")
    users = await db.get_all_users_for_admin()
    rows = []
    for u in users:
        blocked = u.get("blocked", False)
        act = ""
        if not blocked:
            act = f'<a class="btn btn-danger" href="/users/block/{u["telegram_id"]}">Заблокировать</a> '
        else:
            act = f'<a class="btn btn-success" href="/users/unblock/{u["telegram_id"]}">Разблокировать</a> '
        if u.get("short_uuid"):
            act += f'<a class="btn btn-danger" href="/users/revoke/{u["telegram_id"]}" onclick="return confirm(\'Отозвать ключ?\')">Отозвать ключ</a>'
        rows.append(
            f"<tr><td>{u['telegram_id']}</td><td>{u['type']}</td><td>{u['plan']}</td>"
            f"<td>{u['status']}</td><td>{u.get('short_uuid') or '-'}</td>"
            f"<td>{'🚫 Заблокирован' if blocked else '✅'}</td><td>{act}</td></tr>"
        )
    content = """
    <h1>Пользователи</h1>
    <table>
    <tr><th>Telegram ID</th><th>Тип</th><th>Тариф</th><th>Статус</th><th>Short UUID</th><th>Блок</th><th>Действия</th></tr>
    """ + "\n".join(rows) + """
    </table>
    """
    msg = request.query_params.get("msg", "")
    if msg:
        content = f'<div class="msg msg-ok">{msg}</div>' + content
    return BASE_HTML.replace("{{ content }}", content)


@app.get("/users/block/{telegram_id}")
async def block_user(telegram_id: int, _: str = Depends(verify_admin)):
    if not db:
        raise HTTPException(503, "БД не инициализирована")
    await db.block_user(telegram_id)
    return RedirectResponse(url=f"/users?msg=Пользователь+{telegram_id}+заблокирован", status_code=302)


@app.get("/users/unblock/{telegram_id}")
async def unblock_user(telegram_id: int, _: str = Depends(verify_admin)):
    if not db:
        raise HTTPException(503, "БД не инициализирована")
    await db.unblock_user(telegram_id)
    return RedirectResponse(url=f"/users?msg=Пользователь+{telegram_id}+разблокирован", status_code=302)


@app.get("/users/revoke/{telegram_id}")
async def revoke_user(telegram_id: int, _: str = Depends(verify_admin)):
    if not db or not remnawave:
        raise HTTPException(503, "Сервисы не инициализированы")
    try:
        deleted, _ = remnawave.revoke_user_by_telegram_id(telegram_id)
        await db.block_user(telegram_id, "Ключ отозван")
        msg = f"Ключ отозван ({deleted} записей)"
    except RemnawaveError as e:
        msg = f"Ошибка Remnawave: {e}"
    return RedirectResponse(url=f"/users?msg={msg.replace(' ', '+')}", status_code=302)


@app.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request, _: str = Depends(verify_admin)):
    """Настройки из .env"""
    vars_list = load_env_vars()
    rows = []
    for key, val, mask in vars_list:
        display = "••••••" if mask and val else (val or "(не задано)")
        rows.append(f"<tr><td><code>{key}</code></td><td>{display}</td>"
                    f"<td><a href=\"/settings/edit/{key}\">Изменить</a></td></tr>")
    content = """
    <h1>Настройки (.env)</h1>
    <p><small>После изменения перезапустите сервис: <code>sudo systemctl restart vpn-bot</code></small></p>
    <table>
    <tr><th>Переменная</th><th>Значение</th><th></th></tr>
    """ + "\n".join(rows) + """
    </table>
    """
    msg = request.query_params.get("msg", "")
    if msg:
        content = f'<div class="msg msg-ok">{msg}</div>' + content
    return BASE_HTML.replace("{{ content }}", content)


@app.get("/settings/edit/{key}", response_class=HTMLResponse)
async def settings_edit_form(key: str, request: Request, _: str = Depends(verify_admin)):
    vars_list = load_env_vars()
    val = ""
    for k, v, _ in vars_list:
        if k == key:
            val = v
            break
    content = f"""
    <h1>Изменить {key}</h1>
    <form method="post" action="/settings/save">
    <input type="hidden" name="key" value="{key}">
    <input type="text" name="value" value="{val}" style="width:400px">
    <button type="submit" class="btn btn-success">Сохранить</button>
    </form>
    """
    return BASE_HTML.replace("{{ content }}", content)


@app.post("/settings/save")
async def settings_save(
    request: Request,
    key: str = Form(...),
    value: str = Form(""),
    _: str = Depends(verify_admin),
):
    save_env_var(key, value)
    return RedirectResponse(url=f"/settings?msg=Сохранено.+Перезапустите+сервис.", status_code=302)


def run_admin_panel(
    cfg: Config, db_instance: Database, rw_client: RemnawaveClient
) -> None:
    """Запустить админ-панель на 127.0.0.1 (только SSH-туннель). Блокирующая функция для потока."""
    global config, db, remnawave
    config = cfg
    db = db_instance
    remnawave = rw_client
    if not cfg.admin_panel_enabled or not cfg.admin_panel_password:
        logger.info("Админ-панель отключена или пароль не задан")
        return
    host = "127.0.0.1"
    port = cfg.admin_panel_port
    logger.info(f"Админ-панель: http://127.0.0.1:{port} (SSH: ssh -L {port}:127.0.0.1:{port} user@server)")
    uvicorn.run(app, host=host, port=port, log_level="warning")
