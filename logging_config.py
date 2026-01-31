"""Настройка логирования для VPN Bot"""
import logging
import os
import sys


def setup_logging(log_dir: str = None) -> None:
    """
    Настроить логирование в файл и консоль.
    log_dir или VPN_BOT_LOG_DIR, по умолчанию ./logs
    """
    log_dir = log_dir or os.getenv("VPN_BOT_LOG_DIR") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "logs"
    )
    os.makedirs(log_dir, exist_ok=True)

    log_file = os.path.join(log_dir, "vpn-bot.log")

    # Формат с деталями для отладки
    formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    root = logging.getLogger()
    root.setLevel(logging.INFO)

    # Файл — все логи
    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(formatter)
    root.addHandler(fh)

    # Консоль — INFO и выше
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(formatter)
    root.addHandler(ch)

    # Уменьшить шум от библиотек
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("telegram").setLevel(logging.WARNING)
