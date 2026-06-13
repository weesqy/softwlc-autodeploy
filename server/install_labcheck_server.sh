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
# Приложение для проверки лабораторных работ НЕ размещается
# в публичном репозитории и доставляется одним из способов:
#
# Использование:
#   Вариант 1 (локальный файл, путь аргументом):
#     sudo ./install_labcheck_server.sh /путь/к/app.js
#   Вариант 2 (локальный файл app.js в одной папке с программой):
#     sudo ./install_labcheck_server.sh
#   Вариант 3 (внутренний источник, например веб-сервер организации):
#     sudo APP_URL=http://<внутренний-сервер>/app.js ./install_labcheck_server.sh
# ============================================================

# Внутренний URL приложения (только если задан явно через окружение)
APP_URL="${APP_URL:-}"

APP_SOURCE="${1:-}"
# Если путь не передан — ищем app.js рядом со сценарием
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[[ -z "$APP_SOURCE" && -f "${SCRIPT_DIR}/app.js" ]] && APP_SOURCE="${SCRIPT_DIR}/app.js"
APP_DIR="/opt/labcheck"
APP_PORT=9090
SERVICE_NAME="labcheck"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

# На свежезагруженной системе фоновая служба автообновлений
# (unattended-upgrades) может удерживать блокировку менеджера пакетов.
# Ожидаем её освобождения, чтобы команды apt не завершались ошибкой.
wait_for_apt() {
    command -v fuser >/dev/null 2>&1 || return 0
    if fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
        log "Менеджер пакетов занят фоновым обновлением системы, ожидание освобождения..."
        while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
            sleep 5
        done
        log "Менеджер пакетов освободился, продолжаем."
    fi
}

# Запускает обновление списков пакетов и распознаёт типичную ошибку,
# связанную с неверным системным временем ("Release file ... is not valid yet").
# Такое случается на виртуальных машинах, время которых отстало от реального
# (например, после длительного простоя или отката к снимку). Время не меняется
# автоматически — выводится пояснение со способом исправления.
apt_update_checked() {
    local out
    out="$(apt-get update -y 2>&1)" || true
    echo "$out"
    if echo "$out" | grep -qiE 'not valid yet|Release file.*is not valid'; then
        echo ""
        log "[ВНИМАНИЕ] Похоже, системное время неверно (отстаёт от реального),"
        log "           из-за чего менеджер пакетов отклонил данные репозитория."
        log "           Синхронизируйте время и повторите запуск, например:"
        log "             sudo timedatectl set-ntp true"
        log "           либо задайте время вручную:"
        log "             sudo timedatectl set-time \"ГГГГ-ММ-ДД ЧЧ:ММ:СС\""
    fi
}


# --- 1. Предварительные проверки -----------------------------------
[[ $EUID -eq 0 ]] || fail "Запустите скрипт с правами суперпользователя: sudo $0"

# Приложение обращается к MySQL на localhost — убедимся, что СУБД установлена
systemctl is-active --quiet mysql 2>/dev/null \
    || log "[ВНИМАНИЕ] Служба MySQL не активна. Приложение требует установленного SoftWLC."

wait_for_apt
log "Обновление списка пакетов..."
apt_update_checked

# --- 2. Установка Node.js 20 LTS ------------------------------------
if command -v node >/dev/null 2>&1 && [[ "$(node -v | cut -d. -f1 | tr -d v)" -ge 20 ]]; then
    log "Node.js $(node -v) уже установлен, пропуск."
else
    log "Установка Node.js 20 LTS из репозитория NodeSource..."
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
elif [[ -n "$APP_URL" ]]; then
    log "Загрузка приложения из внутреннего источника: ${APP_URL}"
    wget -O "$APP_DIR/app.js" "$APP_URL" \
        || fail "Не удалось загрузить приложение из указанного источника."
else
    fail "Не найден файл приложения. Приложение не распространяется через публичный репозиторий.
Передайте путь аргументом: sudo $0 /путь/к/app.js
или поместите app.js рядом со сценарием,
или задайте внутренний источник: APP_URL=http://<сервер>/app.js"
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
