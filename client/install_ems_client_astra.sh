#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоматизированная установка EMS-апплета SoftWLC (клиент)
# Целевая ОС: Astra Linux 1.7.6.15
#
# Отличия от сценария для Ubuntu:
#   - JDK 17 устанавливается из архива (tar.gz), так как
#     в штатном репозитории Astra Linux нет подходящей версии;
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
# Использование:
#   Вариант 1 (интерактивный — IP сервера вводится с клавиатуры):
#     sudo ./install_ems_client_astra.sh
#   Вариант 2 (адрес передаётся аргументом, без вопросов):
#     sudo ./install_ems_client_astra.sh http://192.168.1.23:8080/ems/jws
#
# Источники компонентов (необязательно, для офлайн-установки):
#   sudo JDK_TARBALL=/путь/к/jdk17.tar.gz \
#        ICEDTEA_ZIP=/путь/к/icedtea-web-1.8.8.linux.bin.zip \
#        ./install_ems_client_astra.sh <URL_JNLP>
# ============================================================

JNLP_URL="${1:-}"

JDK_VERSION="jdk-17.0.14+7"
JDK_TARBALL="${JDK_TARBALL:-}"
JDK_URL="${JDK_URL:-https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.14%2B7/OpenJDK17U-jdk_x64_linux_hotspot_17.0.14_7.tar.gz}"
JVM_DIR="/usr/lib/jvm"
JAVA_HOME_DIR="${JVM_DIR}/${JDK_VERSION}"

ICEDTEA_DIR="/opt/icedtea"
ICEDTEA_ZIP="${ICEDTEA_ZIP:-}"
ICEDTEA_URL="${ICEDTEA_URL:-https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.linux.bin.zip}"

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
fail() { echo -e "[ОШИБКА] $*" >&2; exit 1; }

# --- 1. Предварительные проверки -----------------------------------
[[ $EUID -eq 0 ]] || fail "Запустите скрипт через sudo."
[[ -n "${SUDO_USER:-}" ]] || fail "Не удалось определить пользователя, запустившего sudo."

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

TARGET_USER="$SUDO_USER"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
DOWNLOAD_DIR="${TARGET_HOME}/Downloads"
mkdir -p "$DOWNLOAD_DIR"

apt-get update -y || log "[ВНИМАНИЕ] Не удалось обновить списки пакетов, продолжаем."
apt-get install -y wget unzip ca-certificates || true

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 2. Установка JDK 17 из архива -----------------------------------
if [[ -d "$JAVA_HOME_DIR" ]]; then
    log "[1/6] JDK 17 уже установлен в ${JAVA_HOME_DIR}, пропуск загрузки."
    log "[2/6] Настройка окружения..."
else
    log "[1/6] Получение JDK 17..."
    if [[ -n "$JDK_TARBALL" && -f "$JDK_TARBALL" ]]; then
        log "Используется локальный архив: $JDK_TARBALL"
        cp "$JDK_TARBALL" "$TMP_DIR/jdk17.tar.gz"
    else
        log "Загрузка JDK 17: $JDK_URL"
        wget -O "$TMP_DIR/jdk17.tar.gz" "$JDK_URL" \
            || fail "Не удалось загрузить JDK. Укажите локальный архив через JDK_TARBALL."
    fi

    log "[2/6] Распаковка JDK в ${JVM_DIR} и настройка окружения..."
    mkdir -p "$JVM_DIR"
    tar -xzf "$TMP_DIR/jdk17.tar.gz" -C "$JVM_DIR/"
    [[ -d "$JAVA_HOME_DIR" ]] || fail "После распаковки не найден каталог ${JAVA_HOME_DIR}.
Проверьте версию архива (ожидается ${JDK_VERSION})."
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
java -version

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
            || fail "Не удалось загрузить IcedTea-Web. Укажите локальный архив через ICEDTEA_ZIP."
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
wget -O "$JNLP_FILE" "$JNLP_URL" \
    || fail "Не удалось загрузить JNLP-файл. Проверьте доступность сервера SoftWLC."
chown "${TARGET_USER}:${TARGET_USER}" "$JNLP_FILE"

# --- 6. Запуск EMS-апплета ----------------------------------------------
log "[6/6] Запуск EMS-апплета..."
if [[ -n "${DISPLAY:-}" ]]; then
    runuser -u "$TARGET_USER" -- javaws "$JNLP_FILE" &
    log "EMS-апплет запущен. Используйте учётные данные, выданные при установке SoftWLC."
else
    log "Графическая сессия не обнаружена. Файл загружен: $JNLP_FILE"
    log "Запустите вручную под пользователем ${TARGET_USER}: javaws \"$JNLP_FILE\""
fi
