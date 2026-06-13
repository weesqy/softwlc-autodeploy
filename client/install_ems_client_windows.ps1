<#
============================================================
 Автоматизированная установка EMS-апплета SoftWLC (клиент)
 Целевая ОС: Windows 10 / 11 (x64)

 Скрипт выполняет:
   1) установку Java 17 (Oracle JDK, MSI, тихий режим);
   2) установку IcedTea-Web 1.8.8 (MSI, тихий режим);
   3) ассоциацию файлов *.jnlp с приложением javaws;
   4) загрузку ems_gui.jnlp с сервера SoftWLC;
   5) запуск EMS-апплета.

 Использование (PowerShell от имени администратора):
   Вариант 1 (интерактивный — IP сервера вводится с клавиатуры):
     powershell -ExecutionPolicy Bypass -File install_ems_client_windows.ps1
   Вариант 2 (адрес передаётся параметром, без вопросов):
     powershell -ExecutionPolicy Bypass -File install_ems_client_windows.ps1 -JnlpUrl http://192.168.1.23:8080/ems/jws

 Офлайн-режим (установка из локальных MSI-файлов):
     powershell -ExecutionPolicy Bypass -File install_ems_client_windows.ps1 `
         -JdkMsi C:\dist\jdk-17.0.12_windows-x64_bin.msi `
         -IcedTeaMsi C:\dist\icedtea-web-1.8.8.msi
============================================================
#>

param(
    [string]$JnlpUrl    = "",
    [string]$JdkUrl     = "https://download.oracle.com/java/17/archive/jdk-17.0.12_windows-x64_bin.msi",
    [string]$IcedTeaUrl = "https://github.com/AdoptOpenJDK/IcedTea-Web/releases/download/icedtea-web-1.8.8/icedtea-web-1.8.8.msi",
    [string]$JdkMsi     = "",   # локальный MSI-файл JDK (офлайн-режим)
    [string]$IcedTeaMsi = ""    # локальный MSI-файл IcedTea-Web (офлайн-режим)
)

$ErrorActionPreference = "Stop"
# Отключение индикатора прогресса многократно ускоряет Invoke-WebRequest
$ProgressPreference    = "SilentlyContinue"

function Log([string]$msg)  { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg) }
function Fail([string]$msg) { Write-Host ("[ОШИБКА] {0}" -f $msg) -ForegroundColor Red; exit 1 }

# Преобразует введённый путь в путь к файлу. Принимает путь к файлу
# (возвращает как есть) либо к папке (ищет в ней файл по маске).
# При неоднозначности или отсутствии файла возвращает $null с пояснением.
function Resolve-LocalFile([string]$inputPath, [string]$mask) {
    $p = $inputPath.Trim('"').TrimEnd('\')
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    if (Test-Path -LiteralPath $p -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $p -Filter $mask -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) { return $found[0].FullName }
        elseif ($found.Count -eq 0) {
            Write-Host "В папке $p не найден файл по шаблону $mask. Попробуйте ещё раз."
            return $null
        } else {
            Write-Host "В папке $p найдено несколько подходящих файлов:"
            $found | ForEach-Object { Write-Host ("  " + $_.FullName) }
            Write-Host "Укажите полный путь к нужному файлу."
            return $null
        }
    }
    Write-Host "Путь не существует: $p. Попробуйте ещё раз."
    return $null
}

# Установка MSI-пакета в тихом режиме с контролем кода возврата
function Install-Msi([string]$path, [string]$name) {
    Log "Установка ${name} (тихий режим)..."
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$path`" /qn /norestart" -Wait -PassThru
    # 0 — успех; 3010 — успех, требуется перезагрузка
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Fail "Установка ${name} завершилась с кодом $($proc.ExitCode)."
    }
    Log "  [OK] ${name} установлен."
}

# --- 1. Предварительные проверки -----------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Запустите PowerShell от имени администратора."
}

# Современный TLS для загрузок (актуально для Windows PowerShell 5.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 2. Запрос и проверка адреса сервера -----------------------------
if (-not $JnlpUrl) {
    while ($true) {
        $serverIp = Read-Host "Введите IP-адрес сервера SoftWLC (например, 192.168.1.23)"
        if ($serverIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            Write-Host "Некорректный формат IP-адреса, попробуйте ещё раз."
            continue
        }
        $JnlpUrl = "http://${serverIp}:8080/ems/jws"
        Log "Проверка доступности сервера ${JnlpUrl}..."
        $reachable = Test-NetConnection -ComputerName $serverIp -Port 8080 `
                     -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($reachable) { Log "Сервер SoftWLC доступен."; break }
        $answer = Read-Host "Сервер не отвечает. Продолжить с этим адресом? [y/N]"
        if ($answer -match '^[YyДд]$') { break }
    }
}

# Если установщики не заданы заранее (-JdkMsi / -IcedTeaMsi), предлагаем
# выбрать режим установки компонентов: онлайн или офлайн. В офлайн-режиме
# запрашиваются пути к локальным MSI-пакетам JDK и IcedTea-Web.
if (-not $JdkMsi -and -not $IcedTeaMsi) {
    Write-Host ""
    Write-Host "Выберите режим установки компонентов:"
    Write-Host "  1) Онлайн  - загрузка из сети Интернет (по умолчанию)"
    Write-Host "  2) Офлайн  - установка из локальных файлов (для изолированной сети)"
    $installMode = Read-Host "Ваш выбор [1/2]"
    if ($installMode -eq "2") {
        Write-Host "Можно указать путь к файлу либо к папке, в которой он находится."
        while ($true) {
            Write-Host "Установщик JDK 17 (jdk-17.0.12_windows-x64_bin.msi)."
            Write-Host "  Пример файла: C:\Users\$env:USERNAME\Downloads\jdk-17.0.12_windows-x64_bin.msi"
            Write-Host "  Пример папки: C:\Users\$env:USERNAME\Downloads"
            $jdkInput = Read-Host "Путь"
            $JdkMsi = Resolve-LocalFile $jdkInput "jdk-17*windows*.msi"
            if ($JdkMsi) { Write-Host "Установщик JDK найден: $JdkMsi"; break }
        }
        while ($true) {
            Write-Host "Установщик IcedTea-Web (icedtea-web-1.8.8.msi)."
            Write-Host "  Пример файла: C:\Users\$env:USERNAME\Downloads\icedtea-web-1.8.8.msi"
            Write-Host "  Пример папки: C:\Users\$env:USERNAME\Downloads"
            $icedInput = Read-Host "Путь"
            $IcedTeaMsi = Resolve-LocalFile $icedInput "icedtea-web-*.msi"
            if ($IcedTeaMsi) { Write-Host "Установщик IcedTea-Web найден: $IcedTeaMsi"; break }
        }
        Log "Выбран офлайн-режим установки компонентов."
    } else {
        Log "Выбран онлайн-режим установки компонентов."
    }
}

$tmpDir = Join-Path $env:TEMP "softwlc-client"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

# --- 3. Установка Java 17 ---------------------------------------------
Log "[1/5] Проверка наличия JDK 17..."
$jdkInstalled = Get-ChildItem "C:\Program Files\Java" -Directory -Filter "jdk-17*" -ErrorAction SilentlyContinue
if ($jdkInstalled) {
    Log "JDK 17 уже установлен ($($jdkInstalled[0].Name)), пропуск."
} else {
    if ($JdkMsi -and (Test-Path $JdkMsi)) {
        Log "Используется локальный установщик: $JdkMsi"
        $jdkPath = $JdkMsi
    } else {
        $jdkPath = Join-Path $tmpDir "jdk17.msi"
        Log "Загрузка JDK 17: $JdkUrl"
        try { Invoke-WebRequest -Uri $JdkUrl -OutFile $jdkPath -UseBasicParsing }
        catch { Fail "Не удалось загрузить JDK. Укажите локальный файл параметром -JdkMsi." }
    }
    Install-Msi $jdkPath "Oracle JDK 17"
}

# --- 4. Установка IcedTea-Web ------------------------------------------
Log "[2/5] Проверка наличия IcedTea-Web..."
$javawsKnown = @(
    "C:\Program Files\IcedTea-Web\bin\javaws.exe",
    "C:\Program Files (x86)\IcedTea-Web\bin\javaws.exe",
    "C:\Program Files\AdoptOpenJDK\IcedTea-Web\bin\javaws.exe"
)
$javaws = $javawsKnown | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($javaws) {
    Log "IcedTea-Web уже установлен, пропуск."
} else {
    if ($IcedTeaMsi -and (Test-Path $IcedTeaMsi)) {
        Log "Используется локальный установщик: $IcedTeaMsi"
        $icedteaPath = $IcedTeaMsi
    } else {
        $icedteaPath = Join-Path $tmpDir "icedtea-web.msi"
        Log "Загрузка IcedTea-Web 1.8.8: $IcedTeaUrl"
        try { Invoke-WebRequest -Uri $IcedTeaUrl -OutFile $icedteaPath -UseBasicParsing }
        catch { Fail "Не удалось загрузить IcedTea-Web. Укажите локальный файл параметром -IcedTeaMsi." }
    }
    Install-Msi $icedteaPath "IcedTea-Web 1.8.8"
    $javaws = $javawsKnown | Where-Object { Test-Path $_ } | Select-Object -First 1
}

# Если javaws не найден по типовым путям — поиск по каталогу Program Files
if (-not $javaws) {
    Log "Поиск javaws.exe в каталоге Program Files..."
    $found = Get-ChildItem "C:\Program Files" -Recurse -Filter "javaws.exe" `
             -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $javaws = $found.FullName }
}
if (-not $javaws) { Fail "Не удалось найти javaws.exe после установки IcedTea-Web." }
Log "Приложение javaws: $javaws"

# --- 5. Ассоциация файлов *.jnlp с javaws --------------------------------
Log "[3/5] Настройка ассоциации файлов *.jnlp с javaws..."
cmd /c "assoc .jnlp=JNLPFile" | Out-Null
cmd /c "ftype JNLPFile=`"$javaws`" `"%1`"" | Out-Null
Log "  [OK] Файлы *.jnlp ассоциированы с javaws."

# Очистка кэша IcedTea-Web: устаревший или повреждённый кэш приводит
# к ошибке "Не удалось прочитать или обработать файл JNLP"
$itwCache = Join-Path $env:USERPROFILE ".cache\icedtea-web\cache"
if (Test-Path $itwCache) {
    Log "Очистка кэша IcedTea-Web..."
    Remove-Item $itwCache -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 6. Загрузка JNLP-файла -----------------------------------------------
Log "[4/5] Загрузка ems_gui.jnlp с ${JnlpUrl}..."
$downloads = Join-Path ([Environment]::GetFolderPath('UserProfile')) "Downloads"
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$jnlpFile = Join-Path $downloads "ems_gui.jnlp"
# Сервер отдаёт корректный JNLP только после полного запуска EMS:
# проверяем содержимое файла и при необходимости повторяем загрузку
$jnlpOk = $false
for ($attempt = 1; $attempt -le 10; $attempt++) {
    try { Invoke-WebRequest -Uri $JnlpUrl -OutFile $jnlpFile -UseBasicParsing } catch {}
    if ((Test-Path $jnlpFile) -and ((Get-Item $jnlpFile).Length -gt 0) -and
        (Select-String -Path $jnlpFile -Pattern '<jnlp' -Quiet)) {
        $jnlpOk = $true
        break
    }
    Log "EMS-сервер ещё не готов (попытка $attempt из 10), повтор через 15 секунд..."
    Start-Sleep -Seconds 15
}
if (-not $jnlpOk) {
    Fail "Сервер не вернул корректный JNLP-файл. Убедитесь, что SoftWLC полностью запущен (после перезагрузки сервера запуск занимает несколько минут), и повторите."
}

# Удаление атрибута href из корневого тега <jnlp>. При наличии href
# javaws повторно загружает JNLP-файл с сервера в кэш, и на Windows
# IcedTea-Web 1.8.8 даёт сбой кэширования адреса без имени файла
# (FileNotFoundException). Без href используется локальный файл.
$jnlpText = Get-Content $jnlpFile -Raw
$patched  = $jnlpText -replace "(<jnlp\b[^>]*?)\s+href=(""[^""]*""|'[^']*')", '$1'
if ($patched -ne $jnlpText) {
    Set-Content -Path $jnlpFile -Value $patched -Encoding UTF8
    Log "Атрибут href удалён из JNLP-файла (обход сбоя кэша IcedTea-Web на Windows)."
}

# --- 7. Запуск EMS-апплета --------------------------------------------------
Log "[5/5] Запуск EMS-апплета..."
Start-Process -FilePath $javaws -ArgumentList "`"$jnlpFile`""
Log "EMS-апплет запущен. Используйте учётные данные, выданные при установке SoftWLC."
