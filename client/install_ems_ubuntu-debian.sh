#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоматизированная установка EMS-апплета SoftWLC (клиент)
# Целевые ОС: семейство Debian/Ubuntu.
#   - Онлайн-режим: Ubuntu 20.04+ и Debian 11+ (где в репозитории
#     присутствует пакет openjdk-17-jdk);
#   - Офлайн-режим: работает и на более старых версиях (Ubuntu 18.04,
#     Debian 10), т.к. JDK ставится из локального архива и не зависит
#     от репозитория.
# Поддерживаемые архитектуры: amd64 (полностью), arm64/armhf/i386
#   для JDK; для IcedTea-Web на не-amd64 см. примечание в разделе 3.
#
# Скрипт выполняет:
#   1) установку OpenJDK 17 (из репозитория ОС либо из локального архива);
#   2) настройку Java 17 в качестве версии по умолчанию;
#   3) установку IcedTea-Web 1.8.8 (из локального ZIP-архива
#      или по указанному URL);
#   4) настройку альтернатив javaws / itweb-settings / policyeditor;
#   5) загрузку ems_gui.jnlp с сервера и запуск EMS-апплета.
#
# Использование:
#   Вариант 1 (интерактивный — IP сервера вводится с клавиатуры):
#     sudo ./install_ems_client_ubuntu.sh
#     (дополнительно интерактивно предлагается выбрать режим: онлайн или офлайн)
#   Вариант 2 (адрес передаётся аргументом, без вопросов):
#     sudo ./install_ems_client_ubuntu.sh http://192.168.1.23:8080/ems/jws
#
# Режим установки компонентов выбирается интерактивно:
#   - онлайн: Java (openjdk-17-jdk) и IcedTea-Web загружаются из сети;
#   - офлайн: оба компонента берутся из локальных архивов (JDK 17 .tar.gz
#     и icedtea-web-1.8.8.linux.bin.zip), заранее скачанных на клиент.
# ============================================================

JNLP_URL="${1:-}"
ICEDTEA_DIR="/opt/icedtea"
ICEDTEA_URL="https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.linux.bin.zip"

# Подсказка по версии JDK для офлайн-режима (используется только в тексте
# приглашений). Фактический каталог распаковки определяется из самого архива,
# поэтому подходит любая сборка JDK 17.x, не только указанная здесь.
JDK_VERSION_HINT="jdk-17.0.14+7"
JVM_DIR="/usr/lib/jvm"

# Пути к локальным архивам. Заполняются только при выборе офлайн-режима
# в интерактивном диалоге (см. ниже). По умолчанию пусты.
ICEDTEA_ZIP=""
JDK_TARBALL=""

# Режим установки: online (по умолчанию) либо offline. Определяется в диалоге.
INSTALL_MODE_KIND="online"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

# Преобразует введённый путь в путь к файлу. Принимает:
#   - путь к существующему файлу — возвращает его как есть;
#   - путь к каталогу — ищет в нём файл по маске (второй аргумент).
# При неоднозначности или отсутствии файла возвращает ненулевой код,
# выводя пояснение, чтобы вызывающий цикл повторил запрос.
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

# Скрипт использует apt-get и update-alternatives — инструменты семейства
# Debian/Ubuntu. На других семействах (Fedora/RHEL, openSUSE, Arch) их нет,
# поэтому выполнение там приведёт к ошибкам. Проверяем принадлежность к семейству.
if ! command -v apt-get >/dev/null 2>&1 || [[ ! -f /etc/debian_version ]]; then
    fail "Скрипт рассчитан на семейство Debian/Ubuntu (Ubuntu, Debian, Astra Linux и совместимые).
Текущая система не определяется как Debian-совместимая (нет apt-get или /etc/debian_version)."
fi

# Архитектура пакетов Debian/Ubuntu (amd64, arm64, armhf, i386, ...).
# Используется для построения пути к системному OpenJDK, чтобы скрипт
# не был жёстко привязан к amd64.
DPKG_ARCH="$(dpkg --print-architecture)"
log "Обнаружена система: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Debian-совместимая}"), архитектура ${DPKG_ARCH}."

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

# Предлагаем выбрать режим установки компонентов: онлайн или офлайн.
# В офлайн-режиме запрашивается путь к локальному архиву IcedTea-Web.
if [[ -e /dev/tty ]]; then
    echo ""
    echo "Выберите режим установки компонентов:"
    echo "  1) Онлайн  — загрузка из сети Интернет (по умолчанию)"
    echo "  2) Офлайн  — установка из локальных файлов (для изолированной сети)"
    read -rp "Ваш выбор [1/2]: " INSTALL_MODE </dev/tty
    if [[ "$INSTALL_MODE" == "2" ]]; then
        INSTALL_MODE_KIND="offline"
        echo "Для офлайн-установки нужны два заранее скачанных архива:"
        echo "  - JDK 17 под вашу архитектуру (${DPKG_ARCH}), формат .tar.gz;"
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

# --- 2. Установка Java 17 -------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$INSTALL_MODE_KIND" == "offline" ]]; then
    # Офлайн-режим: JDK 17 устанавливается из локального архива
    # (так же, как на Astra Linux), без обращения к репозиторию.
    # Имя корневого каталога внутри архива определяем из самого архива,
    # поэтому подходит любая сборка JDK 17.x и любая архитектура.
    JDK_TOPDIR="$(tar -tzf "$JDK_TARBALL" 2>/dev/null | head -1 || true)"
    JDK_TOPDIR="${JDK_TOPDIR%%/*}"
    [[ -n "$JDK_TOPDIR" ]] || fail "Не удалось прочитать содержимое архива JDK: $JDK_TARBALL"
    JAVA_HOME_DIR="${JVM_DIR}/${JDK_TOPDIR}"

    if [[ -d "$JAVA_HOME_DIR" ]]; then
        log "[1/6] JDK уже установлен в ${JAVA_HOME_DIR}, пропуск распаковки."
    else
        log "[1/6] Установка JDK 17 из локального архива (каталог: ${JDK_TOPDIR})..."
        mkdir -p "$JVM_DIR"
        tar -xzf "$JDK_TARBALL" -C "$JVM_DIR/" \
            || fail "Не удалось распаковать архив JDK: $JDK_TARBALL"
        [[ -d "$JAVA_HOME_DIR" ]] || fail "После распаковки не найден каталог ${JAVA_HOME_DIR}."
    fi

    [[ -x "${JAVA_HOME_DIR}/bin/java" ]] \
        || fail "В распакованном JDK не найден исполняемый файл bin/java. Проверьте архив (${JDK_TARBALL})."

    log "[2/6] Настройка Java 17 по умолчанию..."
    # Переменные окружения для всех пользователей системы
    cat > /etc/profile.d/java.sh <<PROF
export JAVA_HOME=${JAVA_HOME_DIR}
export PATH=\$JAVA_HOME/bin:\$PATH
PROF
    chmod +x /etc/profile.d/java.sh
    # shellcheck disable=SC1091
    source /etc/profile.d/java.sh
    update-alternatives --install /usr/bin/java  java  "${JAVA_HOME_DIR}/bin/java"  2000
    update-alternatives --install /usr/bin/javac javac "${JAVA_HOME_DIR}/bin/javac" 2000
    update-alternatives --set java  "${JAVA_HOME_DIR}/bin/java"
    update-alternatives --set javac "${JAVA_HOME_DIR}/bin/javac"
else
    # Онлайн-режим: Java ставится из штатного репозитория Debian/Ubuntu.
    log "[1/6] Проверка наличия OpenJDK 17..."
    wait_for_apt
    apt_update_checked

    # Не во всех версиях есть пакет openjdk-17 (например, Ubuntu 18.04, Debian 10).
    # Проверяем доступность пакета в репозитории до попытки установки, чтобы
    # выдать понятное пояснение вместо неочевидной ошибки apt.
    if ! apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
        fail "В репозитории этой версии ОС нет пакета openjdk-17-jdk.
Вероятно, версия дистрибутива слишком старая (например, Ubuntu 18.04 или Debian 10).
Перезапустите скрипт и выберите офлайн-режим (пункт 2), указав заранее скачанный
архив JDK 17 (.tar.gz) — он не зависит от репозитория и ставится на любой версии."
    fi

    if dpkg -s openjdk-17-jdk >/dev/null 2>&1; then
        log "OpenJDK 17 уже установлен, пропуск установки."
        DEBIAN_FRONTEND=noninteractive apt-get install -y unzip wget ca-certificates
    else
        log "Установка OpenJDK 17..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jdk unzip wget ca-certificates
    fi

    # Путь к JDK строится по архитектуре системы (amd64, arm64, armhf, ...),
    # а не жёстко как amd64. Если по ожидаемому пути ничего нет — ищем
    # фактический каталог java-17-openjdk-* как подстраховку.
    JAVA_HOME_DIR="${JVM_DIR}/java-17-openjdk-${DPKG_ARCH}"
    if [[ ! -d "$JAVA_HOME_DIR" ]]; then
        JAVA_HOME_DIR="$(find "$JVM_DIR" -maxdepth 1 -type d -name 'java-17-openjdk-*' 2>/dev/null | head -1 || true)"
    fi
    JAVA_BIN="${JAVA_HOME_DIR}/bin/java"
    [[ -x "$JAVA_BIN" ]] || fail "Не найден исполняемый файл java в ${JAVA_HOME_DIR}. Проверьте установку openjdk-17-jdk."

    log "[2/6] Настройка Java 17 по умолчанию..."
    update-alternatives --install /usr/bin/java java "$JAVA_BIN" 2000
    update-alternatives --set java "$JAVA_BIN" || true
    if [[ -x "${JAVA_HOME_DIR}/bin/javac" ]]; then
        update-alternatives --install /usr/bin/javac javac "${JAVA_HOME_DIR}/bin/javac" 2000
        update-alternatives --set javac "${JAVA_HOME_DIR}/bin/javac" || true
    fi
    [[ -e "${JVM_DIR}/default-java" ]] || ln -s "$JAVA_HOME_DIR" "${JVM_DIR}/default-java"
fi
java -version

# В офлайн-режиме пакеты не устанавливались через apt — проверим,
# что необходимые утилиты (unzip для распаковки, wget для загрузки
# JNLP-файла с сервера) уже присутствуют в системе.
if [[ "$INSTALL_MODE_KIND" == "offline" ]]; then
    for tool in unzip wget; do
        command -v "$tool" >/dev/null 2>&1 \
            || fail "Утилита '$tool' не найдена. В офлайн-режиме она должна быть установлена заранее (sudo apt install $tool)."
    done
fi

# --- 3. Установка IcedTea-Web ---------------------------------------
# Примечание о совместимости: штатный бинарный архив IcedTea-Web 1.8.8
# собран под x86-64 (amd64). На других архитектурах он не запустится —
# для них используйте пакет из репозитория (sudo apt install icedtea-netx)
# либо локальный архив IcedTea-Web под вашу архитектуру (офлайн-режим).
if [[ "$DPKG_ARCH" != "amd64" && -z "$ICEDTEA_ZIP" ]]; then
    log "[ВНИМАНИЕ] Архитектура — ${DPKG_ARCH}, а штатный IcedTea-Web 1.8.8 собран под amd64"
    log "           и может не запуститься. Рекомендуется: sudo apt install icedtea-netx,"
    log "           либо укажите локальный архив IcedTea-Web под ${DPKG_ARCH} (офлайн-режим)."
fi

if [[ -x "${ICEDTEA_DIR}/icedtea-web-image/bin/javaws" ]]; then
    log "[3/6] IcedTea-Web уже установлен в ${ICEDTEA_DIR}, пропуск загрузки и распаковки."
else
    log "[3/6] Установка IcedTea-Web 1.8.8..."
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

# --- 4. Настройка альтернатив IcedTea-Web ----------------------------
log "[4/6] Настройка системных альтернатив IcedTea-Web..."
for tool in javaws itweb-settings policyeditor; do
    update-alternatives --install "/usr/bin/${tool}" "$tool" \
        "${ICEDTEA_DIR}/icedtea-web-image/bin/${tool}" 1500
    update-alternatives --set "$tool" "${ICEDTEA_DIR}/icedtea-web-image/bin/${tool}"
done

javaws --version || true
rm -rf "${TARGET_HOME}/.cache/icedtea-web/cache/" || true

# --- 5. Загрузка JNLP-файла -------------------------------------------
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

# --- 6. Запуск EMS-апплета --------------------------------------------
log "[6/6] Запуск EMS-апплета..."
if [[ -n "${DISPLAY:-}" ]]; then
    runuser -u "$TARGET_USER" -- javaws "$JNLP_FILE" &
    log "EMS-апплет запущен. Используйте учётные данные, выданные при установке SoftWLC."
else
    log "Графическая сессия не обнаружена. Файл загружен: $JNLP_FILE"
    log "Запустите вручную под пользователем ${TARGET_USER}: javaws \"$JNLP_FILE\""
fi
