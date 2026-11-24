$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'mysql_reset.bat'
$lines = [IO.File]::ReadAllLines($scriptPath)
$markerIndex = [Array]::IndexOf($lines, ':: === EMBEDDED POWERSHELL BELOW ===')
if ($markerIndex -lt 0) {
    throw 'The batch launcher extraction offset no longer matches the embedded PowerShell marker.'
}
$expectedOffset = $markerIndex + 1
if (-not ($lines -match "^\s*more \+$expectedOffset ")) {
    throw 'The batch launcher must extract PowerShell from the line after its marker.'
}
$powerShellSource = $lines[($markerIndex + 1)..($lines.Length - 1)] -join [Environment]::NewLine
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $powerShellSource,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Embedded PowerShell has parse errors: $($parseErrors -join '; ')"
}

$functions = @{}
$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object {
    $functions[$_.Name] = $_
}

if (-not $functions.ContainsKey('Stop-TemporaryMySqlProcess')) {
    throw 'The script must stop only the temporary mysqld process it started.'
}

if (-not $functions.ContainsKey('Get-MySqlServerArguments')) {
    throw 'The script must build safely quoted server arguments for paths containing spaces.'
}
if (-not $functions.ContainsKey('Get-MySqlServerPort')) {
    throw 'The script must resolve the port from the MySQL server section, not another config section.'
}
if (-not $functions.ContainsKey('New-PasswordResetSql') -or
    -not $functions.ContainsKey('Assert-ResetPassword')) {
    throw 'The script must generate SQL that safely preserves special password characters.'
}
if (-not $functions.ContainsKey('Test-MySqlServiceImagePath')) {
    throw 'The script must validate service command-line options before starting a temporary server.'
}
if (-not $functions.ContainsKey('Resolve-MySqlServiceName')) {
    throw 'The script must require an explicit choice when more than one MySQL service exists.'
}
if (-not $functions.ContainsKey('Select-MySqlServiceName')) {
    throw 'Interactive runs must offer a service picker when multiple MySQL services exist.'
}
if (-not $functions.ContainsKey('Get-MySqlUpdateInfo') -or
    -not $functions.ContainsKey('Get-MySqlLatestUpdateInfo') -or
    -not $functions.ContainsKey('Download-MySqlUpdateFile') -or
    -not $functions.ContainsKey('Install-MySqlUpdate') -or
    -not $functions.ContainsKey('New-MySqlUpdateForm') -or
    -not $functions.ContainsKey('Show-MySqlUpdateDialog')) {
    throw 'The updater must strictly validate release versions and asset metadata before offering an update.'
}
if (-not $functions.ContainsKey('Test-MySqlUpdateLauncher') -or
    -not $functions.ContainsKey('Replace-MySqlLauncher')) {
    throw 'The updater must replace only the validated current launcher and preserve rollback on failure.'
}
if (-not $functions.ContainsKey('Get-MySqlServiceAccountPrincipal')) {
    throw 'The script must map Windows built-in service accounts to portable SID-based ACL principals.'
}
if (-not $functions.ContainsKey('Resolve-MySqlLogRoot')) {
    throw 'The script must constrain the log root to a safe CommonApplicationData subdirectory.'
}

$argumentBuilder = [scriptblock]::Create(
    $functions['Get-MySqlServerArguments'].Extent.Text +
    "`nGet-MySqlServerArguments -DefaultsFile 'C:\Program Files\MySQL\my.ini' -InitFile 'C:\ProgramData\MySQL Reset\init.sql'"
)
$serverArguments = @(& $argumentBuilder)
if ($serverArguments.Count -ne 2 -or
    $serverArguments[0] -ne '--defaults-file="C:\Program Files\MySQL\my.ini"' -or
    $serverArguments[1] -ne '--init-file="C:/ProgramData/MySQL Reset/init.sql"') {
    throw 'MySQL server arguments must preserve quoted paths containing spaces.'
}

$portResolver = [scriptblock]::Create(
    $functions['Get-MySqlServerPort'].Extent.Text +
    "`nGet-MySqlServerPort -ConfigLines @('[client]', 'port=4406', '[mysqld]', 'port=3307')"
)
if ((& $portResolver) -ne 3307) {
    throw 'The script must read port from the [mysqld] section only.'
}
$defaultPortResolver = [scriptblock]::Create(
    $functions['Get-MySqlServerPort'].Extent.Text +
    "`nGet-MySqlServerPort -ConfigLines @('[client]', 'port=4406', '[mysqld]')"
)
if ((& $defaultPortResolver) -ne 3306) {
    throw "The script must use MySQL's default port if [mysqld] does not specify one."
}
$invalidPortResolver = [scriptblock]::Create(
    $functions['Get-MySqlServerPort'].Extent.Text +
    "`nGet-MySqlServerPort -ConfigLines @('[mysqld]', 'port=70000')"
)
$rejectedInvalidPort = $false
try {
    & $invalidPortResolver | Out-Null
} catch {
    $rejectedInvalidPort = $true
}
if (-not $rejectedInvalidPort) {
    throw 'The script must reject out-of-range MySQL ports.'
}
$malformedPortResolver = [scriptblock]::Create(
    $functions['Get-MySqlServerPort'].Extent.Text +
    "`nGet-MySqlServerPort -ConfigLines @('[mysqld]', 'port=not-a-number')"
)
$rejectedMalformedPort = $false
try {
    & $malformedPortResolver | Out-Null
} catch {
    $rejectedMalformedPort = $true
}
if (-not $rejectedMalformedPort) {
    throw 'The script must reject malformed server port values instead of silently using 3306.'
}
$includedConfigResolver = [scriptblock]::Create(
    $functions['Get-MySqlServerPort'].Extent.Text +
    "`nGet-MySqlServerPort -ConfigLines @('!include extra.ini', '[mysqld]')"
)
$rejectedIncludedConfig = $false
try {
    & $includedConfigResolver | Out-Null
} catch {
    $rejectedIncludedConfig = $true
}
if (-not $rejectedIncludedConfig) {
    throw 'The script must reject included configs instead of guessing the effective port.'
}

$password = 'Abc' + [char]92 + 'Def' + [char]39 + '123'
$passwordLiteral = "'" + $password.Replace("'", "''") + "'"
$sqlBuilder = [scriptblock]::Create(
    $functions['Assert-ResetPassword'].Extent.Text +
    "`n" +
    $functions['New-PasswordResetSql'].Extent.Text +
    "`nNew-PasswordResetSql -Password $passwordLiteral"
)
$resetSql = & $sqlBuilder
$expectedSqlPassword = 'Abc' + [char]92 + 'Def' + [char]39 + [char]39 + '123'
if (-not $resetSql.Contains("NO_BACKSLASH_ESCAPES") -or
    -not $resetSql.Contains("IDENTIFIED BY '$expectedSqlPassword';")) {
    throw 'Generated SQL must preserve backslashes and escape quotes safely.'
}

$unicodePasswordLiteral = "'Abc" + [char]0x00E9 + "123456'"
$unicodeSqlBuilder = [scriptblock]::Create(
    $functions['Assert-ResetPassword'].Extent.Text +
    "`n" +
    $functions['New-PasswordResetSql'].Extent.Text +
    "`nNew-PasswordResetSql -Password $unicodePasswordLiteral"
)
$rejectedUnicodePassword = $false
try {
    & $unicodeSqlBuilder | Out-Null
} catch {
    $rejectedUnicodePassword = $true
}
if (-not $rejectedUnicodePassword) {
    throw 'The script must reject password characters that its ASCII init file cannot preserve.'
}

$servicePath = '"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqld.exe" --defaults-file="C:\ProgramData\MySQL\MySQL Server 8.0\my.ini" MySQL80'
$servicePathTest = [scriptblock]::Create(
    $functions['Test-MySqlServiceImagePath'].Extent.Text +
    "`nTest-MySqlServiceImagePath -ImagePath '$servicePath' -ServiceName 'MySQL80'"
)
& $servicePathTest | Out-Null

$unsupportedServicePathTest = [scriptblock]::Create(
    $functions['Test-MySqlServiceImagePath'].Extent.Text +
    "`nTest-MySqlServiceImagePath -ImagePath 'mysqld.exe --defaults-file=my.ini --port=3307 MySQL80' -ServiceName 'MySQL80'"
)
$rejectedUnsupportedArguments = $false
try {
    & $unsupportedServicePathTest | Out-Null
} catch {
    $rejectedUnsupportedArguments = $true
}
if (-not $rejectedUnsupportedArguments) {
    throw 'The script must reject unsupported service arguments instead of silently misparsing them.'
}

$serviceNameResolver = [scriptblock]::Create(
    $functions['Resolve-MySqlServiceName'].Extent.Text +
    "`nResolve-MySqlServiceName -ServiceNames @('MySQL80')"
)
if ((& $serviceNameResolver) -ne 'MySQL80') {
    throw 'The script must resolve a single discovered MySQL service.'
}
$ambiguousServiceResolver = [scriptblock]::Create(
    $functions['Resolve-MySqlServiceName'].Extent.Text +
    "`nResolve-MySqlServiceName -ServiceNames @('MySQL80', 'MySQL_80')"
)
$rejectedAmbiguousServices = $false
try {
    & $ambiguousServiceResolver | Out-Null
} catch {
    $rejectedAmbiguousServices = $true
}
if (-not $rejectedAmbiguousServices) {
    throw 'The script must not arbitrarily select one of several MySQL services.'
}
$interactiveServicePicker = [scriptblock]::Create(
    $functions['Select-MySqlServiceName'].Extent.Text +
    "`n" +
    '$script:servicePickerInputs = @("not-a-number", "3", "2")' +
    "`n" +
    '$script:servicePickerIndex = 0' +
    "`n" +
    'function Read-Host { $value = $script:servicePickerInputs[$script:servicePickerIndex]; $script:servicePickerIndex++; return $value }' +
    "`n" +
    'function Write-Host { }' +
    "`n" +
    '$selectedService = Select-MySqlServiceName -ServiceNames @("MySQL80", "MySQL_80")' +
    "`n" +
    '[pscustomobject]@{ Name = $selectedService; Attempts = $script:servicePickerIndex }'
)
$pickerResult = & $interactiveServicePicker
if ($pickerResult.Name -ne 'MySQL_80' -or $pickerResult.Attempts -ne 3) {
    throw 'The interactive picker must use the service explicitly selected by the user.'
}
if ($powerShellSource -notmatch '(?s)if \(\$serviceNames\.Count -gt 1 -and -not \$Preflight\)\s*\{\s*\$ServiceName = Select-MySqlServiceName') {
    throw 'Interactive resets without a service name must display the service picker.'
}

$validReleaseResolver = [scriptblock]::Create(
    $functions['Get-MySqlUpdateInfo'].Extent.Text +
    "`n" +
    '$release = [pscustomobject]@{' +
    ' tag_name = "v1.2.0"; draft = $false; prerelease = $false;' +
    ' html_url = "https://github.com/Abel-Ajish/mysql-reset-windows/releases/tag/v1.2.0";' +
    ' assets = @([pscustomobject]@{' +
    ' name = "mysql_reset.bat"; state = "uploaded"; size = 27000;' +
    ' digest = "sha256:' + ('a' * 64) + '";' +
    ' browser_download_url = "https://github.com/Abel-Ajish/mysql-reset-windows/releases/download/v1.2.0/mysql_reset.bat"' +
    ' })' +
    '}; Get-MySqlUpdateInfo -Release $release -CurrentVersion "1.1.0"'
)
$validUpdateInfo = & $validReleaseResolver
if ($validUpdateInfo.Version -ne '1.2.0' -or
    $validUpdateInfo.Digest -ne ('a' * 64) -or
    $validUpdateInfo.Size -ne 27000) {
    throw 'A valid newer release must return its validated version, digest, and size.'
}

$currentReleaseResolver = [scriptblock]::Create(
    $functions['Get-MySqlUpdateInfo'].Extent.Text +
    "`n" +
    '$release = [pscustomobject]@{' +
    ' tag_name = "v1.1.0"; draft = $false; prerelease = $false; assets = @()' +
    '}; Get-MySqlUpdateInfo -Release $release -CurrentVersion "1.1.0"'
)
if ($null -ne (& $currentReleaseResolver)) {
    throw 'The updater must not offer an update when the installed version is current.'
}

$unsafeReleaseResolver = [scriptblock]::Create(
    $functions['Get-MySqlUpdateInfo'].Extent.Text +
    "`n" +
    '$release = [pscustomobject]@{' +
    ' tag_name = "v1.2.0"; draft = $false; prerelease = $false;' +
    ' assets = @([pscustomobject]@{' +
    ' name = "mysql_reset.bat"; state = "uploaded"; size = 27000;' +
    ' digest = "sha256:' + ('a' * 64) + '";' +
    ' browser_download_url = "https://example.invalid/mysql_reset.bat"' +
    ' })' +
    '}; Get-MySqlUpdateInfo -Release $release -CurrentVersion "1.1.0"'
)
$rejectedUnsafeUpdateUrl = $false
try {
    & $unsafeReleaseResolver | Out-Null
} catch {
    $rejectedUnsafeUpdateUrl = $true
}
if (-not $rejectedUnsafeUpdateUrl) {
    throw 'The updater must reject release assets outside the fixed GitHub repository.'
}
$invalidDigestResolver = [scriptblock]::Create(
    $functions['Get-MySqlUpdateInfo'].Extent.Text +
    "`n" +
    '$release = [pscustomobject]@{' +
    ' tag_name = "v1.2.0"; draft = $false; prerelease = $false;' +
    ' html_url = "https://github.com/Abel-Ajish/mysql-reset-windows/releases/tag/v1.2.0";' +
    ' assets = @([pscustomobject]@{' +
    ' name = "mysql_reset.bat"; state = "uploaded"; size = 27000;' +
    ' digest = $null;' +
    ' browser_download_url = "https://github.com/Abel-Ajish/mysql-reset-windows/releases/download/v1.2.0/mysql_reset.bat"' +
    ' })' +
    '}; Get-MySqlUpdateInfo -Release $release -CurrentVersion "1.1.0"'
)
$rejectedMissingDigest = $false
try {
    & $invalidDigestResolver | Out-Null
} catch {
    $rejectedMissingDigest = $true
}
if (-not $rejectedMissingDigest) {
    throw 'The updater must fail closed when GitHub does not provide an asset digest.'
}
if ($powerShellSource -notmatch '(?s)if \(-not \$Preflight -and -not \$SkipUpdateCheck -and -not \$Elevated\)') {
    throw 'Preflight and elevated reruns must not perform automatic update checks.'
}
if ($powerShellSource.IndexOf('$updateInfo = Get-MySqlLatestUpdateInfo') -lt 0 -or
    $powerShellSource.IndexOf('$updateInfo = Get-MySqlLatestUpdateInfo') -gt $powerShellSource.IndexOf('if (-not $isAdmin -and -not $Preflight)')) {
    throw 'Update checks must complete before the UAC elevation handoff.'
}

$updateTestRoot = Join-Path $env:TEMP ("MySqlResetUpdaterTest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $updateTestRoot -ErrorAction Stop | Out-Null
try {
    $replacementFunctions = [scriptblock]::Create(
        $functions['Test-MySqlUpdateLauncher'].Extent.Text +
        "`n" +
        $functions['Replace-MySqlLauncher'].Extent.Text
    )
    . $replacementFunctions

    $launcherPath = Join-Path $updateTestRoot 'mysql_reset.bat'
    $downloadedPath = Join-Path $updateTestRoot 'verified_update.bat'
    $oldLauncher = '@echo off' + [Environment]::NewLine + '$script:appVersion = "1.1.0"'
    $newLauncher = '@echo off' + [Environment]::NewLine + '$script:appVersion = "1.2.0"'
    [IO.File]::WriteAllText($launcherPath, $oldLauncher)
    [IO.File]::WriteAllText($downloadedPath, $newLauncher)
    $newDigest = (Get-FileHash -LiteralPath $downloadedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $update = [pscustomobject]@{
        Version = '1.2.0'
        Digest = $newDigest
        Size = (Get-Item -LiteralPath $downloadedPath).Length
    }

    $badDigestUpdate = [pscustomobject]@{
        Version = '1.2.0'
        Digest = ('0' * 64)
        Size = $update.Size
    }
    $rejectedTamperedUpdate = $false
    try {
        Replace-MySqlLauncher -LauncherPath $launcherPath -DownloadedPath $downloadedPath -UpdateInfo $badDigestUpdate -CurrentVersion '1.1.0' | Out-Null
    } catch {
        $rejectedTamperedUpdate = $true
    }
    if (-not $rejectedTamperedUpdate -or
        [IO.File]::ReadAllText($launcherPath) -ne $oldLauncher) {
        throw 'A digest mismatch must leave the current launcher unchanged.'
    }

    $wrongNamePath = Join-Path $updateTestRoot 'not_mysql_reset.bat'
    [IO.File]::WriteAllText($wrongNamePath, $oldLauncher)
    $rejectedWrongTarget = $false
    try {
        Replace-MySqlLauncher -LauncherPath $wrongNamePath -DownloadedPath $downloadedPath -UpdateInfo $update -CurrentVersion '1.1.0' | Out-Null
    } catch {
        $rejectedWrongTarget = $true
    }
    if (-not $rejectedWrongTarget -or
        [IO.File]::ReadAllText($wrongNamePath) -ne $oldLauncher) {
        throw 'The updater must refuse to replace a file other than the current named launcher.'
    }

    $backupPath = Replace-MySqlLauncher -LauncherPath $launcherPath -DownloadedPath $downloadedPath -UpdateInfo $update -CurrentVersion '1.1.0'
    if ([IO.File]::ReadAllText($launcherPath) -ne $newLauncher -or
        -not (Test-Path -LiteralPath $backupPath) -or
        [IO.File]::ReadAllText($backupPath) -ne $oldLauncher) {
        throw 'A verified replacement must install the new launcher and preserve a rollback copy.'
    }
} finally {
    Remove-Item -LiteralPath $updateTestRoot -Recurse -Force -ErrorAction Stop
}

$serviceAccountMapper = [scriptblock]::Create(
    $functions['Get-MySqlServiceAccountPrincipal'].Extent.Text +
    "`nGet-MySqlServiceAccountPrincipal -ServiceAccount 'LocalSystem'"
)
if ((& $serviceAccountMapper) -ne '*S-1-5-18') {
    throw 'LocalSystem must resolve to its locale-independent SID for ACL grants.'
}
$networkServiceMapper = [scriptblock]::Create(
    $functions['Get-MySqlServiceAccountPrincipal'].Extent.Text +
    "`nGet-MySqlServiceAccountPrincipal -ServiceAccount 'NT AUTHORITY\NetworkService'"
)
if ((& $networkServiceMapper) -ne '*S-1-5-20') {
    throw 'NetworkService must resolve to its locale-independent SID for ACL grants.'
}

$safeLogRootResolver = [scriptblock]::Create(
    $functions['Resolve-MySqlLogRoot'].Extent.Text +
    "`nResolve-MySqlLogRoot -LogRoot 'C:\ProgramData\MySQLPasswordReset' -CommonDataRoot 'C:\ProgramData'"
)
if ((& $safeLogRootResolver) -ne 'C:\ProgramData\MySQLPasswordReset') {
    throw 'The script must accept a dedicated log directory beneath CommonApplicationData.'
}
$unsafeLogRootResolver = [scriptblock]::Create(
    $functions['Resolve-MySqlLogRoot'].Extent.Text +
    "`nResolve-MySqlLogRoot -LogRoot 'C:\Windows' -CommonDataRoot 'C:\ProgramData'"
)
$rejectedUnsafeLogRoot = $false
try {
    & $unsafeLogRootResolver | Out-Null
} catch {
    $rejectedUnsafeLogRoot = $true
}
if (-not $rejectedUnsafeLogRoot) {
    throw 'The script must reject log paths outside CommonApplicationData.'
}

if ($powerShellSource -match 'Stop-Process\s+-Name\s+["'']mysqld["'']') {
    throw 'The script must not terminate every mysqld process on the machine.'
}

$elevationCall = [regex]::Match(
    $powerShellSource,
    '(?s)Start-Process\s+-FilePath\s+["'']powershell\.exe["''].*?(?=\r?\n\s*exit\s+\$elevatedProcess\.ExitCode)'
)
if (-not $elevationCall.Success -or
    $elevationCall.Value -notmatch '-Wait' -or
    $elevationCall.Value -notmatch '-PassThru') {
    throw 'The UAC handoff must use STA mode, wait for the elevated process, and return its exit code.'
}
if ($powerShellSource -notmatch '(?s)\$argList\s*=\s*@\(\s*"-STA"') {
    throw 'The elevated PowerShell process must also use STA mode for the Windows Forms update dialog.'
}
if (-not ($lines[0..$markerIndex] -match 'powershell\.exe -STA ')) {
    throw 'The batch launcher must use STA mode for the Windows Forms update dialog.'
}

if ($powerShellSource -notmatch '\$serviceWasRunning') {
    throw 'The script must preserve whether the Windows service was running before reset.'
}

if ($powerShellSource -notmatch 'icacls \$runDir /inheritance:r' -or
    $powerShellSource -notmatch 'if \(\$aclRc -ne 0\)' -or
    $powerShellSource -match 'icacls \$LogDir') {
    throw 'The per-run password directory must have checked, restrictive ACLs before the secret is written.'
}

if ($powerShellSource -notmatch 'Add-Content .* -ErrorAction Stop' -or
    $powerShellSource -match 'Add-Content .*SilentlyContinue' -or
    $powerShellSource -notmatch '\$script:loggingEnabled = \$false') {
    throw 'Audit logging errors must be explicit, and preflight must not write logs.'
}

if ($lines[3] -notmatch 'STAGE_DIR=%TEMP%') {
    throw 'The batch launcher must stage its script in a user-writable temporary directory.'
}

if ($powerShellSource -notmatch '\[switch\]\$Preflight' -or
    $powerShellSource -notmatch 'if \(\$Preflight\)\s*\{\s*Write-Host "\[PREFLIGHT OK\]') {
    throw 'The script must provide a read-only preflight that exits before password prompts.'
}

if ($lines[0..$markerIndex] -match '^\s*pause\s*$') {
    throw 'The batch launcher must return errors without blocking automation on pause.'
}

Write-Output 'PASS: embedded PowerShell parses.'
Write-Output 'PASS: cleanup targets only the temporary mysqld process.'
Write-Output 'PASS: MySQL server arguments quote paths containing spaces.'
Write-Output 'PASS: server port and password SQL are parsed/encoded safely.'
Write-Output 'PASS: service command-line arguments are validated safely.'
Write-Output 'PASS: multiple MySQL services require an explicit selection.'
Write-Output 'PASS: interactive reset offers a validated service selection menu.'
Write-Output 'PASS: updater validates release versions, URLs, sizes, and digests.'
Write-Output 'PASS: updater requires consent, runs before UAC, and safely replaces only the launcher.'
Write-Output 'PASS: built-in service accounts map to stable ACL SIDs.'
Write-Output 'PASS: UAC handoff waits for the elevated process.'
Write-Output 'PASS: pre-reset service state is tracked.'
Write-Output 'PASS: non-admin staging and read-only preflight are available.'

$script:appVersion = '1.1.0'
$uiFormFunction = [scriptblock]::Create($functions['New-MySqlUpdateForm'].Extent.Text)
. $uiFormFunction
$previewInfo = [pscustomobject]@{ Version = '1.2.0' }
$updateDialog = New-MySqlUpdateForm -UpdateInfo $previewInfo -LauncherPath 'C:\Preview\mysql_reset.bat'
try {
    if ($updateDialog.Form.Text -ne 'MySQL Password Reset - Update' -or
        $updateDialog.Form.ClientSize.Width -lt 520 -or
        $updateDialog.UpdateButton.Right -gt $updateDialog.Form.ClientSize.Width -or
        $updateDialog.LaterButton.Right -gt $updateDialog.Form.ClientSize.Width -or
        $updateDialog.UpdateButton.AccessibleName -ne 'Verify, install, and reopen the update' -or
        $updateDialog.LaterButton.AccessibleName -ne 'Continue with the current version') {
        throw 'The update dialog must have its expected title, fit its actions, and expose accessible labels.'
    }
} finally {
    $updateDialog.Form.Dispose()
}
Write-Output 'PASS: native update dialog constructs with accessible actions and expected layout.'
