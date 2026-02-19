@echo off
REM VPN Bot - Установка (Windows)
REM Запуск: install.bat

cd /d "%~dp0"

echo ==========================================
echo   VPN Bot - Установка
echo ==========================================
echo.

where python >nul 2>nul
if %errorlevel% neq 0 (
    echo Ошибка: Python не найден. Установите Python 3.10+
    pause
    exit /b 1
)
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>nul
if %errorlevel% neq 0 (
    echo Ошибка: Требуется Python 3.10 или выше. Текущая версия:
    python --version 2>nul
    pause
    exit /b 1
)

echo Установка зависимостей...
python -m pip install --upgrade pip -q
python -m pip install -r requirements.txt -q
echo Зависимости установлены.

if not exist .env (
    echo.
    echo Создание .env...
    copy .env.example .env
    echo Файл .env создан.
    echo.
    echo ВАЖНО: Отредактируйте .env и укажите ваши данные.
) else (
    echo Файл .env уже существует.
)

echo.
echo Инициализация базы данных...
python -c "import asyncio; from database import Database; asyncio.run(Database().init()); print('OK')"
echo.

echo ==========================================
echo   Установка завершена!
echo ==========================================
echo.
echo Следующие шаги:
echo   1. Отредактируйте .env
echo   2. Запуск: python main.py
echo.
pause
