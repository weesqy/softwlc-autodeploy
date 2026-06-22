#!/usr/bin/env bash
#
# build_ems_client_bundle.sh — сборка офлайн-архива клиентских сценариев EMS-апплета SoftWLC.
#
# Запускать ОДИН РАЗ на Linux x86_64/amd64 с доступом в Интернет.
# Рядом со сценарием должны лежать клиентские установочные сценарии:
#   install_ems_ubuntu-debian.sh  — установка EMS-клиента для Ubuntu/Debian;
#   install_ems_astra-up.sh       — установка EMS-клиента для Astra Linux Common Edition (Орёл) 2.12.
#
# Результат — ems-client-offline.tar.gz, содержащий:
#   install_ems_ubuntu-debian.sh
#   install_ems_astra-up.sh
#   deps/jdk17-linux-x64.tar.gz
#   deps/icedtea-web-1.8.8.linux.bin.zip
#   SHA256SUMS
#   README_OFFLINE.txt
#
# Важно: текущие клиентские сценарии уже поддерживают офлайн-режим, но в нём
# они интерактивно просят указать путь к архивам JDK 17 и IcedTea-Web.
# После распаковки этого комплекта выбирайте пункт «Офлайн» и указывайте путь
# к каталогу deps/ либо к конкретным файлам внутри deps/.
#
# Переменные окружения (необязательные):
#   JDK_URL=...        — URL архива JDK 17;
#   ICEDTEA_URL=...    — URL архива IcedTea-Web;
#   OUT=...            — имя итогового архива.

set -euo pipefail

JDK_URL="${JDK_URL:-https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse}"
ICEDTEA_URL="${ICEDTEA_URL:-https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.linux.bin.zip}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
UBUNTU_SCRIPT="${HERE}/install_ems_ubuntu-debian.sh"
ASTRA_SCRIPT="${HERE}/install_ems_astra-up.sh"
OUT="${OUT:-${HERE}/ems-client-offline.tar.gz}"
WORK="$(mktemp -d)"
KIT="${WORK}/kit"

JDK_FILE="jdk17-linux-x64.tar.gz"
ICEDTEA_FILE="icedtea-web-1.8.8.linux.bin.zip"

log()  { echo "[build] $*"; }
fail() { echo "[build][ОШИБКА] $*" >&2; exit 1; }
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
      echo "[build][ОШИБКА] Найдено несколько файлов для ${label}:"
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
  || fail "Этот комплект рассчитан на Linux x86_64/amd64. Текущая архитектура: $(uname -m)."

# Разрешаем как точные имена, так и файлы с суффиксами вида (5), если они
# были скачаны из браузера/мессенджера. В архив кладём нормальные имена.
if [[ ! -f "$UBUNTU_SCRIPT" ]]; then
  UBUNTU_SCRIPT="$(find_single_match 'install_ems_ubuntu-debian*.sh' 'сценарий Ubuntu/Debian')"
fi
if [[ ! -f "$ASTRA_SCRIPT" ]]; then
  ASTRA_SCRIPT="$(find_single_match 'install_ems_astra-up*.sh' 'сценарий Astra Linux')"
fi

mkdir -p "${KIT}/deps"

# 1) Клиентские установочные сценарии.
log "Копирование клиентских сценариев..."
cp "$UBUNTU_SCRIPT" "${KIT}/install_ems_ubuntu-debian.sh"
cp "$ASTRA_SCRIPT"  "${KIT}/install_ems_astra-up.sh"
chmod +x "${KIT}/install_ems_ubuntu-debian.sh" "${KIT}/install_ems_astra-up.sh"

# 2) Архивы компонентов для офлайн-режима.
download_file "$JDK_URL" "${KIT}/deps/${JDK_FILE}" "JDK 17 для Linux x64"
download_file "$ICEDTEA_URL" "${KIT}/deps/${ICEDTEA_FILE}" "IcedTea-Web 1.8.8"

# 3) Самопроверка загруженных архивов.
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

# 4) Инструкция внутри комплекта.
cat > "${KIT}/README_OFFLINE.txt" <<'README'
Офлайн-комплект EMS-клиента SoftWLC
===================================

Состав:
  install_ems_ubuntu-debian.sh          — клиентский установщик для Ubuntu/Debian;
  install_ems_astra-up.sh               — клиентский установщик для Astra Linux Common Edition;
  deps/jdk17-linux-x64.tar.gz           — JDK 17 для Linux x64;
  deps/icedtea-web-1.8.8.linux.bin.zip  — IcedTea-Web 1.8.8;
  SHA256SUMS                            — контрольные суммы файлов комплекта.

Как использовать на клиентской машине:

1. Распаковать архив:
     tar -xzf ems-client-offline.tar.gz
     cd <каталог_распаковки>

2. Запустить нужный сценарий:

   Ubuntu/Debian:
     sudo bash install_ems_ubuntu-debian.sh

   Astra Linux Common Edition:
     sudo bash install_ems_astra-up.sh

   Можно сразу передать адрес EMS-сервера SoftWLC:
     sudo bash install_ems_ubuntu-debian.sh http://<ip-сервера>:8080/ems/jws
     sudo bash install_ems_astra-up.sh http://<ip-сервера>:8080/ems/jws

3. В меню выбора режима установки выбрать:
     2) Офлайн — установка из локальных файлов

4. Когда сценарий попросит архив JDK 17, указать:
     deps
   либо конкретный файл:
     deps/jdk17-linux-x64.tar.gz

5. Когда сценарий попросит архив IcedTea-Web, указать:
     deps
   либо конкретный файл:
     deps/icedtea-web-1.8.8.linux.bin.zip

Примечания:
  - Комплект рассчитан на x86-64/amd64.
  - В офлайн-режиме на клиентской ОС уже должны быть доступны базовые утилиты
    tar, unzip и wget. Если их нет, установите их заранее из репозитория ОС
    или с установочного носителя.
  - JNLP-файл всё равно загружается с EMS-сервера SoftWLC по локальной сети.
    Это не Интернет-загрузка, а обращение к вашему серверу SoftWLC.
README

# 5) Контрольные суммы.
log "Расчёт SHA256SUMS..."
(
  cd "$KIT"
  sha256sum \
    install_ems_ubuntu-debian.sh \
    install_ems_astra-up.sh \
    "deps/${JDK_FILE}" \
    "deps/${ICEDTEA_FILE}" \
    README_OFFLINE.txt > SHA256SUMS
)

# 6) Итоговая проверка состава.
log "Проверка состава комплекта..."
for required in \
  "${KIT}/install_ems_ubuntu-debian.sh" \
  "${KIT}/install_ems_astra-up.sh" \
  "${KIT}/deps/${JDK_FILE}" \
  "${KIT}/deps/${ICEDTEA_FILE}" \
  "${KIT}/SHA256SUMS" \
  "${KIT}/README_OFFLINE.txt"; do
  [[ -s "$required" ]] || fail "В комплекте отсутствует или пустой файл: ${required#${KIT}/}"
done

# 7) Упаковка.
log "Упаковка ${OUT}..."
rm -f "$OUT"
tar -czf "$OUT" -C "$KIT" .

SIZE="$(du -h "$OUT" | cut -f1)"
log "Готово: ${OUT} (${SIZE})."
log "Состав: install_ems_ubuntu-debian.sh, install_ems_astra-up.sh, deps/ с JDK 17 и IcedTea-Web, SHA256SUMS, README_OFFLINE.txt."
log "Дальше: скопируйте архив на клиентскую машину, распакуйте, запустите нужный install_ems_*.sh и выберите офлайн-режим."
