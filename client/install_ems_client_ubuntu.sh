#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоматизированная установка EMS-апплета SoftWLC (клиент)
# Целевая ОС: Ubuntu 22.04 LTS (Desktop)
#
# Скрипт выполняет:
#   1) установку OpenJDK 17 из репозитория ОС;
#   2) настройку Java 17 в качестве версии по умолчанию;
#   3) установку IcedTea-Web 1.8.8 (из локального ZIP-архива
#      или по указанному URL);
#   4) настройку альтернатив javaws / itweb-settings / policyeditor;
#   5) загрузку ems_gui.jnlp с сервера и запуск EMS-апплета.
#
# Использование:
#   Вариант 1 (интерактивный — IP сервера вводится с клавиатуры):
#     sudo ./install_ems_client_ubuntu.sh
#   Вариант 2 (адрес передаётся аргументом, без вопросов):
#     sudo ./install_ems_client_ubuntu.sh http://192.168.1.23:8080/ems/jws
#
# Источник IcedTea-Web (необязательно):
#   sudo ICEDTEA_ZIP=/путь/к/icedtea-web-1.8.8.linux.bin.zip ./install_ems_client_ubuntu.sh <URL_JNLP>
#   sudo ICEDTEA_URL=https://.../icedtea-web-1.8.8.linux.bin.zip ./install_ems_client_ubuntu.sh <URL_JNLP>
# ============================================================

JNLP_URL="${1:-}"
ICEDTEA_DIR="/opt/icedtea"
ICEDTEA_DEFAULT_URL="https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.linux.bin.zip"
ICEDTEA_ZIP="${ICEDTEA_ZIP:-}"
ICEDTEA_URL="${ICEDTEA_URL:-$ICEDTEA_DEFAULT_URL}"

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

# --- 2. Установка Java 17 -------------------------------------------
log "[1/6] Проверка наличия OpenJDK 17..."
wait_for_apt
apt-get update -y
if dpkg -s openjdk-17-jdk >/dev/null 2>&1; then
    log "OpenJDK 17 уже установлен, пропуск установки."
    apt-get install -y unzip wget ca-certificates
else
    log "Установка OpenJDK 17..."
    apt-get install -y openjdk-17-jdk unzip wget ca-certificates
fi

JAVA_HOME_DIR="/usr/lib/jvm/java-17-openjdk-amd64"
JAVA_BIN="${JAVA_HOME_DIR}/bin/java"
[[ -x "$JAVA_BIN" ]] || fail "Не найден ${JAVA_BIN}. Проверьте архитектуру и пакет openjdk-17-jdk."

log "[2/6] Настройка Java 17 по умолчанию..."
update-alternatives --set java "$JAVA_BIN" || true
[[ -e /usr/lib/jvm/default-java ]] || ln -s "$JAVA_HOME_DIR" /usr/lib/jvm/default-java
java -version

# --- 3. Установка IcedTea-Web ---------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
            || fail "Не удалось загрузить IcedTea-Web. Укажите локальный архив через ICEDTEA_ZIP."
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

# --- 6. Запуск EMS-апплета --------------------------------------------
log "[6/6] Запуск EMS-апплета..."
if [[ -n "${DISPLAY:-}" ]]; then
    runuser -u "$TARGET_USER" -- javaws "$JNLP_FILE" &
    log "EMS-апплет запущен. Используйте учётные данные, выданные при установке SoftWLC."
else
    log "Графическая сессия не обнаружена. Файл загружен: $JNLP_FILE"
    log "Запустите вручную под пользователем ${TARGET_USER}: javaws \"$JNLP_FILE\""
fi
