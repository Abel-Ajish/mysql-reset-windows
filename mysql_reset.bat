@echo off
setlocal EnableExtensions
set "SELF_BAT=%~f0"
set "STAGE_DIR=%TEMP%\MySQLPasswordReset_%RANDOM%_%RANDOM%"
set "PS1_FILE=%STAGE_DIR%\reset_root.ps1"
if not exist "%STAGE_DIR%" mkdir "%STAGE_DIR%" >nul 2>&1
if not exist "%STAGE_DIR%" (
    echo [ERROR] Could not create "%STAGE_DIR%".
    rmdir "%STAGE_DIR%" >nul 2>&1
    exit /b 1
)
more +32 "%SELF_BAT%" > "%PS1_FILE%"
if errorlevel 1 (
    echo [ERROR] Failed to extract PowerShell script.
    if exist "%PS1_FILE%" del /f /q "%PS1_FILE%" >nul 2>&1 & rmdir "%STAGE_DIR%" >nul 2>&1
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%" -RunnerPs1 "%PS1_FILE%" %*
set "RC=%errorlevel%"
if exist "%PS1_FILE%" del /f /q "%PS1_FILE%"
if exist "%PS1_FILE%" (
    echo [ERROR] Could not remove temporary PowerShell file "%PS1_FILE%".
    if "%RC%"=="0" set "RC=1"
)
if exist "%STAGE_DIR%" rmdir "%STAGE_DIR%"
if exist "%STAGE_DIR%" (
    echo [ERROR] Could not remove temporary staging directory "%STAGE_DIR%".
    if "%RC%"=="0" set "RC=1"
)
if not "%RC%"=="0" echo [ERROR] PowerShell exited with code %RC%.
exit /b %RC%
:: === EMBEDDED POWERSHELL BELOW ===
param(
    [string]$RunnerPs1 = "",
    [string]$ServiceName = "",
    [string]$MySqlBin = "",
    [string]$DefaultsFile = "",
    [string]$LogDir = "$env:ProgramData\MySQLPasswordReset",
    [switch]$Elevated,
    [switch]$Preflight
)

$ErrorActionPreference = "Stop"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = $null
$initFile = $null
$script:loggingEnabled = $false
$script:runDir = $null
$tempStarted = $false
$script:tempProcess = $null
$serviceStopped = $false
$serviceWasRunning = $false
$script:plainPass = $null
$dbPort = 3306
$svcAccount = $null

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Message"
    Write-Host $line
    if ($script:loggingEnabled) {
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
}

function Stop-TemporaryMySqlProcess {
    if ($script:tempProcess -and -not $script:tempProcess.HasExited) {
        Write-Log "[WARN] Stopping only the temporary mysqld process started by this run..."
        Stop-Process -Id $script:tempProcess.Id -Force -ErrorAction Stop
        if (-not $script:tempProcess.WaitForExit(10000)) {
            throw "Temporary mysqld.exe process $($script:tempProcess.Id) did not exit."
        }
    }
}

function Get-MySqlServerArguments {
    param(
        [string]$DefaultsFile,
        [string]$InitFile
    )

    $arguments = @()
    if ($DefaultsFile) {
        $arguments += "--defaults-file=`"$DefaultsFile`""
    }
    $initPath = $InitFile -replace '\\', '/'
    $arguments += "--init-file=`"$initPath`""
    return $arguments
}

function Get-MySqlServerPort {
    param([string[]]$ConfigLines)

    $inServerSection = $false
    $serverPort = $null
    foreach ($line in $ConfigLines) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            $inServerSection = $Matches[1] -match '^(?i:server|mysqld(?:[.-]\d+(?:\.\d+)*)?)$'
            continue
        }
        if ($line -match '^\s*!(?:include|includedir)\b') {
            throw "MySQL config includes are not supported for automatic port detection. Specify a direct [mysqld] port setting or use -DefaultsFile with a non-included config."
        }
        if ($inServerSection -and $line -match '^\s*port\s*=') {
            if ($line -notmatch '^\s*port\s*=\s*(\d+)\s*(?:[#;].*)?$') {
                throw "Malformed MySQL server port setting in the [mysqld] section: '$line'."
            }
            $candidate = 0
            if (-not [int]::TryParse($Matches[1], [ref]$candidate) -or $candidate -lt 1 -or $candidate -gt 65535) {
                throw "Invalid MySQL server port '$($Matches[1])' in the [mysqld] section."
            }
            $serverPort = $candidate
        }
    }

    if ($null -eq $serverPort) {
        return 3306
    }
    return $serverPort
}

function Resolve-MySqlLogRoot {
    param(
        [string]$LogRoot,
        [string]$CommonDataRoot
    )

    $commonDataPath = [IO.Path]::GetFullPath($CommonDataRoot).TrimEnd('\')
    $requestedPath = [IO.Path]::GetFullPath($LogRoot).TrimEnd('\')
    if (-not $requestedPath.StartsWith($commonDataPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "LogDir must be a dedicated subdirectory beneath '$commonDataPath'."
    }
    return $requestedPath
}

function Get-MySqlServiceAccountPrincipal {
    param([string]$ServiceAccount)

    if ([string]::IsNullOrWhiteSpace($ServiceAccount)) {
        throw "The MySQL service account is empty."
    }
    switch -Regex ($ServiceAccount.Trim()) {
        '^(?:LocalSystem|SYSTEM|NT AUTHORITY\\SYSTEM)$' { return '*S-1-5-18' }
        '^(?:NT AUTHORITY\\LocalService|LocalService)$' { return '*S-1-5-19' }
        '^(?:NT AUTHORITY\\NetworkService|NetworkService)$' { return '*S-1-5-20' }
        default { return $ServiceAccount.Trim() }
    }
}

function Assert-ResetPassword {
    param([string]$Password)

    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw "Password cannot be empty or whitespace."
    }
    if ($Password.Length -lt 8) {
        throw "Password must be at least 8 characters."
    }
    foreach ($character in $Password.ToCharArray()) {
        $codePoint = [int]$character
        if ($codePoint -lt 32 -or $codePoint -gt 126) {
            throw "Password must contain printable ASCII characters only."
        }
    }
}

function New-PasswordResetSql {
    param([string]$Password)

    Assert-ResetPassword -Password $Password
    $sqlPassword = $Password.Replace("'", "''")
    return @(
        "SET SESSION sql_mode = IF(FIND_IN_SET('NO_BACKSLASH_ESCAPES', @@SESSION.sql_mode), @@SESSION.sql_mode, CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'NO_BACKSLASH_ESCAPES'));"
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '$sqlPassword';"
        "FLUSH PRIVILEGES;"
    ) -join [Environment]::NewLine
}

function Resolve-MySqlServiceName {
    param([string[]]$ServiceNames)

    if (-not $ServiceNames -or $ServiceNames.Count -eq 0) {
        throw "No Windows service starting with 'mysql' was found."
    }
    if ($ServiceNames.Count -gt 1) {
        throw "Multiple MySQL services were found: $($ServiceNames -join ', '). Pass -ServiceName to select one."
    }
    return $ServiceNames[0]
}

function Test-MySqlServiceImagePath {
    param(
        [string]$ImagePath,
        [string]$ServiceName
    )

    $remaining = $ImagePath -replace '^(?:"[^"]*mysqld\.exe"|[^\s"]*mysqld\.exe)\s*', ''
    $remaining = [regex]::Replace($remaining, '(?i)--defaults-file=(?:"[^"]+"|\S+)', '')
    $remaining = [regex]::Replace($remaining, '(?i)(^|\s)--local-service(?=\s|$)', '$1')
    $escapedServiceName = [regex]::Escape($ServiceName)
    $remaining = [regex]::Replace($remaining, "(?i)(^|\s)`"?$escapedServiceName`"?(?=\s|$)", '$1')
    if ($remaining.Trim()) {
        throw "Unsupported extra arguments in MySQL service ImagePath: '$($remaining.Trim())'. Remove them or move the options to the MySQL configuration file."
    }
}

function Fail-WithReport {
    param(
        [string]$Step,
        [int]$ExitCode,
        [string]$Reason,
        [string]$Fix
    )

    try {
        Write-Log "[FAILURE] Step='$Step' Code=$ExitCode Reason='$Reason'"
    } catch {
        Write-Warning "Audit log write failed: $($_.Exception.Message)"
    }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "[FAILURE REPORT] MySQL Password Reset Aborted" -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "Failed Step   : $Step"
    Write-Host "Exit Code     : $ExitCode"
    Write-Host "Reason        : $Reason"
    Write-Host "Suggested Fix : $Fix"
    Write-Host "Audit Log     : $logFile"
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "[RECOVERY] Cleaning up sensitive files and restoring state..." -ForegroundColor Yellow

    $script:plainPass = $null
    $env:MYSQL_PWD = $null

    if ($initFile -and (Test-Path -LiteralPath $initFile)) {
        try {
            [IO.File]::WriteAllText($initFile, ("0" * 256))
            Remove-Item -LiteralPath $initFile -Force
            Write-Host "  - [OK] Wiped and deleted temporary init SQL file."
        } catch {
            Write-Host "  - [WARN] Could not delete '$initFile'. Delete it manually immediately." -ForegroundColor Yellow
        }
    }

    if ($tempStarted) {
        try {
            Stop-TemporaryMySqlProcess
            Write-Host "  - [OK] Stopped temporary mysqld.exe process."
        } catch {
            Write-Host "  - [WARN] Temporary mysqld.exe may still be running. Check Task Manager." -ForegroundColor Yellow
        }
    }

    if ($serviceStopped -and $serviceWasRunning -and $ServiceName) {
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Host "  - [OK] Restored Windows service '$ServiceName'."
        } catch {
            Write-Host "  - [WARN] Could not auto-start '$ServiceName'. Start it via services.msc." -ForegroundColor Yellow
        }
    }

    Write-Host "======================================================================" -ForegroundColor Red
    exit $ExitCode
}

Write-Log "=== MySQL Password Reset Started ==="

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Preflight) {
    if ($Elevated) {
        Fail-WithReport -Step "Step 1: UAC Elevation" -ExitCode 5 -Reason "Elevated process did not receive Administrator rights." -Fix "Run PowerShell or Command Prompt as Administrator manually."
    }

    Write-Host ""
    Write-Host "[ACTION REQUIRED] Administrator rights are needed." -ForegroundColor Yellow
    Write-Host "A Windows UAC prompt will open - please click YES to continue." -ForegroundColor Yellow
    Write-Host ""
    Start-Sleep -Seconds 2

    try {
        $targetScript = if ($RunnerPs1) { $RunnerPs1 } else { $PSCommandPath }
        $argList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$targetScript`"",
            "-Elevated",
            "-RunnerPs1", "`"$targetScript`"",
            "-LogDir", "`"$LogDir`""
        )
        if ($ServiceName) { $argList += @("-ServiceName", "`"$ServiceName`"") }
        if ($MySqlBin) { $argList += @("-MySqlBin", "`"$MySqlBin`"") }
        if ($DefaultsFile) { $argList += @("-DefaultsFile", "`"$DefaultsFile`"") }

        $elevatedProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru -ErrorAction Stop
        exit $elevatedProcess.ExitCode
    } catch {
        Fail-WithReport -Step "Step 1: Trigger UAC Prompt" -ExitCode 5 -Reason $_.Exception.Message -Fix "Click YES on the UAC prompt, or right-click and choose 'Run as administrator'."
    }
}

if ($isAdmin) {
    Write-Log "[OK] Running with elevated Administrator privileges."
} elseif ($Preflight) {
    Write-Log "[INFO] Running in read-only preflight mode without elevation."
}

try {
    if (-not $ServiceName) {
        $serviceNames = @(Get-Service -Name "mysql*" -ErrorAction Stop | Select-Object -ExpandProperty Name)
        $ServiceName = Resolve-MySqlServiceName -ServiceNames $serviceNames
    }
    $svcObj = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svcObj.Status -notin @("Running", "Stopped")) {
        throw "MySQL service '$ServiceName' is in unsupported state '$($svcObj.Status)'. Stop it or wait for a stable Running/Stopped state and retry."
    }
    $serviceWasRunning = $svcObj.Status -eq "Running"
    $svcCim = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -eq $ServiceName })
    if ($svcCim.Count -ne 1) {
        throw "Could not determine the service account for '$ServiceName'."
    }
    if (-not $svcCim[0].StartName) {
        throw "The MySQL service '$ServiceName' has no configured service account."
    }
    $svcAccount = $svcCim[0].StartName
} catch {
    Fail-WithReport -Step "Step 2: Detect MySQL Service" -ExitCode 2 -Reason $_.Exception.Message -Fix "Check services.msc for your MySQL service name and pass -ServiceName '<name>'."
}

if (-not $Preflight) {
    try {
        $commonDataRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath('CommonApplicationData')).TrimEnd('\')
        $requestedLogRoot = Resolve-MySqlLogRoot -LogRoot $LogDir -CommonDataRoot $commonDataRoot
        $allowedLogPrefix = $commonDataRoot + '\'

        $currentPath = $commonDataRoot
        $relativeSegments = $requestedLogRoot.Substring($allowedLogPrefix.Length).Split('\')
        foreach ($segment in $relativeSegments) {
            $currentPath = Join-Path $currentPath $segment
            if (Test-Path -LiteralPath $currentPath) {
                $entry = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "LogDir cannot contain reparse points: '$currentPath'."
                }
            }
        }

        $LogDir = $requestedLogRoot
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $LogDir -ErrorAction Stop | Out-Null
        }

        $runDirectoryName = "run_{0}_{1}" -f $ts, [guid]::NewGuid().ToString('N')
        $runDir = Join-Path $LogDir $runDirectoryName
        $script:runDir = $runDir
        New-Item -ItemType Directory -Path $runDir -ErrorAction Stop | Out-Null
        $serviceAccountPrincipal = Get-MySqlServiceAccountPrincipal -ServiceAccount $svcAccount
        $aclGrants = @('*S-1-5-18:(OI)(CI)(F)', '*S-1-5-32-544:(OI)(CI)(F)')
        if ($serviceAccountPrincipal -notin @('*S-1-5-18', '*S-1-5-32-544')) {
            $aclGrants += "${serviceAccountPrincipal}:(OI)(CI)(RX)"
        }
        & icacls $runDir /inheritance:r /grant:r $aclGrants | Out-Null
        $aclRc = $LASTEXITCODE
        if ($aclRc -ne 0) {
            throw "Failed to restrict access to per-run directory '$runDir' (icacls exit code $aclRc)."
        }

        $logFile = Join-Path $runDir "reset_$ts.log"
        $initFile = Join-Path $runDir "init_$ts.sql"
        $script:loggingEnabled = $true
        Write-Log "[OK] Restricted per-run audit directory to Administrators, SYSTEM, and '$svcAccount'."
    } catch {
        Fail-WithReport -Step "Step 0: Initialize Secure Run Directory" -ExitCode 1 -Reason $_.Exception.Message -Fix "Use a writable LogDir beneath CommonApplicationData and verify its parent paths and ACLs."
    }
}

Write-Log "[OK] Target Windows service: $ServiceName (Status: $($svcObj.Status), Account: $svcAccount)"

try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $imagePath = (Get-ItemProperty -Path $regPath -Name ImagePath -ErrorAction Stop).ImagePath

    if (-not $MySqlBin) {
        if ($imagePath -match '"([^"]+mysqld\.exe)"') {
            $MySqlBin = Split-Path -Path $Matches[1] -Parent
        } elseif ($imagePath -match '(\S+mysqld\.exe)') {
            $MySqlBin = Split-Path -Path $Matches[1] -Parent
        }
    }

    if (-not $DefaultsFile) {
        if ($imagePath -match '--defaults-file="([^"]+)"') {
            $DefaultsFile = $Matches[1]
        } elseif ($imagePath -match '--defaults-file=(\S+)') {
            $DefaultsFile = $Matches[1]
        }
    }

    Test-MySqlServiceImagePath -ImagePath $imagePath -ServiceName $ServiceName

    if (-not $MySqlBin -or -not (Test-Path -LiteralPath (Join-Path $MySqlBin "mysqld.exe"))) {
        throw "mysqld.exe not found in '$MySqlBin' (ImagePath: $imagePath)."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $MySqlBin "mysql.exe"))) {
        throw "mysql.exe not found in '$MySqlBin'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $MySqlBin "mysqladmin.exe"))) {
        throw "mysqladmin.exe not found in '$MySqlBin'."
    }
    if ($DefaultsFile -and -not (Test-Path -LiteralPath $DefaultsFile)) {
        throw "Referenced --defaults-file '$DefaultsFile' does not exist."
    }

    if ($DefaultsFile) {
        $configLines = @(Get-Content -LiteralPath $DefaultsFile -ErrorAction Stop)
        $dbPort = Get-MySqlServerPort -ConfigLines $configLines
    }

    Write-Log "[OK] Verified binaries at '$MySqlBin' (Port: $dbPort)."
    if ($DefaultsFile) { Write-Log "[OK] Verified config file at '$DefaultsFile'." }
} catch {
    Fail-WithReport -Step "Step 3: Resolve MySQL Binaries and Config" -ExitCode 2 -Reason $_.Exception.Message -Fix "Pass -MySqlBin 'C:\Path\To\MySQL\bin' (and -DefaultsFile if needed)."
}

if ($Preflight) {
    Write-Host "[PREFLIGHT OK] Service, MySQL binaries, and config were resolved. No service or account was changed."
    exit 0
}

Write-Host ""
Write-Host "Target Service : $ServiceName"
Write-Host "MySQL Binaries : $MySqlBin"
Write-Host "Target Port    : $dbPort"
if ($DefaultsFile) { Write-Host "Config File    : $DefaultsFile" }
Write-Host "Audit Log      : $logFile"
Write-Host ""

while ($true) {
    $sec1 = Read-Host "Enter new MySQL root password (min 8 printable ASCII characters)" -AsSecureString
    $sec2 = Read-Host "Confirm new MySQL root password" -AsSecureString

    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1)
    $b2 = [IntPtr]::Zero
    try {
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2)
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
        $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
    } finally {
        if ($b1 -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        }
        if ($b2 -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        $sec1.Dispose()
        $sec2.Dispose()
    }

    if ($p1 -ne $p2) {
        Write-Host "[ERROR] Passwords do not match. Try again." -ForegroundColor Red
        $p1 = $null
        $p2 = $null
        continue
    }
    try {
        Assert-ResetPassword -Password $p1
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $p1 = $null
        $p2 = $null
        continue
    }

    $script:plainPass = $p1
    $p1 = $null
    $p2 = $null
    break
}

$confirm = Read-Host "Stop '$ServiceName' and reset root password now? [Y/N]"
if ($confirm -notmatch '^[Yy]$') {
    Write-Log "[ABORT] Cancelled by user."
    $script:plainPass = $null
    exit 0
}

try {
    $svcCurrent = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svcCurrent.Status -ne "Stopped") {
        Write-Log "[INFO] Stopping service '$ServiceName'..."
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        $serviceStopped = $true
        $svcCurrent.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    }
    Write-Log "[OK] Target service '$ServiceName' is stopped."
} catch {
    Fail-WithReport -Step "Step 5: Stop MySQL Service & Processes" -ExitCode 1 -Reason $_.Exception.Message -Fix "Stop '$ServiceName' in services.msc or close locking processes and retry."
}

try {
    $sqlContent = New-PasswordResetSql -Password $script:plainPass

    try {
        Set-Content -LiteralPath $initFile -Value $sqlContent -Encoding ASCII -NoNewline -ErrorAction Stop
    } finally {
        $sqlContent = $null
    }
    Write-Log "[OK] Created init SQL file in the restricted per-run directory."
} catch {
    Fail-WithReport -Step "Step 6: Create Init SQL File" -ExitCode 1 -Reason $_.Exception.Message -Fix "Check permissions and free disk space in '$LogDir'."
}

try {
    Write-Log "[INFO] Starting temporary mysqld with --init-file..."
    $mysqldExe = Join-Path $MySqlBin "mysqld.exe"
    $mysqlExe = Join-Path $MySqlBin "mysql.exe"
    $mysqlAdminExe = Join-Path $MySqlBin "mysqladmin.exe"
    $initArg = $initFile -replace '\\', '/'

    $mysqldArgs = Get-MySqlServerArguments -DefaultsFile $DefaultsFile -InitFile $initArg

    $script:tempProcess = Start-Process -FilePath $mysqldExe -ArgumentList $mysqldArgs -WindowStyle Minimized -PassThru -ErrorAction Stop
    $tempStarted = $true

    $ready = $false
    for ($i = 0; $i -lt 35; $i++) {
        Start-Sleep -Seconds 1
        if ($script:tempProcess.HasExited) {
            throw "Temporary mysqld.exe exited unexpectedly during startup."
        }
        $env:MYSQL_PWD = $script:plainPass
        & $mysqlExe -h 127.0.0.1 -P $dbPort -u root -e "SELECT 1;" >$null 2>&1
        $rc = $LASTEXITCODE
        $env:MYSQL_PWD = $null
        if ($rc -eq 0) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        throw "Timed out waiting for temporary mysqld on port $dbPort to accept the new password."
    }
    Write-Log "[OK] Verified new root password against temporary mysqld on port $dbPort."
} catch {
    Fail-WithReport -Step "Step 7: Apply Password via --init-file" -ExitCode 1 -Reason $_.Exception.Message -Fix "Check your MySQL .err log file in the MySQL Data folder for startup errors."
}

try {
    Write-Log "[INFO] Shutting down temporary mysqld cleanly..."
    $env:MYSQL_PWD = $script:plainPass
    & $mysqlAdminExe -h 127.0.0.1 -P $dbPort -u root shutdown >> $logFile 2>&1
    $shutdownRc = $LASTEXITCODE
    $env:MYSQL_PWD = $null
    if ($shutdownRc -ne 0) {
        throw "mysqladmin shutdown failed with exit code $shutdownRc."
    }
    if (-not $script:tempProcess.WaitForExit(20000)) {
        throw "Temporary mysqld.exe process $($script:tempProcess.Id) did not shut down within 20 seconds."
    }
    $tempStarted = $false
    Write-Log "[OK] Temporary mysqld shut down cleanly."

    [IO.File]::WriteAllText($initFile, ("0" * 256))
    Remove-Item -LiteralPath $initFile -Force -ErrorAction Stop
    Write-Log "[OK] Wiped and deleted init SQL file."
} catch {
    Fail-WithReport -Step "Step 8: Shutdown Temporary Instance & Cleanup" -ExitCode 1 -Reason $_.Exception.Message -Fix "Stop mysqld.exe processes, delete '$initFile', and start '$ServiceName'."
}

try {
    if ($serviceWasRunning) {
        Write-Log "[INFO] Restoring service '$ServiceName' to its original Running state..."
        Start-Service -Name $ServiceName -ErrorAction Stop
        (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
        $serviceStopped = $false

        $env:MYSQL_PWD = $script:plainPass
        & $mysqlExe -h 127.0.0.1 -P $dbPort -u root -e "SELECT USER(), VERSION();" >> $logFile 2>&1
        $verRc = $LASTEXITCODE
        $env:MYSQL_PWD = $null
        if ($verRc -ne 0) {
            throw "Service '$ServiceName' started, but post-reset login check failed with exit code $verRc."
        }
    } else {
        Write-Log "[INFO] Service '$ServiceName' was stopped before reset; leaving it stopped."
    }
    $script:plainPass = $null

    Write-Log "[SUCCESS] MySQL root password reset and verified."
    $finalServiceStatus = if ($serviceWasRunning) { "Running" } else { "Stopped" }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "[SUCCESS] Password reset completed for root@localhost." -ForegroundColor Green
    Write-Host "Service   : $ServiceName ($finalServiceStatus)"
    Write-Host "Audit Log : $logFile"
    Write-Host "======================================================================" -ForegroundColor Green
    exit 0
} catch {
    Fail-WithReport -Step "Step 9: Start Service & Verify Login" -ExitCode 1 -Reason $_.Exception.Message -Fix "Check Windows Application Event Log and MySQL .err log, then start '$ServiceName'."
}