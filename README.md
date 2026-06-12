# Автоматизированное развёртывание SoftWLC

Набор сценариев для автоматизированного развёртывания программного контроллера
беспроводной сети SoftWLC, приложения для проверки лабораторных работ
и клиентских узлов с EMS-апплетом.

## Состав репозитория

| Сценарий | Назначение | Целевая ОС |
|---|---|---|
| `server/install_softwlc_server.sh` | Установка контроллера SoftWLC | Ubuntu Server 22.04 |
| `server/install_labcheck_server.sh` | Установка приложения проверки лабораторных работ (Node.js 20, служба systemd) | Ubuntu Server 22.04 |
| `server/app.js` | Приложение для проверки лабораторных работ | — |
| `client/install_ems_client_ubuntu.sh` | Установка EMS-апплета (Java 17, IcedTea-Web 1.8.8) | Ubuntu 22.04 |
| `client/install_ems_client_astra.sh` | Установка EMS-апплета (Java 17, IcedTea-Web 1.8.8) | Astra Linux 1.7.6 |
| `client/install_ems_client_windows.ps1` | Установка EMS-апплета (Java 17, IcedTea-Web 1.8.8, ассоциация JNLP) | Windows 10 / 11 |

Все сценарии идемпотентны: повторный запуск безопасен, уже установленные
компоненты определяются и пропускаются с соответствующим сообщением.

## Развёртывание сервера

Выполняется на сервере в два шага:

```bash
# 1. Контроллер SoftWLC
wget https://raw.githubusercontent.com/weesqy/softwlc-autodeploy/main/server/install_softwlc_server.sh
sudo bash install_softwlc_server.sh

# 2. Приложение проверки лабораторных работ
wget https://raw.githubusercontent.com/weesqy/softwlc-autodeploy/main/server/install_labcheck_server.sh
sudo bash install_labcheck_server.sh
```

После установки:
- EMS-апплет раздаётся по адресу `http://<ip-сервера>:8080/ems/jws`
- приложение проверки доступно по адресу `http://<ip-сервера>:9090`
  (работает как служба systemd `labcheck`: автозапуск при загрузке,
  перезапуск при сбоях)

## Развёртывание клиентского узла

Сценарий запросит IP-адрес сервера SoftWLC, проверит его доступность,
после чего установит все компоненты и запустит EMS-апплет.

### Ubuntu 22.04

```bash
wget https://raw.githubusercontent.com/weesqy/softwlc-autodeploy/main/client/install_ems_client_ubuntu.sh
sudo bash install_ems_client_ubuntu.sh
```

### Astra Linux 1.7.6

```bash
wget https://raw.githubusercontent.com/weesqy/softwlc-autodeploy/main/client/install_ems_client_astra.sh
sudo bash install_ems_client_astra.sh
```

### Windows 10 / 11

В консоли PowerShell, запущенной от имени администратора:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/weesqy/softwlc-autodeploy/main/client/install_ems_client_windows.ps1 -OutFile $env:USERPROFILE\Downloads\install_ems_client_windows.ps1
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\Downloads\install_ems_client_windows.ps1
```

### Автоматический режим (без вопросов)

Адрес сервера можно передать аргументом — сценарий выполнится
без участия оператора:

```bash
sudo bash install_ems_client_ubuntu.sh http://192.168.1.23:8080/ems/jws
```

```powershell
powershell -ExecutionPolicy Bypass -File install_ems_client_windows.ps1 -JnlpUrl http://192.168.1.23:8080/ems/jws
```

## Офлайн-установка (изолированные стенды)

Клиентские сценарии поддерживают установку из локальных архивов
без доступа в интернет.

Astra Linux / Ubuntu:

```bash
sudo JDK_TARBALL=/путь/к/jdk17.tar.gz \
     ICEDTEA_ZIP=/путь/к/icedtea-web-1.8.8.linux.bin.zip \
     bash install_ems_client_astra.sh http://192.168.1.23:8080/ems/jws
```

(Параметр `JDK_TARBALL` используется только сценарием для Astra Linux.)

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File install_ems_client_windows.ps1 `
    -JdkMsi C:\dist\jdk-17.0.12_windows-x64_bin.msi `
    -IcedTeaMsi C:\dist\icedtea-web-1.8.8.msi
```

## Особенности и устранение неполадок

**Сервер недавно перезагружался.** После перезагрузки сервера службы SoftWLC
запускаются несколько минут; порт 8080 при этом открывается раньше, чем
EMS-сервер готов отдавать JNLP-файл. Клиентские сценарии учитывают это:
содержимое загруженного JNLP-файла проверяется, и при неготовности сервера
загрузка повторяется автоматически (до 10 попыток с интервалом 15 секунд)
с сообщением «EMS-сервер ещё не готов».

**Повторный запуск EMS-апплета.** Рекомендуемый способ повторного запуска
апплета — повторный запуск клиентского сценария: установка уже выполненных
компонентов будет пропущена, а перед запуском апплета сценарий очистит кэш
IcedTea-Web и загрузит актуальный JNLP-файл. Запуск апплета вручную без
очистки кэша может завершаться ошибкой чтения JNLP-файла (особенность
IcedTea-Web).

**Проверка состояния сервера:**

```bash
systemctl status labcheck          # приложение проверки
ss -tln | grep -E ':8080|:9090'    # порты EMS и приложения
journalctl -u labcheck -n 50       # журнал приложения
```
