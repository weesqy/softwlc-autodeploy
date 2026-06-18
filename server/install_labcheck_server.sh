#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоматизированное развёртывание приложения для проверки
# лабораторных работ (сервер SoftWLC)
# Целевая ОС: Ubuntu Server 22.04 LTS / 24.04 LTS
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
#   Вариант 2 (локальный файл app.js рядом со сценарием):
#     sudo ./install_labcheck_server.sh
#   Вариант 3 (внутренний источник, например веб-сервер организации):
#     sudo APP_URL=http://<внутренний-сервер>/app.js ./install_labcheck_server.sh
#
# Если ни один из источников не задан заранее, скрипт интерактивно
# предлагает выбрать способ доставки приложения (локальный файл / URL).
# ============================================================

# Внутренний URL приложения (только если задан явно через окружение)
APP_URL="${APP_URL:-}"

APP_SOURCE="${1:-}"
# Путь к app.js, лежащему рядом со сценарием (если есть) — предлагается
# в интерактивном меню как вариант по умолчанию.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_NEARBY=""
[[ -f "${SCRIPT_DIR}/app.js" ]] && APP_NEARBY="${SCRIPT_DIR}/app.js"
APP_DIR="/opt/labcheck"
APP_PORT=9090
SERVICE_NAME="labcheck"

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

# Преобразует введённый путь в путь к файлу: принимает путь к файлу
# (возвращает как есть) либо к каталогу (ищет в нём файл по маске).
resolve_local_file() {
    local input="${1%/}" mask="$2"
    if [[ -f "$input" ]]; then printf '%s' "$input"; return 0; fi
    if [[ -d "$input" ]]; then
        local matches=()
        while IFS= read -r -d '' f; do matches+=("$f"); done \
            < <(find "$input" -maxdepth 1 -type f -name "$mask" -print0 2>/dev/null)
        if [[ ${#matches[@]} -eq 1 ]]; then printf '%s' "${matches[0]}"; return 0
        elif [[ ${#matches[@]} -eq 0 ]]; then
            echo "В каталоге $input не найден файл по шаблону $mask. Попробуйте ещё раз." >&2; return 1
        else
            echo "В каталоге $input найдено несколько подходящих файлов:" >&2
            printf '  %s\n' "${matches[@]}" >&2
            echo "Укажите полный путь к нужному файлу." >&2; return 1
        fi
    fi
    echo "Путь не существует: $input. Попробуйте ещё раз." >&2; return 1
}

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
        log "            из-за чего менеджер пакетов отклонил данные репозитория."
        log "            Синхронизируйте время и повторите запуск, например:"
        log "              sudo timedatectl set-ntp true"
        log "            либо задайте время вручную:"
        log "              sudo timedatectl set-time \"ГГГГ-ММ-ДД ЧЧ:ММ:СС\""
    fi
}


# --- 1. Предварительные проверки ------------------------------------
[[ $EUID -eq 0 ]] || fail "Запустите скрипт с правами суперпользователя: sudo $0"

# Засекаем время начала развёртывания для итогового подсчёта длительности.
START_TIME="$(date +%s)"

# SoftWLC (модуль EMS) слушает порт 8080 — это признак, что он развёрнут
# и запущен. Приложение проверки подключается к базам данных SoftWLC
# (wireless, radius) в MySQL на localhost, поэтому SoftWLC должен быть
# установлен на этом же сервере.
if ! ss -ltn 2>/dev/null | grep -qE ':8080([[:space:]]|$)'; then
    log "[ВНИМАНИЕ] Порт 8080 (EMS-сервер SoftWLC) не прослушивается — похоже, SoftWLC"
    log "            не развёрнут на этом сервере либо ещё не запущен (после перезагрузки"
    log "            EMS-серверу нужно несколько минут на запуск). Приложение проверки"
    log "            обращается к базам данных SoftWLC (wireless, radius) на localhost."
fi

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
# Если источник приложения не задан заранее (аргументом или переменной
# APP_URL) — предлагаем выбрать способ доставки интерактивно. Меню
# показывается всегда; если рядом со сценарием найден app.js, он
# предлагается как вариант по умолчанию.
if [[ -z "$APP_SOURCE" && -z "$APP_URL" && -e /dev/tty ]]; then
    echo ""
    echo "Укажите источник приложения для проверки лабораторных работ:"
    if [[ -n "$APP_NEARBY" ]]; then
        echo " 1) Использовать app.js рядом со сценарием (по умолчанию):"
        echo "       $APP_NEARBY"
        echo " 2) Указать другой локальный файл app.js"
        echo " 3) Внутренний источник по URL (веб-сервер организации)"
        read -rp "Ваш выбор [1/2/3]: " APP_MODE </dev/tty
        case "$APP_MODE" in
            2) APP_MODE="local" ;;
            3) APP_MODE="url" ;;
            *) APP_SOURCE="$APP_NEARBY" ;;   # по умолчанию — файл рядом
        esac
    else
        echo " 1) Локальный файл app.js (по умолчанию)"
        echo " 2) Внутренний источник по URL (веб-сервер организации)"
        read -rp "Ваш выбор [1/2]: " APP_MODE </dev/tty
        case "$APP_MODE" in
            2) APP_MODE="url" ;;
            *) APP_MODE="local" ;;
        esac
    fi

    if [[ "$APP_MODE" == "url" ]]; then
        echo "Укажите адрес приложения на внутреннем сервере организации."
        echo " Пример: http://192.168.1.50:8000/app.js"
        while true; do
            read -rp "URL: " APP_URL </dev/tty
            if [[ -z "$APP_URL" ]]; then
                echo "Адрес не может быть пустым. Попробуйте ещё раз."
                continue
            fi
            # Предварительная проверка доступности адреса: при ошибке
            # переспрашиваем, а не прерываем установку.
            if wget -q --timeout=10 --tries=1 -O /dev/null "$APP_URL"; then
                break
            fi
            echo "Не удалось обратиться к адресу: $APP_URL"
            echo "Проверьте адрес и доступность сервера и попробуйте ещё раз."
        done
    elif [[ "$APP_MODE" == "local" ]]; then
        echo "Можно указать путь к файлу либо к папке, в которой он находится."
        while true; do
            echo " Пример файла: /home/${SUDO_USER}/app.js"
            echo " Пример папки: /home/${SUDO_USER}"
            read -rp "Путь к app.js: " APP_INPUT </dev/tty
            APP_SOURCE="$(resolve_local_file "$APP_INPUT" 'app.js')" && break
        done
        echo "Файл приложения найден: $APP_SOURCE"
    fi
fi

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

# --- 4. Установка зависимостей --------------------------------------
log "Установка npm-зависимостей..."
cd "$APP_DIR"
[[ -f package.json ]] || npm init -y >/dev/null
npm install express bcrypt express-session mysql2

# --- 5. Создание systemd-службы -------------------------------------
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

# --- 6. Проверка результата -----------------------------------------
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log " [OK] Служба ${SERVICE_NAME} запущена."
else
    fail "Служба ${SERVICE_NAME} не запустилась. Журнал: journalctl -u ${SERVICE_NAME} -n 50"
fi

if ss -tln | grep -q ":${APP_PORT}"; then
    log " [OK] Порт ${APP_PORT} прослушивается."
else
    log " [ВНИМАНИЕ] Порт ${APP_PORT} не прослушивается — проверьте журнал службы."
fi

SERVER_IP="$(hostname -I | awk '{print $1}')"

# Подсчёт и вывод затраченного времени
ELAPSED=$(( $(date +%s) - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

log "Развёртывание завершено."
log "Затрачено времени: ${ELAPSED_MIN} мин ${ELAPSED_SEC} с."
log "Приложение доступно по адресу: http://${SERVER_IP}:${APP_PORT}"
