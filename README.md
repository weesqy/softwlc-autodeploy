# Автоматизированное развёртывание SoftWLC

Набор сценариев для автоматизированного развёртывания программного контроллера
беспроводной сети SoftWLC, приложения для проверки лабораторных работ
и клиентских узлов с EMS-апплетом.

## Состав репозитория

| Сценарий | Назначение | Целевая ОС |
|---|---|---|
| `server/install_softwlc_server.sh` | Установка контроллера SoftWLC | Ubuntu Server 22.04 |
| `server/install_labcheck_server.sh` | Установка приложения проверки лабораторных работ (Node.js 20, systemd-служба) | Ubuntu Server 22.04 |
| `server/app.js` | Приложение для проверки лабораторных работ | — |
| `client/install_ems_client_ubuntu.sh` | Установка EMS-апплета (Java 17, IcedTea-Web) | Ubuntu 22.04 |
| `client/install_ems_client_astra.sh` | Установка EMS-апплета (Java 17, IcedTea-Web) | Astra Linux 1.7.6 |

## Развёртывание сервера

Выполняется на сервере в два шага:

```bash
# 1. Контроллер SoftWLC
wget -qO- https://raw.githubusercontent.com/ЛОГИН/softwlc-autodeploy/main/server/install_softwlc_server.sh | sudo bash

# 2. Приложение проверки лабораторных работ
wget -qO- https://raw.githubusercontent.com/ЛОГИН/softwlc-autodeploy/main/server/install_labcheck_server.sh | sudo bash
```

После установки:
- EMS-апплет раздаётся по адресу `http://<ip-сервера>:8080/ems/jws`
- приложение проверки доступно по адресу `http://<ip-сервера>:9090`

## Развёртывание клиентского узла

### Ubuntu 22.04

```bash
wget -qO- https://raw.githubusercontent.com/ЛОГИН/softwlc-autodeploy/main/client/install_ems_client_ubuntu.sh | sudo bash
```

### Astra Linux 1.7.6

```bash
wget -qO- https://raw.githubusercontent.com/ЛОГИН/softwlc-autodeploy/main/client/install_ems_client_astra.sh | sudo bash
```

Сценарий запросит IP-адрес сервера SoftWLC, проверит его доступность,
после чего установит все компоненты и запустит EMS-апплет.

Для полностью автоматического режима (без вопросов) адрес передаётся аргументом:

```bash
wget -qO- https://raw.githubusercontent.com/ЛОГИН/softwlc-autodeploy/main/client/install_ems_client_ubuntu.sh | sudo bash -s -- http://192.168.1.23:8080/ems/jws
```

## Офлайн-установка (изолированные стенды)

Клиентские сценарии поддерживают установку из локальных архивов
без доступа в интернет:

```bash
sudo JDK_TARBALL=/путь/к/jdk17.tar.gz \
     ICEDTEA_ZIP=/путь/к/icedtea-web-1.8.8.linux.bin.zip \
     ./install_ems_client_astra.sh http://192.168.1.23:8080/ems/jws
```

(Параметр `JDK_TARBALL` используется только сценарием для Astra Linux.)
