#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоматизированное развёртывание приложения для проверки
# лабораторных работ (сервер SoftWLC)
# Целевая ОС: Ubuntu Server 22.04 LTS
#
# Скрипт выполняет:
#   1) установку Node.js 20 LTS из репозитория NodeSource;
#   2) копирование приложения в каталог /opt/labcheck;
#   3) установку npm-зависимостей (express, bcrypt,
#      express-session, mysql2);
#   4) создание systemd-службы labcheck для автозапуска;
#   5) запуск службы и проверку доступности порта 9090.
#
# Использование:
#   Вариант 1 (приложение загружается из репозитория автоматически):
#     sudo ./install_labcheck_server.sh
#   Вариант 2 (приложение из локального файла):
#     sudo ./install_labcheck_server.sh /путь/к/test.js
# ============================================================

# URL приложения в репозитории (используется, если путь не передан).
# ВНИМАНИЕ: подставьте адрес вашего репозитория.
APP_URL="${APP_URL:-https://raw.githubusercontent.com/weesqy/softwlc-autodeploy/main/server/app.js}"

APP_SOURCE="${1:-}"
APP_DIR="/opt/labcheck"
APP_PORT=9090
SERVICE_NAME="labcheck"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

# --- 1. Предварительные проверки -----------------------------------
[[ $EUID -eq 0 ]] || fail "Запустите скрипт с правами суперпользователя: sudo $0"

# Приложение обращается к MySQL на localhost — убедимся, что СУБД установлена
systemctl is-active --quiet mysql 2>/dev/null \
    || log "[ВНИМАНИЕ] Служба MySQL не активна. Приложение требует установленного SoftWLC."

# --- 2. Установка Node.js 20 LTS ------------------------------------
if command -v node >/dev/null 2>&1 && [[ "$(node -v | cut -d. -f1 | tr -d v)" -ge 20 ]]; then
    log "Node.js $(node -v) уже установлен, пропуск."
else
    log "Установка Node.js 20 LTS из репозитория NodeSource..."
    apt-get update -y
    apt-get install -y curl wget ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
log "Версии: node $(node -v), npm $(npm -v)"

# --- 3. Размещение приложения ---------------------------------------
mkdir -p "$APP_DIR"
if [[ -n "$APP_SOURCE" ]]; then
    [[ -f "$APP_SOURCE" ]] || fail "Файл приложения не найден: $APP_SOURCE"
    log "Копирование приложения из ${APP_SOURCE} в ${APP_DIR}..."
    cp "$APP_SOURCE" "$APP_DIR/app.js"
else
    log "Загрузка приложения из репозитория: ${APP_URL}"
    [[ "$APP_URL" != *"<логин>"* ]] || fail "В скрипте не задан адрес репозитория.
Отредактируйте переменную APP_URL или передайте локальный путь аргументом."
    wget -O "$APP_DIR/app.js" "$APP_URL" \
        || fail "Не удалось загрузить приложение из репозитория."
fi

# --- 4. Установка зависимостей ---------------------------------------
log "Установка npm-зависимостей..."
cd "$APP_DIR"
[[ -f package.json ]] || npm init -y >/dev/null
npm install express bcrypt express-session mysql2

# --- 5. Создание systemd-службы --------------------------------------
log "Создание службы systemd ${SERVICE_NAME}..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Приложение проверки лабораторных работ SoftWLC
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=$(command -v node) ${APP_DIR}/app.js
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 6. Проверка результата -------------------------------------------
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "  [OK] Служба ${SERVICE_NAME} запущена."
else
    fail "Служба ${SERVICE_NAME} не запустилась. Журнал: journalctl -u ${SERVICE_NAME} -n 50"
fi

if ss -tln | grep -q ":${APP_PORT}"; then
    log "  [OK] Порт ${APP_PORT} прослушивается."
else
    log "  [ВНИМАНИЕ] Порт ${APP_PORT} не прослушивается — проверьте журнал службы."
fi

SERVER_IP="$(hostname -I | awk '{print $1}')"
log "Развёртывание завершено."
log "Приложение доступно по адресу: http://${SERVER_IP}:${APP_PORT}"
