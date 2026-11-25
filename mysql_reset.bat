@echo off
setlocal EnableExtensions
powershell.exe -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 3) { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell 3.0 or later is required.
    exit /b 1
)
set "SELF_BAT=%~f0"
set "STAGE_DIR=%TEMP%\MySQLPasswordReset_%RANDOM%_%RANDOM%"
set "MYSQL_RESET_LAUNCHER=%SELF_BAT%"
set "PS1_FILE=%STAGE_DIR%\reset_root.ps1"
if not exist "%STAGE_DIR%" mkdir "%STAGE_DIR%" >nul 2>&1
if not exist "%STAGE_DIR%" (
    echo [ERROR] Could not create "%STAGE_DIR%".
    rmdir "%STAGE_DIR%" >nul 2>&1
    exit /b 1
)
more +38 "%SELF_BAT%" > "%PS1_FILE%"
if errorlevel 1 (
    echo [ERROR] Failed to extract PowerShell script.
    if exist "%PS1_FILE%" del /f /q "%PS1_FILE%" >nul 2>&1 & rmdir "%STAGE_DIR%" >nul 2>&1
    exit /b 1
)
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%" -RunnerPs1 "%PS1_FILE%" %*
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
    [switch]$Preflight,
    [switch]$Console,
    [switch]$SkipUpdateCheck,
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = $null
$initFile = $null
$script:loggingEnabled = $false
$script:runDir = $null
$script:resetUi = $null
$script:resetUiEnabled = $false
$script:resetUiFallbackReason = $null
$script:resetSecurePassword = $null
$tempStarted = $false
$script:tempProcess = $null
$serviceStopped = $false
$serviceWasRunning = $false
$script:plainPass = $null
$script:appVersion = "1.2.0"
$dbPort = 3306
$svcAccount = $null

function Test-MySqlResetUiSupported {
    param([Parameter(Mandatory = $true)][Version]$PowerShellVersion)
    return $PowerShellVersion -ge [Version]"5.1"
}

$script:resetUiEnabled = (-not $Console -and -not $Preflight -and
    (Test-MySqlResetUiSupported -PowerShellVersion $PSVersionTable.PSVersion))
if (-not $Console -and -not $Preflight -and -not $script:resetUiEnabled) {
    $script:resetUiFallbackReason = "Windows PowerShell 5.1 or later is required for the reset window."
}

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Message"
    Write-Host $line
    if ($script:resetUi) {
        $script:resetUi.ProgressLog.AppendText($line + [Environment]::NewLine)
        $script:resetUi.ProgressLog.SelectionStart = $script:resetUi.ProgressLog.TextLength
        $script:resetUi.ProgressLog.ScrollToCaret()
        $script:resetUi.StatusLabel.Text = $Message
        $script:resetUi.OpenLogButton.Enabled = -not [string]::IsNullOrWhiteSpace($script:logFile) -and [IO.File]::Exists($script:logFile)
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($script:loggingEnabled) {
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
}

function Wait-ForResult {
    if (-not $NoWait -and -not $Preflight) {
        Write-Host ""
        [void](Read-Host "Press Enter to close this window")
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

function Invoke-MySqlAuthenticationProbe {
    param(
        [Parameter(Mandatory = $true)][string]$MySqlExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Password
    )

    if (-not (Test-Path -LiteralPath $MySqlExe -PathType Leaf -ErrorAction Stop)) {
        throw "MySQL client executable was not found at '$MySqlExe'."
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $env:MYSQL_PWD = $Password
        $output = @(& $MySqlExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $outputText = (@($output | ForEach-Object { [string]$_ }) -join " ").Trim()
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = $outputText
        }
    } finally {
        $env:MYSQL_PWD = $null
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-MySqlListeningProcessIds {
    param([Parameter(Mandatory = $true)][int]$Port)

    $listeners = @(Get-CimInstance `
        -Namespace "ROOT/StandardCimv2" `
        -ClassName "MSFT_NetTCPConnection" `
        -Filter "LocalPort = $Port AND State = 2" `
        -ErrorAction Stop)
    return @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
}

function Assert-MySqlTemporaryServerOwnsPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$ExpectedProcessId,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)][string]$InitFilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$ListenerProcessIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes
    )

    $ownerIds = @($ListenerProcessIds | Select-Object -Unique)
    if ($ownerIds.Count -eq 0) {
        return $false
    }
    if ($ownerIds.Count -gt 1) {
        throw "MySQL port $Port has multiple listener process owners ($($ownerIds -join ', ')); expected one temporary server."
    }

    $expectedExecutable = [IO.Path]::GetFullPath($ExpectedExecutablePath)
    $expectedInitFile = [IO.Path]::GetFullPath($InitFilePath)
    $launchProcess = @($Processes | Where-Object { $_.ProcessId -eq $ExpectedProcessId } | Select-Object -First 1)
    if ($launchProcess.Count -ne 1 -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$launchProcess[0].ExecutablePath), $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        throw "MySQL port $Port is owned by PID $($ownerIds[0]), not owned by the launched temporary server PID $ExpectedProcessId."
    }

    $initFileMatch = [regex]::Match(
        [string]$launchProcess[0].CommandLine,
        '(?i)(?:^|\s)--init-file=(?:"([^"]+)"|(\S+))'
    )
    $actualInitFile = if ($initFileMatch.Groups[1].Success) {
        $initFileMatch.Groups[1].Value
    } else {
        $initFileMatch.Groups[2].Value
    }
    if (-not $initFileMatch.Success -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath($actualInitFile.Replace('/', '\')),
            $expectedInitFile,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Launched mysqld PID $ExpectedProcessId does not have the expected init-file argument."
    }

    $currentProcessId = [int]$ownerIds[0]
    $ancestry = New-Object System.Collections.Generic.List[int]
    for ($depth = 0; $depth -lt 32 -and $currentProcessId -gt 0; $depth++) {
        $ancestry.Add($currentProcessId)
        $currentProcess = @($Processes | Where-Object { $_.ProcessId -eq $currentProcessId } | Select-Object -First 1)
        if ($currentProcess.Count -ne 1 -or
            [string]::IsNullOrWhiteSpace([string]$currentProcess[0].ExecutablePath) -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$currentProcess[0].ExecutablePath), $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        if ($currentProcessId -eq $ExpectedProcessId) {
            return $true
        }
        $currentProcessId = [int]$currentProcess[0].ParentProcessId
    }

    throw "MySQL port $Port owner PID $($ownerIds[0]) has ancestry $($ancestry -join ' -> '), which does not match the launched temporary server PID $ExpectedProcessId."
}

function Test-MySqlProcessBelongsToService {
    param(
        [Parameter(Mandatory = $true)][int]$ServiceProcessId,
        [Parameter(Mandatory = $true)][int]$ListenerProcessId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes
    )

    $currentProcessId = $ListenerProcessId
    for ($depth = 0; $depth -lt 32 -and $currentProcessId -gt 0; $depth++) {
        if ($currentProcessId -eq $ServiceProcessId) {
            return $true
        }
        $currentProcess = @($Processes | Where-Object { $_.ProcessId -eq $currentProcessId } | Select-Object -First 1)
        if ($currentProcess.Count -ne 1) {
            return $false
        }
        $currentProcessId = [int]$currentProcess[0].ParentProcessId
    }
    return $false
}

function Assert-MySqlServiceOwnsPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$ServiceProcessId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$ListenerProcessIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes
    )

    $ownerIds = @($ListenerProcessIds | Select-Object -Unique)
    if ($ownerIds.Count -eq 0) {
        throw "No process is listening on MySQL port $Port for service '$ServiceProcessId'."
    }
    if ($ownerIds.Count -ne 1 -or
        -not (Test-MySqlProcessBelongsToService -ServiceProcessId $ServiceProcessId -ListenerProcessId $ownerIds[0] -Processes $Processes)) {
        throw "MySQL port $Port is owned by PID(s) $($ownerIds -join ', '), not owned by service PID $ServiceProcessId."
    }
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

function Select-MySqlServiceName {
    param([string[]]$ServiceNames)

    if (-not $ServiceNames -or $ServiceNames.Count -eq 0) {
        throw "No Windows service starting with 'mysql' was found."
    }
    if ($ServiceNames.Count -eq 1) {
        return $ServiceNames[0]
    }

    Write-Host "Multiple MySQL services were found. Select the one to reset:"
    for ($index = 0; $index -lt $ServiceNames.Count; $index++) {
        Write-Host "  [$($index + 1)] $($ServiceNames[$index])"
    }

    while ($true) {
        $selection = Read-Host "Enter the service number"
        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and $selectedIndex -le $ServiceNames.Count) {
            return $ServiceNames[$selectedIndex - 1]
        }
        Write-Host "Invalid selection. Enter a number from 1 to $($ServiceNames.Count)." -ForegroundColor Red
    }
}

function Get-MySqlUpdateInfo {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$CurrentVersion
    )

    $tag = [string]$Release.tag_name
    if ($Release.draft -or $Release.prerelease -or $tag -notmatch '^v(\d+\.\d+\.\d+)$') {
        throw "The latest GitHub release has an unsupported version tag."
    }

    try {
        $latestVersion = [version]$Matches[1]
        $installedVersion = [version]$CurrentVersion
    } catch {
        throw "The installed or published application version is invalid."
    }
    if ($latestVersion -le $installedVersion) {
        return $null
    }

    $expectedReleaseUrl = "https://github.com/Abel-Ajish/mysql-reset-windows/releases/tag/$tag"
    if ([string]$Release.html_url -cne $expectedReleaseUrl) {
        throw "The latest release URL does not match the trusted repository and tag."
    }

    $matchingAssets = @($Release.assets | Where-Object { $_.name -ceq "mysql_reset.bat" })
    if ($matchingAssets.Count -ne 1) {
        throw "The latest release must contain exactly one mysql_reset.bat update asset."
    }
    $asset = $matchingAssets[0]
    if ($asset.state -cne "uploaded" -or
        $asset.size -lt 100 -or
        $asset.size -gt 1048576 -or
        [string]$asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw "The update asset is incomplete or does not have a valid SHA-256 digest."
    }

    $expectedAssetPath = "/Abel-Ajish/mysql-reset-windows/releases/download/$tag/mysql_reset.bat"
    $assetUri = $null
    if (-not [Uri]::TryCreate([string]$asset.browser_download_url, [UriKind]::Absolute, [ref]$assetUri) -or
        $assetUri.Scheme -cne "https" -or
        $assetUri.Host -ine "github.com" -or
        $assetUri.AbsolutePath -cne $expectedAssetPath -or
        $assetUri.Query -or
        $assetUri.Fragment) {
        throw "The update asset URL is not the expected HTTPS GitHub release asset."
    }

    return [pscustomobject]@{
        Tag = $tag
        Version = $latestVersion.ToString()
        DownloadUrl = $assetUri.AbsoluteUri
        Digest = $Matches[1].ToLowerInvariant()
        Size = [int64]$asset.size
        ReleaseUrl = $expectedReleaseUrl
        ReleaseNotes = [string]$Release.body
    }
}

function Get-MySqlLatestUpdateInfo {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ Accept = "application/vnd.github+json" }
    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/Abel-Ajish/mysql-reset-windows/releases/latest" `
        -Headers $headers `
        -UserAgent "MySQLPasswordReset/$script:appVersion" `
        -TimeoutSec 15 `
        -ErrorAction Stop
    return Get-MySqlUpdateInfo -Release $release -CurrentVersion $script:appVersion
}

function Test-MySqlUpdateLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$CurrentVersion
    )

    $targetPath = [IO.Path]::GetFullPath($LauncherPath)
    if ([IO.Path]::GetFileName($targetPath) -cne "mysql_reset.bat" -or
        -not [IO.File]::Exists($targetPath)) {
        throw "The updater target must be the current mysql_reset.bat file."
    }

    $targetInfo = New-Object IO.FileInfo($targetPath)
    if (($targetInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The updater will not replace a launcher that is a symbolic link or reparse point."
    }

    $currentText = [IO.File]::ReadAllText($targetPath)
    $versionMatch = [regex]::Match($currentText, '(?m)^\$script:appVersion = "(\d+\.\d+\.\d+)"\s*$')
    if (-not $versionMatch.Success -or $versionMatch.Groups[1].Value -cne $CurrentVersion) {
        throw "The current launcher does not identify itself as version $CurrentVersion."
    }

    $probePath = Join-Path $targetInfo.DirectoryName (".mysql_reset_write_probe_" + [guid]::NewGuid().ToString("N"))
    $probeCreated = $false
    try {
        $probe = [IO.File]::Open($probePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $probeCreated = $true
        $probe.Dispose()
    } catch {
        throw "This launcher folder is not writable by the current user. Move mysql_reset.bat to a user-writable folder to enable updates."
    } finally {
        if ($probeCreated -and [IO.File]::Exists($probePath)) {
            [IO.File]::Delete($probePath)
        }
    }

    return $targetPath
}

function Replace-MySqlLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$DownloadedPath,
        [Parameter(Mandatory = $true)]$UpdateInfo,
        [Parameter(Mandatory = $true)][string]$CurrentVersion
    )

    $targetPath = Test-MySqlUpdateLauncher -LauncherPath $LauncherPath -CurrentVersion $CurrentVersion
    if (-not [IO.File]::Exists($DownloadedPath) -or
        (Get-Item -LiteralPath $DownloadedPath -ErrorAction Stop).Length -ne $UpdateInfo.Size) {
        throw "The downloaded update file is missing or has an unexpected size."
    }
    $downloadedHash = (Get-FileHash -LiteralPath $DownloadedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($downloadedHash -cne $UpdateInfo.Digest) {
        throw "The downloaded update failed its SHA-256 integrity check."
    }
    $downloadedText = [IO.File]::ReadAllText($DownloadedPath)
    $downloadedVersion = [regex]::Match($downloadedText, '(?m)^\$script:appVersion = "(\d+\.\d+\.\d+)"\s*$')
    if (-not $downloadedVersion.Success -or $downloadedVersion.Groups[1].Value -cne $UpdateInfo.Version) {
        throw "The update file version does not match the published release."
    }

    $directory = [IO.Path]::GetDirectoryName($targetPath)
    $nonce = [guid]::NewGuid().ToString("N")
    $stagedPath = Join-Path $directory (".mysql_reset_update_$nonce.tmp")
    $backupPath = Join-Path $directory (".mysql_reset_backup_$nonce.bat")
    $failedPath = Join-Path $directory (".mysql_reset_failed_$nonce.tmp")
    $replaced = $false
    try {
        [IO.File]::Copy($DownloadedPath, $stagedPath, $false)
        $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($stagedHash -cne $UpdateInfo.Digest) {
            throw "The staged update failed its SHA-256 integrity check."
        }
        [IO.File]::Replace($stagedPath, $targetPath, $backupPath)
        $replaced = $true
        $installedHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($installedHash -cne $UpdateInfo.Digest) {
            throw "The installed update failed post-replacement verification."
        }
        return $backupPath
    } catch {
        if ($replaced -and [IO.File]::Exists($backupPath)) {
            [IO.File]::Replace($backupPath, $targetPath, $failedPath)
            if ([IO.File]::Exists($failedPath)) {
                [IO.File]::Delete($failedPath)
            }
        }
        throw
    } finally {
        if ([IO.File]::Exists($stagedPath)) {
            [IO.File]::Delete($stagedPath)
        }
    }
}

function Download-MySqlUpdateFile {
    param([Parameter(Mandatory = $true)]$UpdateInfo)

    if ($UpdateInfo.Size -lt 100 -or
        $UpdateInfo.Size -gt 1048576 -or
        $UpdateInfo.Digest -notmatch '^[a-f0-9]{64}$') {
        throw "The update metadata failed size or digest validation."
    }

    $downloadPath = Join-Path ([IO.Path]::GetTempPath()) ("mysql_reset_update_" + [guid]::NewGuid().ToString("N") + ".bat")
    $request = [Net.HttpWebRequest]::Create([Uri]$UpdateInfo.DownloadUrl)
    $request.Method = "GET"
    $request.UserAgent = "MySQLPasswordReset/$script:appVersion"
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 5
    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        $responseUri = $response.ResponseUri
        $allowedHosts = @("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")
        if ($responseUri.Scheme -cne "https" -or $responseUri.Host -notin $allowedHosts) {
            throw "The update download redirected outside the trusted HTTPS GitHub hosts."
        }
        if ($response.ContentLength -ne $UpdateInfo.Size) {
            throw "The update download size does not match the published release metadata."
        }

        $responseStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 8192
        $totalBytes = [int64]0
        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $totalBytes += $bytesRead
            if ($totalBytes -gt 1048576 -or $totalBytes -gt $UpdateInfo.Size) {
                throw "The update download exceeded its allowed size."
            }
            $outputStream.Write($buffer, 0, $bytesRead)
        }
        $outputStream.Flush()
        $outputStream.Dispose()
        $outputStream = $null
        $responseStream.Dispose()
        $responseStream = $null

        if ($totalBytes -ne $UpdateInfo.Size) {
            throw "The update download was incomplete."
        }
        $downloadedHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($downloadedHash -cne $UpdateInfo.Digest) {
            throw "The update download failed its SHA-256 integrity check."
        }
        $downloadedText = [IO.File]::ReadAllText($downloadPath)
        $downloadedVersion = [regex]::Match($downloadedText, '(?m)^\$script:appVersion = "(\d+\.\d+\.\d+)"\s*$')
        if (-not $downloadedVersion.Success -or $downloadedVersion.Groups[1].Value -cne $UpdateInfo.Version) {
            throw "The downloaded script version does not match the published release."
        }
        return $downloadPath
    } catch {
        if ([IO.File]::Exists($downloadPath)) {
            [IO.File]::Delete($downloadPath)
        }
        throw
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Install-MySqlUpdate {
    param(
        [Parameter(Mandatory = $true)]$UpdateInfo,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        throw "The self-updater must run before UAC elevation. Close this window and launch mysql_reset.bat normally."
    }

    $downloadedPath = $null
    $backupPath = $null
    try {
        $downloadedPath = Download-MySqlUpdateFile -UpdateInfo $UpdateInfo
        $backupPath = Replace-MySqlLauncher `
            -LauncherPath $LauncherPath `
            -DownloadedPath $downloadedPath `
            -UpdateInfo $UpdateInfo `
            -CurrentVersion $script:appVersion
        try {
            Start-Process -FilePath $LauncherPath -WorkingDirectory ([IO.Path]::GetDirectoryName($LauncherPath)) -ErrorAction Stop | Out-Null
        } catch {
            $failedPath = Join-Path ([IO.Path]::GetDirectoryName($LauncherPath)) (".mysql_reset_failed_" + [guid]::NewGuid().ToString("N") + ".tmp")
            [IO.File]::Replace($backupPath, $LauncherPath, $failedPath)
            if ([IO.File]::Exists($failedPath)) {
                [IO.File]::Delete($failedPath)
            }
            $backupPath = $null
            throw "The updated utility could not be reopened; the previous version was restored. $($_.Exception.Message)"
        }

        try {
            [IO.File]::Delete($backupPath)
            $backupPath = $null
        } catch {
            Write-Warning "The update is installed, but the old-version backup could not be deleted: '$backupPath'. Remove it manually."
        }
    } finally {
        if ($downloadedPath -and [IO.File]::Exists($downloadedPath)) {
            try {
                [IO.File]::Delete($downloadedPath)
            } catch {
                Write-Warning "Could not remove temporary update file '$downloadedPath'."
            }
        }
    }
}

function New-MySqlUpdateForm {
    param(
        [Parameter(Mandatory = $true)]$UpdateInfo,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "MySQL Password Reset - Update"
    $form.ClientSize = New-Object System.Drawing.Size(520, 318)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 88
    $header.BackColor = [System.Drawing.Color]::FromArgb(24, 43, 62)
    $form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "A safer reset tool is ready"
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
    $title.Location = New-Object System.Drawing.Point(24, 14)
    $title.Size = New-Object System.Drawing.Size(470, 32)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Review the version, then choose when to update."
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(215, 225, 235)
    $subtitle.Location = New-Object System.Drawing.Point(26, 52)
    $subtitle.Size = New-Object System.Drawing.Size(460, 22)
    $header.Controls.Add($subtitle)

    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Installed  $script:appVersion     Available  $($UpdateInfo.Version)"
    $versionLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $versionLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 52, 70)
    $versionLabel.Location = New-Object System.Drawing.Point(26, 108)
    $versionLabel.Size = New-Object System.Drawing.Size(460, 25)
    $versionLabel.AccessibleName = "Installed and available versions"
    $form.Controls.Add($versionLabel)

    $details = New-Object System.Windows.Forms.Label
    $details.Text = "The update is downloaded from the official GitHub release and verified before replacing this file. Your current copy is kept if verification or installation fails."
    $details.Location = New-Object System.Drawing.Point(26, 142)
    $details.Size = New-Object System.Drawing.Size(462, 56)
    $details.ForeColor = [System.Drawing.Color]::FromArgb(73, 87, 101)
    $details.AccessibleName = "Update and safety details"
    $form.Controls.Add($details)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "The reset will not run until you confirm it in the updated app."
    $status.Location = New-Object System.Drawing.Point(26, 202)
    $status.Size = New-Object System.Drawing.Size(462, 38)
    $status.ForeColor = [System.Drawing.Color]::FromArgb(0, 105, 100)
    $status.AccessibleName = "Update status"
    $form.Controls.Add($status)

    $updateButton = New-Object System.Windows.Forms.Button
    $updateButton.Text = "Update and reopen"
    $updateButton.Size = New-Object System.Drawing.Size(150, 36)
    $updateButton.Location = New-Object System.Drawing.Point(334, 262)
    $updateButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $updateButton.FlatAppearance.BorderSize = 0
    $updateButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 115)
    $updateButton.ForeColor = [System.Drawing.Color]::White
    $updateButton.AccessibleName = "Verify, install, and reopen the update"
    $form.Controls.Add($updateButton)

    $laterButton = New-Object System.Windows.Forms.Button
    $laterButton.Text = "Not now"
    $laterButton.Size = New-Object System.Drawing.Size(92, 36)
    $laterButton.Location = New-Object System.Drawing.Point(230, 262)
    $laterButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $laterButton.BackColor = [System.Drawing.Color]::White
    $laterButton.ForeColor = [System.Drawing.Color]::FromArgb(35, 52, 70)
    $laterButton.AccessibleName = "Continue with the current version"
    $form.Controls.Add($laterButton)

    $form.AcceptButton = $updateButton
    $form.CancelButton = $laterButton
    $form.Tag = "Later"
    $laterButton.Add_Click({ $form.Close() }.GetNewClosure())
    $updateButton.Add_Click({
        $updateButton.Enabled = $false
        $laterButton.Enabled = $false
        $status.Text = "Downloading and verifying the update..."
        $status.ForeColor = [System.Drawing.Color]::FromArgb(0, 105, 100)
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Install-MySqlUpdate -UpdateInfo $UpdateInfo -LauncherPath $LauncherPath
            $form.Tag = "Updated"
            $form.Close()
        } catch {
            $message = $_.Exception.Message
            if ($message.Length -gt 300) {
                $message = $message.Substring(0, 300)
            }
            $status.Text = "Update was not installed. Your current version is unchanged."
            $status.ForeColor = [System.Drawing.Color]::FromArgb(160, 55, 45)
            $details.Text = $message
            $updateButton.Text = "Try again"
            $updateButton.Enabled = $true
            $laterButton.Enabled = $true
        }
    }.GetNewClosure())

    return [pscustomobject]@{
        Form = $form
        UpdateButton = $updateButton
        LaterButton = $laterButton
        StatusLabel = $status
    }
}

function Show-MySqlUpdateDialog {
    param(
        [Parameter(Mandatory = $true)]$UpdateInfo,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    $dialog = New-MySqlUpdateForm -UpdateInfo $UpdateInfo -LauncherPath $LauncherPath
    try {
        $null = $dialog.Form.ShowDialog()
        return [string]$dialog.Form.Tag
    } finally {
        $dialog.Form.Dispose()
    }
}

function Set-MySqlResetTheme {
    param([Parameter(Mandatory = $true)]$Ui)

    if ($Ui.ThemeToggle.Checked) {
        $background = [System.Drawing.Color]::FromArgb(28, 36, 46)
        $headerBackground = [System.Drawing.Color]::FromArgb(20, 32, 46)
        $text = [System.Drawing.Color]::FromArgb(235, 240, 246)
        $inputBackground = [System.Drawing.Color]::FromArgb(42, 53, 66)
        $inputText = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $secondaryText = [System.Drawing.Color]::FromArgb(190, 201, 213)
        $logBackground = [System.Drawing.Color]::FromArgb(20, 27, 36)
        $accent = [System.Drawing.Color]::FromArgb(93, 218, 191)
        $success = [System.Drawing.Color]::FromArgb(101, 220, 164)
        $failure = [System.Drawing.Color]::FromArgb(255, 129, 120)
    } else {
        $background = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $headerBackground = [System.Drawing.Color]::FromArgb(24, 43, 62)
        $text = [System.Drawing.Color]::FromArgb(34, 49, 63)
        $inputBackground = [System.Drawing.Color]::White
        $inputText = [System.Drawing.Color]::FromArgb(35, 47, 60)
        $secondaryText = [System.Drawing.Color]::FromArgb(73, 87, 101)
        $logBackground = [System.Drawing.Color]::White
        $accent = [System.Drawing.Color]::FromArgb(0, 105, 100)
        $success = [System.Drawing.Color]::FromArgb(0, 105, 74)
        $failure = [System.Drawing.Color]::FromArgb(160, 55, 45)
    }

    $Ui.Form.BackColor = $background
    $Ui.Header.BackColor = $headerBackground
    $Ui.ThemeToggle.BackColor = $headerBackground
    $Ui.ThemeToggle.ForeColor = [System.Drawing.Color]::White
    foreach ($label in @($Ui.ServiceLabel, $Ui.PasswordLabel, $Ui.ConfirmPasswordLabel, $Ui.StatusLabel)) {
        $label.ForeColor = $text
    }
    $Ui.StatusLabel.ForeColor = $accent
    $Ui.ServiceSelector.BackColor = $inputBackground
    $Ui.ServiceSelector.ForeColor = $inputText
    foreach ($input in @($Ui.PasswordBox, $Ui.ConfirmPasswordBox)) {
        $input.BackColor = $inputBackground
        $input.ForeColor = $inputText
    }
    $Ui.ConfirmationCheckBox.ForeColor = $text
    foreach ($button in @($Ui.CancelButton, $Ui.OpenLogButton)) {
        $button.BackColor = $inputBackground
        $button.ForeColor = $inputText
        $button.UseVisualStyleBackColor = $false
    }
    $Ui.ResultLabel.ForeColor = if ($Ui.State.Completed) {
        if ($Ui.State.ResultSuccess) { $success } else { $failure }
    } else {
        $text
    }
    $Ui.ResultDetails.BackColor = $background
    $Ui.ResultDetails.ForeColor = $secondaryText
    $Ui.ProgressLog.BackColor = $logBackground
    $Ui.ProgressLog.ForeColor = $inputText
}

function New-MySqlResetForm {
    param(
        [Parameter(Mandatory = $true)][string[]]$ServiceNames,
        [string]$InitialServiceName = ""
    )

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "MySQL Password Reset"
    $form.ClientSize = New-Object System.Drawing.Size(700, 690)
    $form.MinimumSize = New-Object System.Drawing.Size(700, 690)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 82
    $header.BackColor = [System.Drawing.Color]::FromArgb(24, 43, 62)
    $form.Controls.Add($header)

    $themeToggle = New-Object System.Windows.Forms.CheckBox
    $themeToggle.Text = "Dark mode"
    $themeToggle.Checked = $true
    $themeToggle.Location = New-Object System.Drawing.Point(545, 12)
    $themeToggle.Size = New-Object System.Drawing.Size(130, 28)
    $themeToggle.ForeColor = [System.Drawing.Color]::White
    $themeToggle.BackColor = $header.BackColor
    $themeToggle.UseVisualStyleBackColor = $false
    $themeToggle.AccessibleName = "Toggle dark mode"
    $header.Controls.Add($themeToggle)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Reset MySQL root password"
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
    $title.Location = New-Object System.Drawing.Point(26, 13)
    $title.Size = New-Object System.Drawing.Size(500, 32)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Choose a local service. The reset will target root@localhost only."
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(215, 225, 235)
    $subtitle.Location = New-Object System.Drawing.Point(28, 49)
    $subtitle.Size = New-Object System.Drawing.Size(620, 22)
    $header.Controls.Add($subtitle)

    $serviceLabel = New-Object System.Windows.Forms.Label
    $serviceLabel.Text = "MySQL Windows service"
    $serviceLabel.Location = New-Object System.Drawing.Point(28, 101)
    $serviceLabel.Size = New-Object System.Drawing.Size(620, 22)
    $serviceLabel.AccessibleName = "MySQL service label"
    $form.Controls.Add($serviceLabel)

    $serviceSelector = New-Object System.Windows.Forms.ComboBox
    $serviceSelector.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $serviceSelector.Location = New-Object System.Drawing.Point(28, 125)
    $serviceSelector.Size = New-Object System.Drawing.Size(644, 30)
    $serviceSelector.AccessibleName = "MySQL Windows service"
    foreach ($serviceName in $ServiceNames) {
        $serviceItem = [pscustomobject]@{
            Name = $serviceName
            DisplayText = $serviceName
        }
        $null = $serviceSelector.Items.Add($serviceItem)
    }
    $serviceSelector.DisplayMember = "DisplayText"
    $serviceSelector.ValueMember = "Name"
    if ($ServiceNames.Count -gt 1) {
        $serviceSelector.SelectedIndex = 0
        if ($InitialServiceName) {
            $initialIndex = [Array]::IndexOf($ServiceNames, $InitialServiceName)
            if ($initialIndex -ge 0) { $serviceSelector.SelectedIndex = $initialIndex }
        }
    } elseif ($ServiceNames.Count -eq 1) {
        $serviceSelector.SelectedIndex = 0
        $serviceSelector.Enabled = $false
    }
    $form.Controls.Add($serviceSelector)

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = "New password (at least 8 printable ASCII characters)"
    $passwordLabel.Location = New-Object System.Drawing.Point(28, 171)
    $passwordLabel.Size = New-Object System.Drawing.Size(644, 22)
    $form.Controls.Add($passwordLabel)

    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location = New-Object System.Drawing.Point(28, 195)
    $passwordBox.Size = New-Object System.Drawing.Size(644, 28)
    $passwordBox.UseSystemPasswordChar = $true
    $passwordBox.AccessibleName = "New MySQL root password"
    $form.Controls.Add($passwordBox)

    $confirmPasswordLabel = New-Object System.Windows.Forms.Label
    $confirmPasswordLabel.Text = "Confirm new password"
    $confirmPasswordLabel.Location = New-Object System.Drawing.Point(28, 235)
    $confirmPasswordLabel.Size = New-Object System.Drawing.Size(644, 22)
    $form.Controls.Add($confirmPasswordLabel)

    $confirmPasswordBox = New-Object System.Windows.Forms.TextBox
    $confirmPasswordBox.Location = New-Object System.Drawing.Point(28, 259)
    $confirmPasswordBox.Size = New-Object System.Drawing.Size(644, 28)
    $confirmPasswordBox.UseSystemPasswordChar = $true
    $confirmPasswordBox.AccessibleName = "Confirm new MySQL root password"
    $form.Controls.Add($confirmPasswordBox)

    $confirmationCheckBox = New-Object System.Windows.Forms.CheckBox
    $confirmationCheckBox.Text = "I confirm this will reset root@localhost for the selected service."
    $confirmationCheckBox.Location = New-Object System.Drawing.Point(28, 303)
    $confirmationCheckBox.Size = New-Object System.Drawing.Size(644, 30)
    $confirmationCheckBox.AccessibleName = "Confirm password reset"
    $form.Controls.Add($confirmationCheckBox)

    $resetButton = New-Object System.Windows.Forms.Button
    $resetButton.Text = "Reset password"
    $resetButton.Size = New-Object System.Drawing.Size(155, 38)
    $resetButton.Location = New-Object System.Drawing.Point(517, 350)
    $resetButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $resetButton.FlatAppearance.BorderSize = 0
    $resetButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 115)
    $resetButton.ForeColor = [System.Drawing.Color]::White
    $resetButton.AccessibleName = "Start MySQL root password reset"
    $form.Controls.Add($resetButton)
    $form.AcceptButton = $resetButton

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Size = New-Object System.Drawing.Size(96, 38)
    $cancelButton.Location = New-Object System.Drawing.Point(411, 350)
    $cancelButton.AccessibleName = "Cancel or close password reset"
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $openLogButton = New-Object System.Windows.Forms.Button
    $openLogButton.Text = "Open reset log"
    $openLogButton.Size = New-Object System.Drawing.Size(124, 38)
    $openLogButton.Location = New-Object System.Drawing.Point(28, 350)
    $openLogButton.Enabled = $false
    $openLogButton.AccessibleName = "Open reset log in Notepad"
    $form.Controls.Add($openLogButton)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Ready. Enter and confirm a password, then confirm the reset."
    $statusLabel.Location = New-Object System.Drawing.Point(28, 405)
    $statusLabel.Size = New-Object System.Drawing.Size(644, 26)
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 105, 100)
    $statusLabel.AutoEllipsis = $true
    $statusLabel.AccessibleName = "Reset progress status"
    $form.Controls.Add($statusLabel)

    $resultLabel = New-Object System.Windows.Forms.Label
    $resultLabel.Location = New-Object System.Drawing.Point(28, 435)
    $resultLabel.Size = New-Object System.Drawing.Size(644, 25)
    $resultLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $resultLabel.Visible = $false
    $resultLabel.AccessibleName = "Reset result"
    $form.Controls.Add($resultLabel)

    $resultDetails = New-Object System.Windows.Forms.TextBox
    $resultDetails.Location = New-Object System.Drawing.Point(28, 461)
    $resultDetails.Size = New-Object System.Drawing.Size(644, 56)
    $resultDetails.Multiline = $true
    $resultDetails.ReadOnly = $true
    $resultDetails.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $resultDetails.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $resultDetails.ForeColor = [System.Drawing.Color]::FromArgb(73, 87, 101)
    $resultDetails.BackColor = $form.BackColor
    $resultDetails.Visible = $false
    $resultDetails.AccessibleName = "Reset result details"
    $form.Controls.Add($resultDetails)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(28, 520)
    $progressBar.Size = New-Object System.Drawing.Size(644, 16)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
    $form.Controls.Add($progressBar)

    $progressLog = New-Object System.Windows.Forms.RichTextBox
    $progressLog.Location = New-Object System.Drawing.Point(28, 548)
    $progressLog.Size = New-Object System.Drawing.Size(644, 114)
    $progressLog.ReadOnly = $true
    $progressLog.WordWrap = $false
    $progressLog.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $progressLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $progressLog.BackColor = [System.Drawing.Color]::White
    $progressLog.AccessibleName = "Reset progress log"
    $form.Controls.Add($progressLog)

    $state = [pscustomobject]@{
        Submitted = $false
        Cancelled = $false
        InProgress = $false
        Completed = $false
        ResultSuccess = $false
        ServiceName = $null
        SecurePassword = $null
    }
    $ui = [pscustomobject]@{
        Form = $form
        State = $state
        ServiceSelector = $serviceSelector
        Header = $header
        ThemeToggle = $themeToggle
        ServiceLabel = $serviceLabel
        PasswordLabel = $passwordLabel
        ConfirmPasswordLabel = $confirmPasswordLabel
        PasswordBox = $passwordBox
        ConfirmPasswordBox = $confirmPasswordBox
        ConfirmationCheckBox = $confirmationCheckBox
        ResetButton = $resetButton
        CancelButton = $cancelButton
        OpenLogButton = $openLogButton
        StatusLabel = $statusLabel
        ResultLabel = $resultLabel
        ResultDetails = $resultDetails
        ProgressBar = $progressBar
        ProgressLog = $progressLog
    }

    $themeToggle.Add_CheckedChanged({
        Set-MySqlResetTheme -Ui $ui
    }.GetNewClosure())
    Set-MySqlResetTheme -Ui $ui

    $resetButton.Add_Click({
        $null = Submit-MySqlResetForm -Ui $ui
    }.GetNewClosure())
    $cancelButton.Add_Click({
        if ($ui.State.Completed) {
            $form.Close()
        } elseif (-not $ui.State.InProgress) {
            $ui.State.Cancelled = $true
            $form.Close()
        }
    }.GetNewClosure())
    $openLogButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($script:logFile) -or -not [IO.File]::Exists($script:logFile)) {
            $ui.StatusLabel.Text = "The reset log is not available yet."
            return
        }
        try {
            Start-Process -FilePath "notepad.exe" -ArgumentList "`"$script:logFile`"" -ErrorAction Stop | Out-Null
        } catch {
            $ui.StatusLabel.Text = "Could not open the reset log: $($_.Exception.Message)"
        }
    }.GetNewClosure())
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($ui.State.InProgress -and -not $ui.State.Completed) {
            $eventArgs.Cancel = $true
            $ui.StatusLabel.Text = "Reset is in progress. Wait for the result before closing this window."
        } elseif (-not $ui.State.Submitted) {
            $ui.State.Cancelled = $true
        }
    }.GetNewClosure())

    return $ui
}

function Submit-MySqlResetForm {
    param([Parameter(Mandatory = $true)]$Ui)

    if ($Ui.ServiceSelector.SelectedIndex -lt 0) {
        $Ui.StatusLabel.Text = "Choose the MySQL service to reset."
        return $false
    }
    if (-not $Ui.ConfirmationCheckBox.Checked) {
        $Ui.StatusLabel.Text = "Confirm that you want to reset root@localhost."
        return $false
    }

    $password = $Ui.PasswordBox.Text
    $confirmation = $Ui.ConfirmPasswordBox.Text
    if ($password -cne $confirmation) {
        $Ui.ConfirmPasswordBox.Clear()
        $null = $Ui.ConfirmPasswordBox.Focus()
        $Ui.StatusLabel.Text = "Passwords do not match. Confirm the new password again."
        return $false
    }
    try {
        Assert-ResetPassword -Password $password
    } catch {
        $Ui.PasswordBox.Clear()
        $Ui.ConfirmPasswordBox.Clear()
        $null = $Ui.PasswordBox.Focus()
        $Ui.StatusLabel.Text = $_.Exception.Message
        return $false
    }

    try {
        $Ui.State.SecurePassword = ConvertTo-SecureString -String $password -AsPlainText -Force -ErrorAction Stop
    } catch {
        $Ui.PasswordBox.Clear()
        $Ui.ConfirmPasswordBox.Clear()
        $Ui.StatusLabel.Text = "Could not securely prepare the password. Try again."
        return $false
    } finally {
        $password = $null
        $confirmation = $null
        $Ui.PasswordBox.Clear()
        $Ui.ConfirmPasswordBox.Clear()
    }

    $Ui.State.ServiceName = [string]$Ui.ServiceSelector.SelectedItem.Name
    $Ui.State.Submitted = $true
    $Ui.State.InProgress = $true
    $Ui.ServiceSelector.Enabled = $false
    $Ui.ConfirmationCheckBox.Enabled = $false
    $Ui.ResetButton.Enabled = $false
    $Ui.CancelButton.Enabled = $false
    $Ui.Form.AcceptButton = $null
    $Ui.StatusLabel.Text = "Starting preflight checks..."
    $Ui.ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $Ui.ProgressBar.MarqueeAnimationSpeed = 24
    return $true
}

function Set-MySqlResetConsoleWindowVisibility {
    param([Parameter(Mandatory = $true)][bool]$Visible)

    if (-not ("MySqlResetConsoleWindow" -as [type])) {
        $typeDefinition = @"
using System;
using System.Runtime.InteropServices;
public static class MySqlResetConsoleWindow {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr windowHandle, int command);
}
"@
        Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop | Out-Null
    }

    $windowHandle = [MySqlResetConsoleWindow]::GetConsoleWindow()
    if ($windowHandle -eq [IntPtr]::Zero) {
        return $false
    }
    $command = if ($Visible) { 5 } else { 0 }
    $null = [MySqlResetConsoleWindow]::ShowWindow($windowHandle, $command)
    return $true
}

function Show-MySqlResetForm {
    param(
        [Parameter(Mandatory = $true)][string[]]$ServiceNames,
        [string]$InitialServiceName = ""
    )

    $ui = New-MySqlResetForm -ServiceNames $ServiceNames -InitialServiceName $InitialServiceName
    $script:resetUi = $ui
    try {
        $ui.Form.Show()
        $ui.Form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        try {
            if (-not (Set-MySqlResetConsoleWindowVisibility -Visible:$false)) {
                throw "No console window handle is available."
            }
        } catch {
            $ui.StatusLabel.Text = "Reset window is open, but the terminal could not be hidden: $($_.Exception.Message)"
            Write-Host "[WARN] $($ui.StatusLabel.Text)" -ForegroundColor Yellow
        }
        while ($ui.Form.Visible -and -not $ui.State.Submitted -and -not $ui.State.Cancelled) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        if (-not $ui.State.Submitted) {
            return $null
        }
        return $ui
    } finally {
        if (-not $ui.State.Submitted) {
            $ui.Form.Dispose()
            $script:resetUi = $null
        }
    }
}

function Show-MySqlResetUiResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Details
    )

    if (-not $script:resetUi) {
        if (-not $script:resetUiEnabled) {
            Write-Host "$Title`r`n$Details" -ForegroundColor $(if ($Success) { "Green" } else { "Red" })
            return
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = if ($Success) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Error }
        $null = [System.Windows.Forms.MessageBox]::Show($Details, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
        return
    }

    $ui = $script:resetUi
    $ui.State.InProgress = $false
    $ui.State.Completed = $true
    $ui.State.ResultSuccess = $Success
    $ui.ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
    $ui.ProgressBar.MarqueeAnimationSpeed = 0
    $ui.ProgressBar.Value = if ($Success) { 100 } else { 0 }
    $ui.ResultLabel.Text = $Title
    $ui.ResultDetails.Text = $Details
    $ui.ResultLabel.Visible = $true
    $ui.ResultDetails.Visible = $true
    $ui.StatusLabel.Text = if ($Success) { "Reset completed successfully." } else { "Reset failed. Review the reason below and the log." }
    $ui.ResetButton.Visible = $false
    $ui.CancelButton.Text = "Close"
    $ui.CancelButton.Enabled = $true
    $ui.Form.AcceptButton = $ui.CancelButton
    $ui.Form.CancelButton = $ui.CancelButton
    $ui.OpenLogButton.Enabled = -not [string]::IsNullOrWhiteSpace($script:logFile) -and [IO.File]::Exists($script:logFile)
    Set-MySqlResetTheme -Ui $ui
    $ui.Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    while ($ui.Form.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    $ui.Form.Dispose()
    $script:resetUi = $null
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
    if ($script:resetSecurePassword) {
        $script:resetSecurePassword.Dispose()
        $script:resetSecurePassword = $null
    }
    if ($script:resetUi) {
        $script:resetUi.State.SecurePassword = $null
    }

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
    if ($script:resetUiEnabled) {
        $failureDetails = "Failed step: $Step`r`nExit code: $ExitCode`r`nReason: $Reason`r`nSuggested fix: $Fix`r`nAudit log: $logFile"
        Show-MySqlResetUiResult -Success:$false -Title "Reset failed: $Step" -Details $failureDetails
    } else {
        Wait-ForResult
    }
    exit $ExitCode
}

Write-Log "=== MySQL Password Reset Started ==="

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Preflight -and -not $SkipUpdateCheck -and -not $Elevated -and
    (Test-MySqlResetUiSupported -PowerShellVersion $PSVersionTable.PSVersion)) {
    if ($isAdmin) {
        Write-Log "[INFO] Skipping automatic update checks because this process is already elevated."
    } else {
        try {
            $updateInfo = Get-MySqlLatestUpdateInfo
            if ($updateInfo) {
                $launcherPath = [Environment]::GetEnvironmentVariable("MYSQL_RESET_LAUNCHER", "Process")
                if ([string]::IsNullOrWhiteSpace($launcherPath)) {
                    throw "The current mysql_reset.bat path could not be determined."
                }
                $updateChoice = Show-MySqlUpdateDialog -UpdateInfo $updateInfo -LauncherPath $launcherPath
                if ($updateChoice -eq "Updated") {
                    exit 0
                }
                Write-Log "[INFO] Update deferred; continuing with version $script:appVersion."
            } else {
                Write-Log "[OK] MySQL Password Reset version $script:appVersion is up to date."
            }
        } catch {
            Write-Log "[WARN] Update check failed; continuing with version $script:appVersion. $($_.Exception.Message)"
        }
    }
}
elseif (-not $Preflight -and -not $SkipUpdateCheck -and
    -not (Test-MySqlResetUiSupported -PowerShellVersion $PSVersionTable.PSVersion)) {
    Write-Log "[INFO] Skipping update checks because the installed PowerShell version uses the console reset workflow."
}

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
            "-STA",
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
        if ($Console) { $argList += "-Console" }
        if ($NoWait) { $argList += "-NoWait" }

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
    if ($ServiceName) {
        $serviceNames = @(Get-Service -Name "mysql*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $requestedServices = @(Get-Service -Name $ServiceName -ErrorAction Stop)
        if ($requestedServices.Count -ne 1 -or $requestedServices[0].Name -ine $ServiceName) {
            throw "Service name '$ServiceName' must identify exactly one MySQL Windows service."
        }
        $ServiceName = $requestedServices[0].Name
        if ($serviceNames -notcontains $ServiceName) {
            $serviceNames += $ServiceName
        }
    } else {
        $serviceNames = @(Get-Service -Name "mysql*" -ErrorAction Stop | Select-Object -ExpandProperty Name)
    }

    if (-not $Preflight -and -not $Console) {
        if ($serviceNames.Count -eq 0) {
            throw "No Windows service starting with 'mysql' was found."
        }
        if ($script:resetUiEnabled) {
            try {
                $script:resetUi = Show-MySqlResetForm -ServiceNames $serviceNames -InitialServiceName $ServiceName
            } catch {
                if ($script:resetUi -and $script:resetUi.State.Submitted) {
                    throw
                }
                $script:resetUiEnabled = $false
                $script:resetUiFallbackReason = "The reset window could not be opened: $($_.Exception.Message)"
                try {
                    if (-not (Set-MySqlResetConsoleWindowVisibility -Visible:$true)) {
                        throw "No console window handle is available."
                    }
                } catch {
                    Write-Host "[WARN] Could not restore the terminal for console fallback: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
        if ($script:resetUi) {
            $ServiceName = $script:resetUi.State.ServiceName
            $script:resetSecurePassword = $script:resetUi.State.SecurePassword
        } elseif ($script:resetUiEnabled) {
            Write-Log "[ABORT] Cancelled by user. No password changes were made."
            exit 0
        } else {
            Write-Log "[WARN] $script:resetUiFallbackReason Falling back to console prompts."
            if (-not $ServiceName) {
                if ($serviceNames.Count -gt 1) {
                    $ServiceName = Select-MySqlServiceName -ServiceNames $serviceNames
                } else {
                    $ServiceName = Resolve-MySqlServiceName -ServiceNames $serviceNames
                }
            }
        }
    } elseif (-not $ServiceName) {
        if ($serviceNames.Count -gt 1 -and -not $Preflight) {
            $ServiceName = Select-MySqlServiceName -ServiceNames $serviceNames
        } else {
            $ServiceName = Resolve-MySqlServiceName -ServiceNames $serviceNames
        }
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

if ($script:resetUi) {
    $passwordBstr = [IntPtr]::Zero
    try {
        $passwordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:resetSecurePassword)
        $script:plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBstr)
        Assert-ResetPassword -Password $script:plainPass
    } catch {
        Fail-WithReport -Step "Step 4: Validate Reset Password" -ExitCode 1 -Reason $_.Exception.Message -Fix "Close the result window and retry with a valid password."
    } finally {
        if ($passwordBstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr)
        }
        if ($script:resetSecurePassword) {
            $script:resetSecurePassword.Dispose()
            $script:resetSecurePassword = $null
            $script:resetUi.State.SecurePassword = $null
        }
    }
} else {
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
}

if (-not $script:resetUi) {
    $confirm = Read-Host "Stop '$ServiceName' and reset root password now? [Y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Log "[ABORT] Cancelled by user. No password changes were made."
        $script:plainPass = $null
        Wait-ForResult
        exit 0
    }
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
    $existingListenerProcessIds = @(Get-MySqlListeningProcessIds -Port $dbPort)
    if ($existingListenerProcessIds.Count -gt 0) {
        throw "TCP port $dbPort is already in use by process ID(s) $($existingListenerProcessIds -join ', '). Stop every MySQL service using this port and retry."
    }
    $initArg = $initFile -replace '\\', '/'

    $mysqldArgs = Get-MySqlServerArguments -DefaultsFile $DefaultsFile -InitFile $initArg

    $script:tempProcess = Start-Process -FilePath $mysqldExe -ArgumentList $mysqldArgs -WindowStyle Minimized -PassThru -ErrorAction Stop
    $tempStarted = $true

    $ready = $false
    $lastProbeOutput = ""
    for ($i = 0; $i -lt 35; $i++) {
        Start-Sleep -Seconds 1
        if ($script:tempProcess.HasExited) {
            throw "Temporary mysqld.exe exited unexpectedly during startup."
        }
        $listenerProcessIds = @(Get-MySqlListeningProcessIds -Port $dbPort)
        if ($listenerProcessIds.Count -gt 0) {
            $null = Assert-MySqlTemporaryServerOwnsPort `
                -Port $dbPort `
                -ExpectedProcessId $script:tempProcess.Id `
                -ExpectedExecutablePath $mysqldExe `
                -InitFilePath $initFile `
                -ListenerProcessIds $listenerProcessIds `
                -Processes @(Get-CimInstance Win32_Process -ErrorAction Stop)
        } else {
            continue
        }
        $probeResult = Invoke-MySqlAuthenticationProbe `
            -MySqlExe $mysqlExe `
            -Arguments @("-h", "127.0.0.1", "-P", [string]$dbPort, "-u", "root", "-e", "SELECT 1;") `
            -Password $script:plainPass
        if ($probeResult.ExitCode -eq 0) {
            $ready = $true
            break
        }
        $lastProbeOutput = $probeResult.Output
    }

    if (-not $ready) {
        $timeoutReason = "Timed out waiting for temporary mysqld on port $dbPort to accept the new password."
        if ($lastProbeOutput) {
            if ($lastProbeOutput.Length -gt 300) {
                $lastProbeOutput = $lastProbeOutput.Substring(0, 300)
            }
            $timeoutReason += " Last MySQL client response: $lastProbeOutput"
        }
        throw $timeoutReason
    }
    $listenerProcessIds = @(Get-MySqlListeningProcessIds -Port $dbPort)
    if (-not (Assert-MySqlTemporaryServerOwnsPort `
        -Port $dbPort `
        -ExpectedProcessId $script:tempProcess.Id `
        -ExpectedExecutablePath $mysqldExe `
        -InitFilePath $initFile `
        -ListenerProcessIds $listenerProcessIds `
        -Processes @(Get-CimInstance Win32_Process -ErrorAction Stop))) {
        Write-Log "[WARN] Temporary MySQL stopped after the new password was authenticated; proceeding with cleanup."
    }
    Write-Log "[OK] Verified new root password against temporary mysqld on port $dbPort."
} catch {
    Fail-WithReport -Step "Step 7: Apply Password via --init-file" -ExitCode 1 -Reason $_.Exception.Message -Fix "Check your MySQL .err log file in the MySQL Data folder for startup errors."
}

try {
    Write-Log "[INFO] Shutting down temporary mysqld cleanly..."
    $listenerProcessIds = @(Get-MySqlListeningProcessIds -Port $dbPort)
    $temporaryServerIsListening = Assert-MySqlTemporaryServerOwnsPort `
        -Port $dbPort `
        -ExpectedProcessId $script:tempProcess.Id `
        -ExpectedExecutablePath $mysqldExe `
        -InitFilePath $initFile `
        -ListenerProcessIds $listenerProcessIds `
        -Processes @(Get-CimInstance Win32_Process -ErrorAction Stop)
    if ($temporaryServerIsListening) {
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
    } else {
        Write-Log "[INFO] Temporary MySQL had already stopped after the successful password check."
        Stop-TemporaryMySqlProcess
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
    Write-Log "[INFO] Starting MySQL service '$ServiceName' and verifying the new password..."
    Start-Service -Name $ServiceName -ErrorAction Stop
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    $serviceStopped = $false

    $serviceProcessIds = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -eq $ServiceName } | Select-Object -ExpandProperty ProcessId)
    if ($serviceProcessIds.Count -ne 1 -or $serviceProcessIds[0] -le 0) {
        throw "Could not verify the process hosting MySQL service '$ServiceName'."
    }
    $listenerProcessIds = @(Get-MySqlListeningProcessIds -Port $dbPort)
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    Assert-MySqlServiceOwnsPort -Port $dbPort -ServiceProcessId $serviceProcessIds[0] -ListenerProcessIds $listenerProcessIds -Processes $processes

    $env:MYSQL_PWD = $script:plainPass
    & $mysqlExe -h 127.0.0.1 -P $dbPort -u root -e "SELECT USER(), VERSION();" >> $logFile 2>&1
    $verRc = $LASTEXITCODE
    $env:MYSQL_PWD = $null
    if ($verRc -ne 0) {
        throw "Service '$ServiceName' started, but post-reset login check failed with exit code $verRc."
    }
    $script:plainPass = $null

    Write-Log "[SUCCESS] MySQL root password reset and verified."
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "[SUCCESS] Password reset completed for root@localhost." -ForegroundColor Green
    Write-Host "Service   : $ServiceName (Running)"
    Write-Host "Audit Log : $logFile"
    Write-Host "======================================================================" -ForegroundColor Green
    if ($script:resetUiEnabled) {
        $successDetails = "Password reset for root@localhost succeeded and was verified.`r`nService: $ServiceName (Running)`r`nAudit log: $logFile"
        Show-MySqlResetUiResult -Success:$true -Title "Password reset completed" -Details $successDetails
    } else {
        Wait-ForResult
    }
    exit 0
} catch {
    Fail-WithReport -Step "Step 9: Start Service & Verify Login" -ExitCode 1 -Reason $_.Exception.Message -Fix "Check Windows Application Event Log and MySQL .err log, then start '$ServiceName'."
}