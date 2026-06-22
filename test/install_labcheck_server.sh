#!/usr/bin/env bash
#
# install_labcheck_server.sh — тестовый офлайн-вариант.
#
# Развёртывание приложения проверки лабораторных работ из готового архива.
# Сценарий запускается ИЗ РАСПАКОВАННОГО архива и рассчитывает найти рядом с собой:
#   app.js                — код приложения проверки;
#   node_modules/         — зависимости (express, express-session, mysql2, bcrypt);
#   runtime/bin/node      — переносимую среду Node.js 20 (Linux x86_64).
# Ничего из сети при установке не загружается.
#
# Порядок применения:
#   1) скопировать архив на сервер (например: scp labcheck-offline.tar.gz user@server:~);
#   2) распаковать целиком:        tar -xzf labcheck-offline.tar.gz -C ~/labcheck-kit;
#   3) запустить из каталога:      cd ~/labcheck-kit && sudo bash install_labcheck_server.sh
#
# Переменные окружения (необязательные):
#   REINSTALL=1       — полностью переразвернуть (удалить прежние app.js, runtime, node_modules);
#   SKIP_EMS_WAIT=1   — пропустить ожидание SoftWLC (только для проверки механики архива без сервера).

set -euo pipefail

APP_DIR="/opt/labcheck"
APP_PORT=9090
EMS_PORT=8080
EMS_WAIT_TIMEOUT=180
EMS_WAIT_INTERVAL=5
SERVICE_NAME="labcheck"
REINSTALL="${REINSTALL:-0}"
SKIP_EMS_WAIT="${SKIP_EMS_WAIT:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Состав архива, ожидаемый рядом со сценарием.
BUNDLE_APP="${SCRIPT_DIR}/app.js"
BUNDLE_MODULES="${SCRIPT_DIR}/node_modules"
BUNDLE_RUNTIME="${SCRIPT_DIR}/runtime"
BUNDLE_NODE="${BUNDLE_RUNTIME}/bin/node"

# Расположение среды Node.js после установки.
NODE_BIN="${APP_DIR}/runtime/bin/node"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Запустите сценарий с правами суперпользователя: sudo $0"

START_TIME="$(date +%s)"

# --- 0. Проверка полноты распакованного архива -----------------------------------
log "Проверка состава архива в каталоге: ${SCRIPT_DIR}"
missing=()
[[ -f "$BUNDLE_APP" ]]                       || missing+=("app.js")
[[ -x "$BUNDLE_NODE" ]]                       || missing+=("runtime/bin/node (переносимый Node.js)")
[[ -d "${BUNDLE_MODULES}/express" ]]          || missing+=("node_modules/express")
[[ -d "${BUNDLE_MODULES}/express-session" ]]  || missing+=("node_modules/express-session")
[[ -d "${BUNDLE_MODULES}/mysql2" ]]           || missing+=("node_modules/mysql2")
[[ -d "${BUNDLE_MODULES}/bcrypt" ]]           || missing+=("node_modules/bcrypt")
if (( ${#missing[@]} > 0 )); then
  {
    echo "В каталоге со сценарием отсутствуют необходимые части архива:"
    printf '  - %s\n' "${missing[@]}"
  } >&2
  fail "Архив неполный или распакован не целиком.
Соберите его сценарием build_labcheck_bundle.sh, распакуйте полностью
и запустите этот сценарий из распакованного каталога."
fi
log " [OK] Архив полный: app.js, runtime, node_modules."

# --- 1. Ожидание готовности SoftWLC (порт 8080) ----------------------------------
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

if [[ "$SKIP_EMS_WAIT" -eq 1 ]]; then
  log " [ВНИМАНИЕ] SKIP_EMS_WAIT=1 — ожидание SoftWLC пропущено (режим проверки механики архива)."
else
  wait_for_softwlc_ems
fi

# --- 2. Размещение среды, зависимостей и кода приложения в ${APP_DIR} -------------
mkdir -p "$APP_DIR"

if [[ "$REINSTALL" -eq 1 ]]; then
  log "REINSTALL=1 — удаление прежнего содержимого ${APP_DIR}."
  rm -rf "${APP_DIR}/runtime" "${APP_DIR}/node_modules" "${APP_DIR}/app.js"
fi

# Фиксируем, изменился ли код приложения (нужно для решения о перезапуске службы).
APP_CHANGED=1
if [[ -f "${APP_DIR}/app.js" ]] && cmp -s "$BUNDLE_APP" "${APP_DIR}/app.js"; then
  APP_CHANGED=0
fi

log "Размещение среды Node.js, зависимостей и кода приложения в ${APP_DIR}..."
rm -rf "${APP_DIR}/runtime" "${APP_DIR}/node_modules"
cp -a "$BUNDLE_RUNTIME"  "${APP_DIR}/runtime"
cp -a "$BUNDLE_MODULES"  "${APP_DIR}/node_modules"
cp -a "$BUNDLE_APP"      "${APP_DIR}/app.js"

# --- 3. Проверка среды и нативного модуля bcrypt ---------------------------------
log "Среда: node $("$NODE_BIN" -v)"
log "Проверка загрузки модулей приложения встроенной средой (включая нативный bcrypt)..."
# Проверку запускаем из ${APP_DIR}: Node ищет node_modules относительно текущего
# каталога, поэтому так проверяется именно развёрнутая копия зависимостей —
# та же, что увидит служба (ExecStart запускает app.js из ${APP_DIR}).
if ! ( cd "$APP_DIR" && "$NODE_BIN" -e "require('express');require('express-session');require('mysql2');require('bcrypt')" ) 2>/tmp/labcheck_modcheck.err; then
  { echo "--- вывод проверки ---"; cat /tmp/labcheck_modcheck.err; echo "----------------------"; } >&2
  fail "Встроенная среда Node.js не смогла загрузить модули приложения.
Наиболее вероятная причина — node_modules собран на другой платформе или другой версии Node:
нативный модуль bcrypt привязан к паре «архитектура процессора + версия Node».
Пересоберите архив сценарием build_labcheck_bundle.sh на Linux x86_64 той же версией Node 20,
что входит в архив. Если на сервере осталось старое развёртывание — запустите с REINSTALL=1."
fi
log " [OK] Все модули приложения загружаются встроенной средой."

# --- 4. Служба systemd -----------------------------------------------------------
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

# --- 5. Итог ---------------------------------------------------------------------
SERVER_IP="$(hostname -I | awk '{print $1}')"
ELAPSED=$(( $(date +%s) - START_TIME ))
log "Развёртывание завершено (офлайн, из архива)."
log "Затрачено времени: $(( ELAPSED / 60 )) мин $(( ELAPSED % 60 )) с."
log "Приложение доступно по адресу: http://${SERVER_IP}:${APP_PORT}"
