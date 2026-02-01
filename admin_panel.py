"""Веб-админ-панель бота — стиль Remnawave"""
import html
import json
import logging
import os
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
import uvicorn

from config import Config
from database import Database
from remnawave_client import RemnawaveClient, RemnawaveError

logger = logging.getLogger(__name__)

security = HTTPBasic()

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
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPN Bot — Админ</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
*{box-sizing:border-box}
:root{--bg:#0f0f14;--card:#16161d;--border:#2a2a35;--text:#e6e6ea;--muted:#8a8a96;--accent:#00d4aa;--accent-hover:#00b894;--danger:#e74c3c;--success:#27ae60}
body{font-family:'Inter',system-ui,-apple-system,sans-serif;margin:0;background:var(--bg);color:var(--text);min-height:100vh}
a{color:var(--accent);text-decoration:none}
a:hover{color:var(--accent-hover)}
nav{display:flex;gap:1rem;padding:1rem 1.5rem;border-bottom:1px solid var(--border);background:var(--card)}
nav a{padding:0.5rem 0;font-weight:500}
main{padding:1.5rem;max-width:1200px;margin:0 auto}
h1{font-size:1.5rem;margin:0 0 1rem;font-weight:600}
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1rem 1.25rem;margin-bottom:1rem}
.card-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:1rem;margin-bottom:1.5rem}
.card-stat .label{font-size:0.8rem;color:var(--muted);text-transform:uppercase;letter-spacing:0.05em}
.card-stat .value{font-size:1.5rem;font-weight:600;margin-top:0.25rem}
table{border-collapse:collapse;width:100%;font-size:0.9rem}
th,td{padding:0.75rem 1rem;text-align:left;border-bottom:1px solid var(--border)}
th{color:var(--muted);font-weight:500;font-size:0.8rem;text-transform:uppercase}
tr:hover td{background:rgba(0,212,170,0.05)}
.btn{padding:0.5rem 1rem;border:none;border-radius:6px;cursor:pointer;font-size:0.875rem;font-weight:500;display:inline-flex;align-items:center;gap:0.5rem}
.btn-primary{background:var(--accent);color:var(--bg)}
.btn-primary:hover{background:var(--accent-hover);color:var(--bg)}
.btn-danger{background:var(--danger);color:#fff}
.btn-danger:hover{opacity:0.9}
.btn-success{background:var(--success);color:#fff}
.btn-outline{border:1px solid var(--border);background:transparent;color:var(--text)}
.btn-outline:hover{background:var(--border)}
.btn-sm{padding:0.35rem 0.75rem;font-size:0.8rem}
.input{width:100%;max-width:400px;padding:0.5rem 0.75rem;border:1px solid var(--border);border-radius:6px;background:var(--bg);color:var(--text);font-size:0.9rem}
.input:focus{outline:none;border-color:var(--accent)}
.msg{padding:0.75rem 1rem;border-radius:6px;margin-bottom:1rem}
.msg-ok{background:rgba(39,174,96,0.2);border:1px solid var(--success)}
.setting-row{display:flex;align-items:center;gap:1rem;padding:0.75rem 0;border-bottom:1px solid var(--border);flex-wrap:wrap}
.setting-row:last-child{border-bottom:none}
.setting-key{font-family:monospace;font-size:0.85rem;min-width:200px}
.setting-val{flex:1;min-width:200px}
.chart-wrap{height:280px;margin-top:1rem}
</style>
</head>
<body>
<nav><a href="/">Дашборд</a> <a href="/users">Пользователи</a> <a href="/settings">Настройки</a></nav>
<main>{{ content }}</main>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request, _: str = Depends(verify_admin)):
    """Главная страница — статистика и график"""
    if not db:
        return BASE_HTML.replace("{{ content }}", "<p>БД не инициализирована</p>")
    stats = await db.get_stats()
    chart_data = await db.get_stats_chart_data(14)
    chart_labels = json.dumps(chart_data["labels"])
    chart_orders = json.dumps(chart_data["orders"])
    chart_revenue = json.dumps(chart_data["revenue"])
    content = f"""
    <h1>Дашборд</h1>
    <div class="card-grid">
    <div class="card card-stat"><div class="label">Оплаченных заказов</div><div class="value">{stats['orders_succeeded']}</div></div>
    <div class="card card-stat"><div class="label">Ожидают оплаты</div><div class="value">{stats['orders_pending']}</div></div>
    <div class="card card-stat"><div class="label">Выручка</div><div class="value">{stats['revenue']:.0f} ₽</div></div>
    <div class="card card-stat"><div class="label">Trial</div><div class="value">{stats['trial_users']}</div></div>
    <div class="card card-stat"><div class="label">Рефералов</div><div class="value">{stats['referrals']}</div></div>
    </div>
    <div class="card">
    <h2 style="font-size:1rem;margin:0 0 0.5rem">Покупки и выручка (14 дней)</h2>
    <div class="chart-wrap"><canvas id="chart"></canvas></div>
    </div>
    <script>
    new Chart(document.getElementById('chart'), {{
      type: 'bar',
      data: {{
        labels: {chart_labels},
        datasets: [
          {{ label: 'Покупки', data: {chart_orders}, backgroundColor: 'rgba(0,212,170,0.6)' }},
          {{ label: 'Выручка, ₽', data: {chart_revenue}, backgroundColor: 'rgba(0,212,170,0.3)', yAxisID: 'y1' }}
        ]
      }},
      options: {{
        responsive: true,
        maintainAspectRatio: false,
        plugins: {{ legend: {{ labels: {{ color: '#e6e6ea' }} }} }},
        scales: {{
          x: {{ ticks: {{ color: '#8a8a96', maxRotation: 45 }} }},
          y: {{ ticks: {{ color: '#8a8a96' }}, grid: {{ color: '#2a2a35' }} }},
          y1: {{ position: 'right', ticks: {{ color: '#8a8a96' }}, grid: {{ drawOnChartArea: false }} }}
        }}
      }}
    }});
    </script>
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
            act = f'<a class="btn btn-danger btn-sm" href="/users/block/{u["telegram_id"]}">Заблокировать</a> '
        else:
            act = f'<a class="btn btn-success btn-sm" href="/users/unblock/{u["telegram_id"]}">Разблокировать</a> '
        if u.get("short_uuid"):
            act += f'<a class="btn btn-danger btn-sm" href="/users/revoke/{u["telegram_id"]}" onclick="return confirm(\'Отозвать ключ?\')">Отозвать</a>'
        rows.append(
            f"<tr><td>{u['telegram_id']}</td><td>{u['type']}</td><td>{u['plan']}</td>"
            f"<td>{u['status']}</td><td><code>{u.get('short_uuid') or '-'}</code></td>"
            f"<td>{'🚫' if blocked else '✅'}</td><td>{act}</td></tr>"
        )
    content = '<h1>Пользователи</h1><div class="card"><table>' + """
    <tr><th>Telegram ID</th><th>Тип</th><th>Тариф</th><th>Статус</th><th>Short UUID</th><th></th><th>Действия</th></tr>
    """ + "\n".join(rows) + "</table></div>"
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
    """Настройки из .env — inline-редактирование"""
    vars_list = load_env_vars()
    rows = []
    for key, val, mask in vars_list:
        input_type = "password" if mask and val else "text"
        placeholder = "••••••" if mask and val else "(не задано)"
        input_val = val if not (mask and val) else ""
        rows.append(f'''
    <div class="setting-row">
      <span class="setting-key"><code>{html.escape(key)}</code></span>
      <form method="post" action="/settings/save" class="setting-val" style="display:flex;gap:0.5rem;align-items:center;flex:1;min-width:0">
        <input type="hidden" name="key" value="{html.escape(key)}">
        <input type="{input_type}" name="value" value="{html.escape(input_val)}" placeholder="{html.escape(placeholder)}" class="input" style="flex:1;min-width:0">
        <button type="submit" class="btn btn-primary btn-sm">Сохранить</button>
      </form>
    </div>''')
    content = """
    <h1>Настройки (.env)</h1>
    <div style="margin-bottom:1rem;display:flex;align-items:center;gap:1rem;flex-wrap:wrap">
      <button class="btn btn-outline" id="restartBtn" title="Скопировать команду">
        Перезапустить сервис
      </button>
      <span id="restartMsg" style="color:var(--success);font-size:0.875rem;display:none">Скопировано</span>
    </div>
    <div class="card">
    """ + "\n".join(rows) + """
    </div>
    <script>
    document.getElementById('restartBtn').onclick = function() {
      navigator.clipboard.writeText('sudo systemctl restart vpn-bot').then(() => {
        var m = document.getElementById('restartMsg');
        m.style.display = 'inline';
        setTimeout(() => m.style.display = 'none', 2000);
      });
    };
    </script>
    """
    msg = request.query_params.get("msg", "")
    if msg:
        content = f'<div class="msg msg-ok">{msg}</div>' + content
    return BASE_HTML.replace("{{ content }}", content)


@app.post("/settings/save")
async def settings_save(
    request: Request,
    key: str = Form(...),
    value: str = Form(""),
    _: str = Depends(verify_admin),
):
    secret_keys = ("TOKEN", "PASSWORD", "SECRET", "KEY")
    is_secret = any(s in key.upper() for s in secret_keys)
    if is_secret and not value.strip():
        return RedirectResponse(url="/settings?msg=Пропущено+(пустое+значение+для+секрета).", status_code=302)
    save_env_var(key, value)
    return RedirectResponse(url=f"/settings?msg=Сохранено.+Нажмите+%C2%ABПерезапустить+сервис%C2%BB.", status_code=302)


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
