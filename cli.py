#!/usr/bin/env python3
"""
Управление VPN Bot через консоль.
Запуск: vlessbot  или  python cli.py
Меню: перезагрузка бота, просмотр логов, полное удаление бота (без панели).
"""
import os
import subprocess
import sys

INSTALL_DIR = os.getenv("VPN_BOT_INSTALL_DIR", "/opt/vpn-bot")
SERVICE_NAME = "vpn-bot"
LOG_DIR = os.getenv("VPN_BOT_LOG_DIR", "/var/log/vpn-bot")
BOT_USER = os.getenv("VPN_BOT_USER", "vpnbot")


def run(cmd: list[str], capture: bool = False) -> int:
    """Выполнить команду. Если capture=False — вывод в консоль."""
    try:
        if capture:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if r.stdout:
                print(r.stdout)
            if r.stderr:
                print(r.stderr, file=sys.stderr)
            return r.returncode
        return subprocess.run(cmd, timeout=60).returncode
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        return 1


def is_root() -> bool:
    return os.geteuid() == 0


def menu_restart():
    """Перезапустить сервис бота"""
    if not is_root():
        print("Для перезапуска выполните: sudo vlessbot")
        print("Или: sudo systemctl restart vpn-bot")
        return
    print("\nПерезапуск бота...")
    code = run(["systemctl", "restart", SERVICE_NAME])
    if code == 0:
        print("Бот перезапущен.")
    else:
        print("Не удалось перезапустить. Проверьте: sudo systemctl status vpn-bot")


def menu_logs_last():
    """Последние строки логов"""
    n = 80
    code = run(["journalctl", "-u", SERVICE_NAME, "-n", str(n), "--no-pager"])
    if code != 0:
        print("Не удалось прочитать логи. Запущен ли сервис?")


def menu_logs_follow():
    """Следить за логами (Ctrl+C — выход в меню)"""
    print("Слежение за логами (Ctrl+C — выход)...\n")
    try:
        subprocess.run(["journalctl", "-u", SERVICE_NAME, "-f", "--no-pager"])
    except KeyboardInterrupt:
        print("\n")


def menu_uninstall():
    """Полное удаление бота с сервера (данные и сервис). Панель Remnawave не трогаем."""
    if not is_root():
        print("Удаление возможно только с правами root: sudo vlessbot")
        return
    print("\n⚠️  Полное удаление VPN Bot:")
    print("   • Будет остановлен и удалён сервис vpn-bot")
    print("   • Будет удалена директория со всеми данными (код, .env, БД)")
    print("   • Панель Remnawave и ноды не затрагиваются")
    confirm = input("Введите 'yes' для подтверждения удаления: ").strip()
    if confirm != "yes":
        print("Отменено.")
        return
    steps = [
        ("Остановка сервиса", ["systemctl", "stop", SERVICE_NAME]),
        ("Отключение автозапуска", ["systemctl", "disable", SERVICE_NAME]),
        ("Удаление unit systemd", ["rm", "-f", f"/etc/systemd/system/{SERVICE_NAME}.service"]),
        ("Перезагрузка systemd", ["systemctl", "daemon-reload"]),
        ("Удаление cron", ["crontab", "-u", BOT_USER, "-r"] if os.path.exists("/usr/bin/crontab") else None),
        ("Удаление sudoers", ["rm", "-f", "/etc/sudoers.d/vpn-bot-restart"]),
        ("Удаление logrotate", ["rm", "-f", "/etc/logrotate.d/vpn-bot"]),
        ("Удаление директории бота", ["rm", "-rf", INSTALL_DIR]),
        ("Удаление команды vlessbot", ["rm", "-f", "/usr/local/bin/vlessbot"]),
    ]
    for label, cmd in steps:
        if cmd is None:
            continue
        print(f"  {label}...", end=" ")
        code = run(cmd, capture=True)
        if code == 0 or "No crontab" in str(cmd):
            print("OK")
        else:
            print("(пропуск или ошибка)")
    print("\nVPN Bot полностью удалён с сервера. Панель Remnawave не затронута.")


def main_menu():
    """Главное меню с навигацией по цифрам"""
    while True:
        print()
        print("=" * 50)
        print("  VPN BOT — Управление")
        print("=" * 50)
        print("  1) Перезапустить бота")
        print("  2) Показать последние логи бота")
        print("  3) Следить за логами (Ctrl+C — выход)")
        print("  4) Полное удаление бота с сервера (без панели)")
        print("  0) Выход")
        print("=" * 50)
        try:
            choice = input("Выберите действие (0–4): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nВыход.")
            break
        if choice == "0":
            print("Выход.")
            break
        if choice == "1":
            menu_restart()
        elif choice == "2":
            menu_logs_last()
        elif choice == "3":
            menu_logs_follow()
        elif choice == "4":
            menu_uninstall()
        else:
            print("Неверный выбор. Введите 0, 1, 2, 3 или 4.")


if __name__ == "__main__":
    # Если передан аргумент (например для совместимости), всё равно показываем меню
    main_menu()
