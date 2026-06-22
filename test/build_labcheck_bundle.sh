#!/usr/bin/env bash
#
# build_labcheck_bundle.sh — сборка офлайн-архива labcheck-offline.tar.gz.
#
# Запускать ОДИН РАЗ на Linux x86_64 с доступом в Интернет
# (подойдёт снимок самого сервера либо чистая Ubuntu в VirtualBox).
# Рядом со сценарием должны лежать:
#   app.js                      — код приложения проверки;
#   install_labcheck_server.sh  — сценарий установки (попадёт внутрь архива).
#
# Результат — labcheck-offline.tar.gz, содержащий:
#   app.js, install_labcheck_server.sh, node_modules/, runtime/ (переносимый Node 20).
#
# Важно: node_modules собирается ИМЕННО тем Node, что кладётся в архив,
# иначе нативный модуль bcrypt не загрузится на сервере.

set -euo pipefail

# Зафиксированная версия Node 20 LTS. При необходимости задайте актуальную: NODE_VERSION=20.x.y ./build_labcheck_bundle.sh
NODE_VERSION="${NODE_VERSION:-20.18.1}"
NODE_DIST="node-v${NODE_VERSION}-linux-x64"
NODE_TARBALL="${NODE_DIST}.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_JS="${HERE}/app.js"
INSTALL_SCRIPT="${HERE}/install_labcheck_server.sh"
OUT="${HERE}/labcheck-offline.tar.gz"
WORK="$(mktemp -d)"
KIT="${WORK}/kit"

log()  { echo "[build] $*"; }
fail() { echo "[build][ОШИБКА] $*" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

[[ "$(uname -m)" == "x86_64" ]] \
  || fail "Сборку нужно выполнять на x86_64: нативный модуль bcrypt привязан к архитектуре."
[[ -f "$APP_JS" ]]         || fail "Не найден app.js рядом со сценарием сборки: ${APP_JS}"
[[ -f "$INSTALL_SCRIPT" ]] || fail "Не найден install_labcheck_server.sh рядом со сценарием сборки."

mkdir -p "$KIT"

# 1) Переносимая среда Node.js.
log "Загрузка Node.js ${NODE_VERSION}..."
if command -v wget >/dev/null 2>&1; then
  wget -qO "${WORK}/${NODE_TARBALL}" "$NODE_URL" \
    || fail "Не удалось загрузить Node.js. Проверьте версию NODE_VERSION и доступность nodejs.org."
else
  curl -fsSL -o "${WORK}/${NODE_TARBALL}" "$NODE_URL" \
    || fail "Не удалось загрузить Node.js. Проверьте версию NODE_VERSION и доступность nodejs.org."
fi
tar -xf "${WORK}/${NODE_TARBALL}" -C "$WORK"
cp -a "${WORK}/${NODE_DIST}" "${KIT}/runtime"

# 2) Зависимости приложения, собранные ИМЕННО этим Node.
export PATH="${KIT}/runtime/bin:${PATH}"
log "Сборка зависимостей версией node $(node -v)..."
BUILD="${WORK}/build"
mkdir -p "$BUILD"
cp "$APP_JS" "${BUILD}/app.js"
(
  cd "$BUILD"
  npm init -y >/dev/null
  npm install --omit=dev --no-audit --no-fund express bcrypt express-session mysql2
) || fail "Не удалось установить npm-зависимости."
cp -a "${BUILD}/node_modules" "${KIT}/node_modules"

# 3) Код приложения и сценарий установки.
cp "$APP_JS" "${KIT}/app.js"
cp "$INSTALL_SCRIPT" "${KIT}/install_labcheck_server.sh"

# 4) Самопроверка: модули грузятся встроенным Node (главное — нативный bcrypt).
log "Проверка загрузки модулей встроенным Node..."
(
  cd "$KIT"
  ./runtime/bin/node -e "require('express');require('express-session');require('mysql2');require('bcrypt')"
) || fail "Модули не загрузились встроенным Node — сборка прервана."

# 5) Упаковка.
log "Упаковка ${OUT}..."
rm -f "$OUT"
tar -czf "$OUT" -C "$KIT" .

SIZE="$(du -h "$OUT" | cut -f1)"
log "Готово: ${OUT} (${SIZE})."
log "Состав: app.js, install_labcheck_server.sh, node_modules/, runtime/ (Node ${NODE_VERSION})."
log "Дальше: скопируйте архив на сервер, распакуйте и запустите install_labcheck_server.sh."
