#!/usr/bin/env bash
#
# install_labcheck_server.sh — развёртывание приложения проверки лабораторных работ.
#
# Поддерживает два режима, выбираемых автоматически:
#   ОНЛАЙН  — как и прежде: Node.js 20 ставится из NodeSource, npm-зависимости
#             загружаются из сети, источник app.js выбирается интерактивно
#             (рядом со сценарием / локальный файл / внутренний URL).
#   ОФЛАЙН  — если сценарий запущен из распакованного архива, рядом с которым лежат
#             runtime/ (переносимый Node) и node_modules/, — Node и зависимости
#             берутся из комплекта, сеть не используется.
#
# Определение режима: если рядом со сценарием есть runtime/bin/node и node_modules,
# выбирается ОФЛАЙН; иначе — ОНЛАЙН. Режим можно задать явно: MODE=online|offline.
#
# Запуск:
#   sudo bash install_labcheck_server.sh [путь к app.js]        (онлайн, путь необязателен)
#   sudo bash install_labcheck_server.sh                        (офлайн, из каталога архива)
#
# Переменные окружения (необязательные):
#   MODE=online|offline|auto   — принудительный выбор режима (по умолчанию auto);
#   APP_URL=http://...         — внутренний источник app.js (онлайн);
#   REINSTALL=1                — переразвернуть начисто (удалить прежние файлы в /opt/labcheck);
#   SKIP_EMS_WAIT=1            — пропустить ожидание SoftWLC (только для проверки механики).

set -euo pipefail

APP_URL="${APP_URL:-}"
APP_SOURCE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

APP_NEARBY=""
[[ -f "${SCRIPT_DIR}/app.js" ]] && APP_NEARBY="${SCRIPT_DIR}/app.js"

APP_DIR="/opt/labcheck"
APP_PORT=9090
EMS_PORT=8080
EMS_WAIT_TIMEOUT=180
EMS_WAIT_INTERVAL=5
SERVICE_NAME="labcheck"
REINSTALL="${REINSTALL:-0}"
SKIP_EMS_WAIT="${SKIP_EMS_WAIT:-0}"
MODE="${MODE:-auto}"

# Состав офлайн-архива, ожидаемый рядом со сценарием.
BUNDLE_RUNTIME="${SCRIPT_DIR}/runtime"
BUNDLE_MODULES="${SCRIPT_DIR}/node_modules"
BUNDLE_NODE="${BUNDLE_RUNTIME}/bin/node"
BUNDLE_APP="${SCRIPT_DIR}/app.js"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

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
      printf ' %s\n' "${matches[@]}" >&2
      echo "Укажите полный путь к нужному файлу." >&2; return 1
    fi
  fi
  echo "Путь не существует: $input. Попробуйте ещё раз." >&2; return 1
}

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

apt_update_checked() {
  local out
  out="$(apt-get update -y 2>&1)" || true
  echo "$out"
  if echo "$out" | grep -qiE 'not valid yet|Release file.*is not valid'; then
    echo ""
    log "[ВНИМАНИЕ] Похоже, системное время неверно (отстаёт от реального),"
    log "      из-за чего менеджер пакетов отклонил данные репозитория."
    log "      Синхронизируйте время и повторите запуск, например:"
    log "       sudo timedatectl set-ntp true"
    log "      либо задайте время вручную:"
    log "       sudo timedatectl set-time \"ГГГГ-ММ-ДД ЧЧ:ММ:СС\""
  fi
}

softwlc_ems_is_listening() {
  ss -ltn 2>/dev/null | grep -qE ":${EMS_PORT}([[:space:]]|$)"
}

wait_for_softwlc_ems() {
  command -v ss >/dev/null 2>&1 \
    || fail "Не найдена утилита ss (пакет iproute2). Установите её и повторите запуск."
  if softwlc_ems_is_listening; then
    log " [OK] Порт ${EMS_PORT} (EMS-сервер SoftWLC) прослушивается."
    return 0
  fi
  log "Порт ${EMS_PORT} (EMS-сервер SoftWLC) пока не прослушивается."
  log "Ожидание запуска EMS до ${EMS_WAIT_TIMEOUT} с..."
  local waited=0
  while (( waited < EMS_WAIT_TIMEOUT )); do
    sleep "${EMS_WAIT_INTERVAL}"
    waited=$((waited + EMS_WAIT_INTERVAL))
    if softwlc_ems_is_listening; then
      log " [OK] EMS-сервер SoftWLC стал доступен через ${waited} с."
      return 0
    fi
  done
  fail "Порт ${EMS_PORT} (EMS-сервер SoftWLC) не прослушивается после ${EMS_WAIT_TIMEOUT} с.
Приложение проверки зависит от баз данных SoftWLC (wireless, radius) на localhost,
поэтому установка без работающего SoftWLC приведёт к нерабочему развёртыванию.
Сначала установите и запустите SoftWLC, дождитесь доступности EMS,
затем повторите запуск этого сценария."
}

[[ $EUID -eq 0 ]] || fail "Запустите сценарий с правами суперпользователя: sudo $0"

START_TIME="$(date +%s)"

# --- Выбор режима установки ------------------------------------------------------
bundle_present() { [[ -x "$BUNDLE_NODE" && -d "$BUNDLE_MODULES" ]]; }

case "$MODE" in
  online)  RUN_MODE="online" ;;
  offline) RUN_MODE="offline" ;;
  auto)    if bundle_present; then RUN_MODE="offline"; else RUN_MODE="online"; fi ;;
  *) fail "Неизвестный режим MODE='$MODE'. Допустимо: auto, online, offline." ;;
esac

if [[ "$RUN_MODE" == "offline" ]]; then
  log "Режим установки: ОФЛАЙН (Node и зависимости берутся из архива рядом со сценарием)."
else
  log "Режим установки: ОНЛАЙН (Node и зависимости загружаются из сети)."
fi

# --- Ожидание готовности SoftWLC (порт 8080) -------------------------------------
if [[ "$SKIP_EMS_WAIT" -eq 1 ]]; then
  log " [ВНИМАНИЕ] SKIP_EMS_WAIT=1 — ожидание SoftWLC пропущено (режим проверки механики)."
else
  wait_for_softwlc_ems
fi

mkdir -p "$APP_DIR"
APP_CHANGED=0       # станет 1, если код приложения заменён (нужно для перезапуска службы)
NODE_BIN=""         # путь к Node, которым будет запускаться служба

if [[ "$RUN_MODE" == "offline" ]]; then
  # ===== ОФЛАЙН: размещение из архива =====
  log "Проверка состава архива в каталоге: ${SCRIPT_DIR}"
  missing=()
  [[ -f "$BUNDLE_APP" ]]                       || missing+=("app.js")
  [[ -x "$BUNDLE_NODE" ]]                       || missing+=("runtime/bin/node (переносимый Node.js)")
  [[ -d "${BUNDLE_MODULES}/express" ]]          || missing+=("node_modules/express")
  [[ -d "${BUNDLE_MODULES}/express-session" ]]  || missing+=("node_modules/express-session")
  [[ -d "${BUNDLE_MODULES}/mysql2" ]]           || missing+=("node_modules/mysql2")
  [[ -d "${BUNDLE_MODULES}/bcrypt" ]]           || missing+=("node_modules/bcrypt")
  if (( ${#missing[@]} > 0 )); then
    { echo "В каталоге со сценарием отсутствуют необходимые части архива:"
      printf '  - %s\n' "${missing[@]}"; } >&2
    fail "Архив неполный или распакован не целиком. Соберите его сценарием
build_labcheck_bundle.sh, распакуйте полностью и запустите сценарий из этого каталога.
Либо запустите онлайн-установку: sudo MODE=online $0"
  fi
  log " [OK] Архив полный: app.js, runtime, node_modules."

  if [[ "$REINSTALL" -eq 1 ]]; then
    log "REINSTALL=1 — удаление прежнего содержимого ${APP_DIR}."
    rm -rf "${APP_DIR}/runtime" "${APP_DIR}/node_modules" "${APP_DIR}/app.js"
  fi

  if [[ -f "${APP_DIR}/app.js" ]] && cmp -s "$BUNDLE_APP" "${APP_DIR}/app.js"; then
    APP_CHANGED=0
  else
    APP_CHANGED=1
  fi

  log "Размещение среды Node.js, зависимостей и кода приложения в ${APP_DIR}..."
  rm -rf "${APP_DIR}/runtime" "${APP_DIR}/node_modules"
  cp -a "$BUNDLE_RUNTIME" "${APP_DIR}/runtime"
  cp -a "$BUNDLE_MODULES" "${APP_DIR}/node_modules"
  cp -a "$BUNDLE_APP"     "${APP_DIR}/app.js"

  NODE_BIN="${APP_DIR}/runtime/bin/node"

else
  # ===== ОНЛАЙН: установка из сети (как в исходном сценарии) =====
  wait_for_apt
  log "Обновление списка пакетов..."
  apt_update_checked

  if command -v node >/dev/null 2>&1 && [[ "$(node -v | cut -d. -f1 | tr -d v)" -ge 20 ]]; then
    log "Node.js $(node -v) уже установлен, пропуск."
  else
    log "Установка Node.js 20 LTS из репозитория NodeSource..."
    apt-get install -y curl wget ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  log "Версии: node $(node -v), npm $(npm -v)"

  # Идемпотентность: если приложение уже размещено и источник не задан — не трогаем код.
  if [[ -z "$APP_SOURCE" && -z "$APP_URL" && -f "$APP_DIR/app.js" ]]; then
    log "Приложение уже установлено: ${APP_DIR}/app.js – повторный запуск без замены кода."
    log "Для обновления передайте новый источник: sudo $0 /путь/к/app.js либо APP_URL=http://<сервер>/app.js"
    APP_SOURCE="$APP_DIR/app.js"
  fi

  # Интерактивный выбор источника app.js.
  if [[ -z "$APP_SOURCE" && -z "$APP_URL" && -e /dev/tty ]]; then
    echo ""
    echo "Укажите источник приложения для проверки лабораторных работ:"
    if [[ -n "$APP_NEARBY" ]]; then
      echo " 1) Использовать app.js рядом со сценарием (по умолчанию):"
      echo "    $APP_NEARBY"
      echo " 2) Указать другой локальный файл app.js"
      echo " 3) Внутренний источник по URL (веб-сервер организации)"
      read -rp "Ваш выбор [1/2/3]: " APP_MODE </dev/tty
      case "$APP_MODE" in
        2) APP_MODE="local" ;;
        3) APP_MODE="url" ;;
        *) APP_SOURCE="$APP_NEARBY" ;;
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

  # Размещение app.js.
  if [[ -n "$APP_SOURCE" ]]; then
    [[ -f "$APP_SOURCE" ]] || fail "Файл приложения не найден: $APP_SOURCE"
    if [[ "$APP_SOURCE" -ef "$APP_DIR/app.js" ]]; then
      log "Используется уже размещённое приложение: ${APP_DIR}/app.js"
    else
      log "Копирование приложения из ${APP_SOURCE} в ${APP_DIR}..."
      cp "$APP_SOURCE" "$APP_DIR/app.js"
      APP_CHANGED=1
    fi
  elif [[ -n "$APP_URL" ]]; then
    log "Загрузка приложения из внутреннего источника: ${APP_URL}"
    wget -O "$APP_DIR/app.js" "$APP_URL" \
      || fail "Не удалось загрузить приложение из указанного источника."
    APP_CHANGED=1
  else
    fail "Не найден файл приложения. Приложение не распространяется через публичный репозиторий.
Передайте путь аргументом: sudo $0 /путь/к/app.js
или поместите app.js рядом со сценарием,
или задайте внутренний источник: APP_URL=http://<сервер>/app.js"
  fi

  # Установка npm-зависимостей.
  cd "$APP_DIR"
  if [[ -d "$APP_DIR/node_modules/express" && -d "$APP_DIR/node_modules/mysql2" ]]; then
    log "npm-зависимости уже установлены, пропуск."
  else
    log "Установка npm-зависимостей..."
    [[ -f package.json ]] || npm init -y >/dev/null
    npm install express bcrypt express-session mysql2
  fi

  NODE_BIN="$(command -v node)"
fi

# --- Проверка загрузки модулей (оба режима) --------------------------------------
# Проверку запускаем из ${APP_DIR}: Node ищет node_modules относительно текущего
# каталога, поэтому так проверяется именно развёрнутая копия — та же, что увидит служба.
log "Проверка загрузки модулей из ${APP_DIR} (включая нативный bcrypt)..."
if ! ( cd "$APP_DIR" && "$NODE_BIN" -e "require('express');require('express-session');require('mysql2');require('bcrypt')" ) 2>/tmp/labcheck_modcheck.err; then
  { echo "--- вывод проверки ---"; cat /tmp/labcheck_modcheck.err; echo "----------------------"; } >&2
  if [[ "$RUN_MODE" == "offline" ]]; then
    fail "Встроенная среда Node.js не смогла загрузить модули приложения.
Вероятная причина — node_modules собран на другой платформе или другой версии Node
(нативный модуль bcrypt привязан к паре «архитектура процессора + версия Node»).
Пересоберите архив сценарием build_labcheck_bundle.sh на Linux x86_64 той же версией Node 20,
что входит в архив. Если на сервере осталось прежнее развёртывание — запустите с REINSTALL=1."
  else
    fail "Node.js не смог загрузить модули приложения.
Удалите ${APP_DIR}/node_modules и повторите запуск для переустановки зависимостей,
либо запустите с REINSTALL=1."
  fi
fi
log " [OK] Все модули приложения загружаются."

# --- Служба systemd --------------------------------------------------------------
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NEW_UNIT="$(cat <<EOF
[Unit]
Description=Приложение проверки лабораторных работ SoftWLC
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${NODE_BIN} ${APP_DIR}/app.js
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
)"

RESTART_NEEDED=0
[[ "$APP_CHANGED" -eq 1 || "$REINSTALL" -eq 1 ]] && RESTART_NEEDED=1

if [[ -f "$UNIT_FILE" && "$(cat "$UNIT_FILE")" == "$NEW_UNIT" ]]; then
  log "Служба ${SERVICE_NAME} уже настроена, пересоздание не требуется."
else
  log "Создание/обновление службы systemd ${SERVICE_NAME}..."
  printf '%s\n' "$NEW_UNIT" > "$UNIT_FILE"
  systemctl daemon-reload
  RESTART_NEEDED=1
fi

systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || systemctl enable "$SERVICE_NAME"

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl start "$SERVICE_NAME"
elif [[ "$RESTART_NEEDED" -eq 1 ]]; then
  log "Изменения применены — перезапуск службы ${SERVICE_NAME}."
  systemctl restart "$SERVICE_NAME"
else
  log "Изменений нет — служба ${SERVICE_NAME} продолжает работу."
fi

sleep 3
systemctl is-active --quiet "$SERVICE_NAME" \
  || fail "Служба ${SERVICE_NAME} не запустилась. Журнал: journalctl -u ${SERVICE_NAME} -n 50"
log " [OK] Служба ${SERVICE_NAME} запущена."

if ss -tln 2>/dev/null | grep -q ":${APP_PORT}"; then
  log " [OK] Порт ${APP_PORT} прослушивается."
else
  log " [ВНИМАНИЕ] Порт ${APP_PORT} не прослушивается — проверьте журнал: journalctl -u ${SERVICE_NAME} -n 50"
fi

# --- Итог ------------------------------------------------------------------------
SERVER_IP="$(hostname -I | awk '{print $1}')"
ELAPSED=$(( $(date +%s) - START_TIME ))
log "Развёртывание завершено (режим: ${RUN_MODE})."
log "Затрачено времени: $(( ELAPSED / 60 )) мин $(( ELAPSED % 60 )) с."
log "Приложение доступно по адресу: http://${SERVER_IP}:${APP_PORT}"
