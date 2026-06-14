#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоматизированная установка EMS-апплета SoftWLC (клиент)
# Целевая ОС: Astra Linux Common Edition (Орёл) 2.12,
#             версия 2.12.46.6 от 17.04.2023, архитектура x86-64.
#
# Отличия от сценария для Ubuntu:
#   - JDK 17 устанавливается из архива (tar.gz), так как в штатном
#     репозитории Astra Linux Орёл 2.12 нет подходящей версии;
#   - переменные окружения JAVA_HOME и PATH задаются через
#     /etc/profile.d/java.sh.
#
# Скрипт выполняет:
#   1) получение JDK 17 (локальный архив или загрузка по URL);
#   2) распаковку JDK в /usr/lib/jvm и настройку окружения;
#   3) регистрацию альтернатив java / javac;
#   4) установку IcedTea-Web 1.8.8 и настройку альтернатив
#      javaws / itweb-settings / policyeditor;
#   5) загрузку ems_gui.jnlp с сервера и запуск EMS-апплета.
#
# Особенности сценария:
#   - каталог распаковки JDK определяется из самого архива, поэтому
#     подходит любая сборка 17.x, не только jdk-17.0.14+7;
#   - в офлайн-режиме проверяется наличие необходимых утилит.
#
# Использование:
#   Вариант 1 (интерактивный — IP сервера вводится с клавиатуры):
#     sudo ./install_ems_client_astra.sh
#     (дополнительно интерактивно предлагается выбрать режим: онлайн или офлайн)
#   Вариант 2 (адрес передаётся аргументом, без вопросов):
#     sudo ./install_ems_client_astra.sh http://192.168.1.23:8080/ems/jws
# ============================================================

JNLP_URL="${1:-}"

# Подсказка по версии JDK для офлайн-режима (используется только в тексте
# приглашений). Фактический каталог распаковки определяется из самого архива.
JDK_VERSION_HINT="jdk-17.0.14+7"
JDK_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.14%2B7/OpenJDK17U-jdk_x64_linux_hotspot_17.0.14_7.tar.gz"
# Путь к локальному архиву JDK. Заполняется только при выборе офлайн-режима.
JDK_TARBALL=""
JVM_DIR="/usr/lib/jvm"
# JAVA_HOME_DIR определяется ниже динамически (по имени каталога в архиве
# либо по уже установленному JDK), поэтому здесь не задаётся жёстко.
JAVA_HOME_DIR=""

ICEDTEA_DIR="/opt/icedtea"
ICEDTEA_URL="https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.linux.bin.zip"
# Путь к локальному архиву IcedTea-Web. Заполняется только при выборе офлайн-режима.
ICEDTEA_ZIP=""

# Режим установки: online (по умолчанию) либо offline. Определяется в диалоге.
INSTALL_MODE_KIND="online"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

# Преобразует введённый путь в путь к файлу. Принимает:
#   - путь к существующему файлу — возвращает его как есть;
#   - путь к каталогу — ищет в нём файл по маске (второй аргумент).
# При неоднозначности или отсутствии файла возвращает ненулевой код.
resolve_local_file() {
    local input="${1%/}" mask="$2"
    if [[ -f "$input" ]]; then
        printf '%s' "$input"
        return 0
    fi
    if [[ -d "$input" ]]; then
        local matches=()
        while IFS= read -r -d '' f; do matches+=("$f"); done \
            < <(find "$input" -maxdepth 1 -type f -name "$mask" -print0 2>/dev/null)
        if [[ ${#matches[@]} -eq 1 ]]; then
            printf '%s' "${matches[0]}"
            return 0
        elif [[ ${#matches[@]} -eq 0 ]]; then
            echo "В каталоге $input не найден файл по шаблону $mask. Попробуйте ещё раз." >&2
            return 1
        else
            echo "В каталоге $input найдено несколько подходящих файлов:" >&2
            printf '  %s\n' "${matches[@]}" >&2
            echo "Укажите полный путь к нужному файлу." >&2
            return 1
        fi
    fi
    echo "Путь не существует: $input. Попробуйте ещё раз." >&2
    return 1
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
        log "           из-за чего менеджер пакетов отклонил данные репозитория."
        log "           Синхронизируйте время и повторите запуск, например:"
        log "             sudo timedatectl set-ntp true"
        log "           либо задайте время вручную:"
        log "             sudo timedatectl set-time \"ГГГГ-ММ-ДД ЧЧ:ММ:СС\""
    fi
}


# --- 1. Предварительные проверки -----------------------------------
[[ $EUID -eq 0 ]] || fail "Запустите скрипт через sudo."
[[ -n "${SUDO_USER:-}" ]] || fail "Не удалось определить пользователя, запустившего sudo."

# Засекаем время начала установки для итогового подсчёта длительности.
START_TIME="$(date +%s)"

# Если адрес не передан аргументом — запрашиваем IP сервера интерактивно.
# Ввод читается с /dev/tty, поэтому запрос работает и при запуске
# через конвейер вида: wget -qO- <URL_скрипта> | sudo bash
if [[ -z "$JNLP_URL" ]]; then
    [[ -e /dev/tty ]] || fail "Терминал недоступен. Передайте адрес аргументом:
sudo $0 http://<ip-сервера>:8080/ems/jws"
    while true; do
        read -rp "Введите IP-адрес сервера SoftWLC (например, 192.168.1.23): " SERVER_IP </dev/tty
        if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "Некорректный формат IP-адреса, попробуйте ещё раз."
            continue
        fi
        JNLP_URL="http://${SERVER_IP}:8080/ems/jws"
        echo "Проверка доступности сервера ${JNLP_URL}..."
        if wget -q --spider --timeout=5 --tries=1 "$JNLP_URL"; then
            echo "Сервер SoftWLC доступен."
            break
        fi
        read -rp "Сервер не отвечает. Продолжить с этим адресом? [y/N]: " ANSWER </dev/tty
        [[ "$ANSWER" =~ ^[YyДд]$ ]] && break
    done
fi

# Предлагаем выбрать режим установки: онлайн или офлайн. В офлайн-режиме
# запрашиваются пути к локальным архивам JDK 17 и IcedTea-Web.
if [[ -e /dev/tty ]]; then
    echo ""
    echo "Выберите режим установки компонентов:"
    echo "  1) Онлайн  — загрузка из сети Интернет (по умолчанию)"
    echo "  2) Офлайн  — установка из локальных файлов (для изолированной сети)"
    read -rp "Ваш выбор [1/2]: " INSTALL_MODE </dev/tty
    if [[ "$INSTALL_MODE" == "2" ]]; then
        INSTALL_MODE_KIND="offline"
        echo "Для офлайн-установки нужны два заранее скачанных архива:"
        echo "  - JDK 17 (OpenJDK17U-jdk_x64_linux_hotspot_17.0.14_7.tar.gz);"
        echo "  - IcedTea-Web (icedtea-web-1.8.8.linux.bin.zip)."
        echo "Можно указать путь к файлу либо к папке, в которой он находится."
        while true; do
            echo "Архив JDK 17 (например, ${JDK_VERSION_HINT}, .tar.gz; подойдёт любая сборка 17.x)."
            echo "  Пример файла: /home/${SUDO_USER}/Downloads/OpenJDK17U-jdk_x64_linux_hotspot_17.0.14_7.tar.gz"
            echo "  Пример папки: /home/${SUDO_USER}/Downloads"
            read -rp "Путь: " JDK_INPUT </dev/tty
            JDK_TARBALL="$(resolve_local_file "$JDK_INPUT" '*.tar.gz')" && break
        done
        echo "Архив JDK найден: $JDK_TARBALL"
        while true; do
            echo "Архив IcedTea-Web (icedtea-web-1.8.8.linux.bin.zip)."
            echo "  Пример файла: /home/${SUDO_USER}/Downloads/icedtea-web-1.8.8.linux.bin.zip"
            echo "  Пример папки: /home/${SUDO_USER}/Downloads"
            read -rp "Путь: " ICEDTEA_INPUT </dev/tty
            ICEDTEA_ZIP="$(resolve_local_file "$ICEDTEA_INPUT" 'icedtea-web-*.zip')" && break
        done
        echo "Архив IcedTea-Web найден: $ICEDTEA_ZIP"
        log "Выбран офлайн-режим установки компонентов."
    else
        log "Выбран онлайн-режим установки компонентов."
    fi
fi

TARGET_USER="$SUDO_USER"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
DOWNLOAD_DIR="${TARGET_HOME}/Downloads"
mkdir -p "$DOWNLOAD_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Подготовка вспомогательных утилит (wget — для загрузки JNLP с сервера,
# unzip — для распаковки IcedTea-Web, tar — для распаковки JDK).
if [[ "$INSTALL_MODE_KIND" == "offline" ]]; then
    # Офлайн-режим: сеть недоступна, через apt ничего не ставим.
    # Проверяем, что нужные утилиты уже присутствуют в системе.
    for tool in wget unzip tar; do
        command -v "$tool" >/dev/null 2>&1 \
            || fail "Утилита '$tool' не найдена. В офлайн-режиме она должна быть установлена заранее (sudo apt install $tool)."
    done
else
    # Онлайн-режим: ставим вспомогательные утилиты из репозитория.
    wait_for_apt
    apt_update_checked
    apt-get install -y wget unzip ca-certificates || true
    for tool in wget unzip tar; do
        command -v "$tool" >/dev/null 2>&1 \
            || fail "Утилита '$tool' не найдена и не установилась из репозитория. Установите вручную: sudo apt install $tool."
    done
fi

# --- 2. Установка JDK 17 из архива -----------------------------------
# Ищем уже установленный JDK 17 (каталог jdk-17* с рабочим java), чтобы не
# скачивать и не распаковывать архив повторно. Имя каталога у разных сборок
# 17.x отличается, поэтому ищем по маске, а не по фиксированному имени.
EXISTING_JDK=""
for d in "$JVM_DIR"/jdk-17*; do
    if [[ -x "$d/bin/java" ]]; then
        EXISTING_JDK="$d"
        break
    fi
done

if [[ -n "$EXISTING_JDK" ]]; then
    JAVA_HOME_DIR="$EXISTING_JDK"
    log "[1/6] JDK 17 уже установлен в ${JAVA_HOME_DIR}, пропуск загрузки и распаковки."
    log "[2/6] Настройка окружения..."
else
    log "[1/6] Получение JDK 17..."
    if [[ -n "$JDK_TARBALL" && -f "$JDK_TARBALL" ]]; then
        log "Используется локальный архив: $JDK_TARBALL"
        cp "$JDK_TARBALL" "$TMP_DIR/jdk17.tar.gz"
    else
        log "Загрузка JDK 17: $JDK_URL"
        wget -O "$TMP_DIR/jdk17.tar.gz" "$JDK_URL" \
            || fail "Не удалось загрузить JDK из сети. Повторите запуск и выберите офлайн-режим с локальным архивом."
    fi

    # Имя корневого каталога внутри архива определяем из самого архива,
    # поэтому подходит любая сборка JDK 17.x (не только jdk-17.0.14+7).
    JDK_TOPDIR="$(tar -tzf "$TMP_DIR/jdk17.tar.gz" 2>/dev/null | head -1 || true)"
    JDK_TOPDIR="${JDK_TOPDIR%%/*}"
    [[ -n "$JDK_TOPDIR" ]] || fail "Не удалось прочитать содержимое архива JDK."
    JAVA_HOME_DIR="${JVM_DIR}/${JDK_TOPDIR}"

    log "[2/6] Распаковка JDK в ${JVM_DIR} и настройка окружения (каталог: ${JDK_TOPDIR})..."
    mkdir -p "$JVM_DIR"
    tar -xzf "$TMP_DIR/jdk17.tar.gz" -C "$JVM_DIR/" \
        || fail "Не удалось распаковать архив JDK."
    [[ -d "$JAVA_HOME_DIR" ]] || fail "После распаковки не найден каталог ${JAVA_HOME_DIR}."
    [[ -x "${JAVA_HOME_DIR}/bin/java" ]] || fail "В распакованном JDK не найден исполняемый файл bin/java."
fi

# Переменные окружения для всех пользователей системы
cat > /etc/profile.d/java.sh <<EOF
export JAVA_HOME=${JAVA_HOME_DIR}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
chmod +x /etc/profile.d/java.sh
# shellcheck disable=SC1091
source /etc/profile.d/java.sh

# --- 3. Регистрация альтернатив java / javac --------------------------
log "[3/6] Регистрация альтернатив java и javac..."
update-alternatives --install /usr/bin/java  java  "${JAVA_HOME_DIR}/bin/java"  2000
update-alternatives --install /usr/bin/javac javac "${JAVA_HOME_DIR}/bin/javac" 2000
update-alternatives --set java  "${JAVA_HOME_DIR}/bin/java"
update-alternatives --set javac "${JAVA_HOME_DIR}/bin/javac"

# Проверка запуска java.
if ! java -version; then
    fail "Команда 'java -version' завершилась ошибкой. Проверьте корректность установки JDK 17."
fi

# --- 4. Установка IcedTea-Web -----------------------------------------
if [[ -x "${ICEDTEA_DIR}/icedtea-web-image/bin/javaws" ]]; then
    log "[4/6] IcedTea-Web уже установлен в ${ICEDTEA_DIR}, пропуск загрузки и распаковки."
else
    log "[4/6] Установка IcedTea-Web 1.8.8..."
    if [[ -n "$ICEDTEA_ZIP" && -f "$ICEDTEA_ZIP" ]]; then
        log "Используется локальный архив: $ICEDTEA_ZIP"
        cp "$ICEDTEA_ZIP" "$TMP_DIR/icedtea.zip"
    else
        log "Загрузка архива: $ICEDTEA_URL"
        wget -O "$TMP_DIR/icedtea.zip" "$ICEDTEA_URL" \
            || fail "Не удалось загрузить IcedTea-Web из сети. Повторите запуск и выберите офлайн-режим с локальным архивом."
    fi

    cd "$TMP_DIR"
    unzip -q icedtea.zip
    [[ -d icedtea-web-image ]] || fail "После распаковки не найден каталог icedtea-web-image."

    mkdir -p "$ICEDTEA_DIR"
    mv icedtea-web-image "$ICEDTEA_DIR/"
fi

for tool in javaws itweb-settings policyeditor; do
    update-alternatives --install "/usr/bin/${tool}" "$tool" \
        "${ICEDTEA_DIR}/icedtea-web-image/bin/${tool}" 1500
    update-alternatives --set "$tool" "${ICEDTEA_DIR}/icedtea-web-image/bin/${tool}"
done

javaws --version || true
rm -rf "${TARGET_HOME}/.cache/icedtea-web/cache/" || true

# --- 5. Загрузка JNLP-файла --------------------------------------------
log "[5/6] Загрузка ems_gui.jnlp с ${JNLP_URL}..."
JNLP_FILE="${DOWNLOAD_DIR}/ems_gui.jnlp"
JNLP_OK=0
for attempt in $(seq 1 10); do
    wget -q -O "$JNLP_FILE" "$JNLP_URL" || true
    if [[ -s "$JNLP_FILE" ]] && grep -q '<jnlp' "$JNLP_FILE"; then
        JNLP_OK=1
        break
    fi
    log "EMS-сервер ещё не готов (попытка ${attempt} из 10), повтор через 15 секунд..."
    sleep 15
done
[[ "$JNLP_OK" -eq 1 ]] || fail "Сервер не вернул корректный JNLP-файл.
Убедитесь, что SoftWLC полностью запущен (после перезагрузки сервера запуск занимает несколько минут), и повторите."
chown "${TARGET_USER}:${TARGET_USER}" "$JNLP_FILE"

# Подсчёт и вывод затраченного на установку времени
ELAPSED=$(( $(date +%s) - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))
log "Установка компонентов завершена. Затрачено времени: ${ELAPSED_MIN} мин ${ELAPSED_SEC} с."

# --- 6. Запуск EMS-апплета ----------------------------------------------
# javaws запускается напрямую с URL и с параметром -allowredirect: сервер
# SoftWLC может отвечать на запрос /ems/jws HTTP-перенаправлением (301/302),
# которое wget выполняет по умолчанию, а IcedTea-Web без этого параметра — нет
# (из-за чего возникает ошибка "Could not read or parse the JNLP file").
log "[6/6] Запуск EMS-апплета..."
if [[ -n "${DISPLAY:-}" ]]; then
    runuser -u "$TARGET_USER" -- javaws -allowredirect "$JNLP_URL" &
    log "EMS-апплет запущен. Используйте учётные данные, выданные при установке SoftWLC."
else
    log "Графическая сессия не обнаружена. Файл загружен: $JNLP_FILE"
    log "Запустите вручную под пользователем ${TARGET_USER}: javaws -allowredirect \"$JNLP_URL\""
fi
