#!/usr/bin/env bash
#
# build_ems_astra_bundle.sh — сборка офлайн-архива EMS-клиента SoftWLC для Astra Linux Common Edition.
#
# Запускать ОДИН РАЗ на Linux x86_64/amd64 с доступом в Интернет.
# Рядом со сборщиком должен лежать клиентский установочный сценарий:
#   install_ems_astra-up.sh
#
# Результат:
#   ems-astra-client-offline.tar.gz
#
# Состав архива:
#   install_ems_astra-up.sh
#   deps/jdk17-linux-x64.tar.gz
#   deps/icedtea-web-1.8.8.linux.bin.zip
#   SHA256SUMS
#   README_OFFLINE_ASTRA.txt
#
# Переменные окружения, которые можно переопределить при запуске:
#   JDK_URL=...       — URL архива JDK 17;
#   ICEDTEA_URL=...   — URL архива IcedTea-Web;
#   OUT=...           — путь/имя итогового архива.

set -euo pipefail

JDK_URL="${JDK_URL:-https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse}"
ICEDTEA_URL="${ICEDTEA_URL:-https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.linux.bin.zip}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_SCRIPT="${HERE}/install_ems_astra-up.sh"
OUT="${OUT:-${HERE}/ems-astra-client-offline.tar.gz}"
WORK="$(mktemp -d)"
KIT="${WORK}/kit"

JDK_FILE="jdk17-linux-x64.tar.gz"
ICEDTEA_FILE="icedtea-web-1.8.8.linux.bin.zip"

log()  { echo "[build][astra] $*"; }
fail() { echo "[build][astra][ОШИБКА] $*" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

find_single_match() {
  local pattern="$1" label="$2"
  local matches=()
  while IFS= read -r -d '' f; do matches+=("$f"); done \
    < <(find "$HERE" -maxdepth 1 -type f -name "$pattern" -print0 2>/dev/null)

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  elif [[ ${#matches[@]} -eq 0 ]]; then
    fail "Не найден ${label} рядом со сборщиком. Ожидается файл по маске: ${pattern}"
  else
    {
      echo "[build][astra][ОШИБКА] Найдено несколько файлов для ${label}:"
      printf '  - %s\n' "${matches[@]}"
      echo "Оставьте один файл или переименуйте нужный в точное имя."
    } >&2
    exit 1
  fi
}

download_file() {
  local url="$1" dest="$2" label="$3"
  log "Загрузка ${label}..."
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$dest" "$url" \
      || fail "Не удалось загрузить ${label}. Проверьте URL и доступность сети: ${url}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$dest" "$url" \
      || fail "Не удалось загрузить ${label}. Проверьте URL и доступность сети: ${url}"
  else
    fail "Не найден wget или curl. Установите один из них и повторите сборку."
  fi
}

[[ "$(uname -m)" == "x86_64" ]] \
  || fail "Сборщик готовит комплект с JDK/IcedTea-Web для x86_64/amd64. Текущая архитектура: $(uname -m)."

command -v tar >/dev/null 2>&1 || fail "Не найдена утилита tar. Установите tar и повторите сборку."
command -v sha256sum >/dev/null 2>&1 || fail "Не найдена утилита sha256sum. Установите coreutils и повторите сборку."

# Разрешаем файлы с суффиксами вида install_ems_astra-up(5).sh,
# если они были скачаны из браузера/мессенджера. В архив кладём нормальное имя.
if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  INSTALL_SCRIPT="$(find_single_match 'install_ems_astra-up*.sh' 'клиентский сценарий Astra Linux')"
fi

mkdir -p "${KIT}/deps"

log "Копирование сценария установки Astra Linux..."
cp "$INSTALL_SCRIPT" "${KIT}/install_ems_astra-up.sh"
chmod +x "${KIT}/install_ems_astra-up.sh"

if command -v bash >/dev/null 2>&1; then
  log "Проверка синтаксиса install_ems_astra-up.sh..."
  bash -n "${KIT}/install_ems_astra-up.sh" \
    || fail "В install_ems_astra-up.sh обнаружена синтаксическая ошибка."
fi

download_file "$JDK_URL" "${KIT}/deps/${JDK_FILE}" "JDK 17 для Linux x64"
download_file "$ICEDTEA_URL" "${KIT}/deps/${ICEDTEA_FILE}" "IcedTea-Web 1.8.8"

log "Проверка архива JDK..."
tar -tzf "${KIT}/deps/${JDK_FILE}" >/dev/null \
  || fail "Архив JDK повреждён или не является .tar.gz: deps/${JDK_FILE}"

log "Проверка архива IcedTea-Web..."
if command -v unzip >/dev/null 2>&1; then
  unzip -tq "${KIT}/deps/${ICEDTEA_FILE}" >/dev/null \
    || fail "Архив IcedTea-Web повреждён или не является zip: deps/${ICEDTEA_FILE}"
else
  log "unzip не найден — пропуск глубокой проверки zip-архива."
fi

cat > "${KIT}/README_OFFLINE_ASTRA.txt" <<'README'
Офлайн-комплект EMS-клиента SoftWLC для Astra Linux Common Edition
==================================================================

Состав:
  install_ems_astra-up.sh                — клиентский установщик для Astra Linux Common Edition;
  deps/jdk17-linux-x64.tar.gz            — JDK 17 для Linux x64;
  deps/icedtea-web-1.8.8.linux.bin.zip   — IcedTea-Web 1.8.8;
  SHA256SUMS                             — контрольные суммы файлов комплекта.

Как использовать на клиентской машине Astra Linux Common Edition:

1. Распаковать архив:
     tar -xzf ems-astra-client-offline.tar.gz
     cd <каталог_распаковки>

2. При необходимости проверить контрольные суммы:
     sha256sum -c SHA256SUMS

3. Запустить установку:
     sudo bash install_ems_astra-up.sh

   Либо сразу передать адрес EMS-сервера SoftWLC:
     sudo bash install_ems_astra-up.sh http://<ip-сервера>:8080/ems/jws

4. В меню выбора режима установки выбрать:
     2) Офлайн — установка из локальных файлов

5. Когда сценарий попросит путь к архиву JDK 17, указать:
     deps
   либо конкретный файл:
     deps/jdk17-linux-x64.tar.gz

6. Когда сценарий попросит путь к архиву IcedTea-Web, указать:
     deps
   либо конкретный файл:
     deps/icedtea-web-1.8.8.linux.bin.zip

Примечания:
  - Комплект рассчитан на Astra Linux Common Edition x86-64/amd64.
  - В офлайн-режиме на клиентской ОС уже должны быть доступны tar, unzip и wget.
  - JNLP-файл всё равно загружается с EMS-сервера SoftWLC по локальной сети.
README

log "Расчёт SHA256SUMS..."
(
  cd "$KIT"
  sha256sum \
    install_ems_astra-up.sh \
    "deps/${JDK_FILE}" \
    "deps/${ICEDTEA_FILE}" \
    README_OFFLINE_ASTRA.txt > SHA256SUMS
)

log "Проверка состава комплекта..."
for required in \
  "${KIT}/install_ems_astra-up.sh" \
  "${KIT}/deps/${JDK_FILE}" \
  "${KIT}/deps/${ICEDTEA_FILE}" \
  "${KIT}/SHA256SUMS" \
  "${KIT}/README_OFFLINE_ASTRA.txt"; do
  [[ -s "$required" ]] || fail "В комплекте отсутствует или пустой файл: ${required#${KIT}/}"
done

log "Упаковка ${OUT}..."
rm -f "$OUT"
tar -czf "$OUT" -C "$KIT" .

SIZE="$(du -h "$OUT" | cut -f1)"
log "Готово: ${OUT} (${SIZE})."
log "Дальше: скопируйте архив на клиент Astra Linux, распакуйте, запустите install_ems_astra-up.sh и выберите офлайн-режим."
