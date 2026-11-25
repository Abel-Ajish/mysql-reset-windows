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
$launcherSource = $lines[0..($markerIndex - 1)] -join [Environment]::NewLine
if (-not $launcherSource.Contains('$PSVersionTable.PSVersion.Major -lt 3')) {
    throw 'The batch launcher must detect unsupported PowerShell before parsing the embedded script.'
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

$appVersionMatch = [regex]::Match($powerShellSource, '(?m)^\$script:appVersion = "(\d+\.\d+\.\d+)"\s*$')
$changelogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md'
$changelog = [IO.File]::ReadAllText($changelogPath)
$changelogVersionMatch = [regex]::Match($changelog, '(?m)^## (\d+\.\d+\.\d+) - ')
if (-not $appVersionMatch.Success -or
    -not $changelogVersionMatch.Success -or
    $appVersionMatch.Groups[1].Value -cne $changelogVersionMatch.Groups[1].Value) {
    throw 'The embedded launcher version must match the latest changelog version.'
}
$appVersion = $appVersionMatch.Groups[1].Value
$consoleParameter = @($ast.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -eq 'Console'
})
if ($consoleParameter.Count -ne 1 -or
    -not $powerShellSource.Contains('if ($Console) { $argList += "-Console" }') -or
    -not $powerShellSource.Contains('$script:resetUiEnabled = (-not $Console -and -not $Preflight -and')) {
    throw 'The console fallback must be explicit, survive UAC handoff, and keep preflight non-UI.'
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
if (-not $functions.ContainsKey('Assert-MySqlTemporaryServerOwnsPort')) {
    throw 'The reset must recognize a verified mysqld child process without trusting unrelated port owners.'
}
if (-not $functions.ContainsKey('Test-MySqlResetUiSupported') -or
    -not $functions.ContainsKey('Set-MySqlResetConsoleWindowVisibility') -or
    -not $functions.ContainsKey('Set-MySqlResetTheme')) {
    throw 'The reset workflow must provide compatibility fallback, console hiding, and an adjustable UI theme.'
}
$uiSupportFunction = [scriptblock]::Create($functions['Test-MySqlResetUiSupported'].Extent.Text)
. $uiSupportFunction
if ((Test-MySqlResetUiSupported -PowerShellVersion ([Version]'5.0')) -or
    -not (Test-MySqlResetUiSupported -PowerShellVersion ([Version]'5.1'))) {
    throw 'PowerShell versions before 5.1 must use console mode; 5.1 and later can use the reset UI.'
}
if ($functions['Show-MySqlResetForm'].Extent.Text.IndexOf('$ui.Form.Show()') -lt 0 -or
    $functions['Show-MySqlResetForm'].Extent.Text.IndexOf('Set-MySqlResetConsoleWindowVisibility -Visible:$false') -lt
    $functions['Show-MySqlResetForm'].Extent.Text.IndexOf('$ui.Form.Show()') -or
    -not $powerShellSource.Contains('Set-MySqlResetConsoleWindowVisibility -Visible:$true') -or
    $functions['Fail-WithReport'].Extent.Text -match 'resetUiEnabled\s*=\s*\$false|Falling back to console prompts' -or
    $powerShellSource -notmatch '(?s)elseif \(\$script:resetUiEnabled\)\s*\{\s*Write-Log "\[ABORT\] Cancelled by user') {
    throw 'Only the reset UI may hide the elevated terminal, and the fallback must be able to restore it.'
}
if (-not $functions.ContainsKey('Assert-MySqlTemporaryServerOwnsPort') -or
    -not $functions.ContainsKey('Get-MySqlListeningProcessIds') -or
    -not $functions.ContainsKey('Assert-MySqlServiceOwnsPort') -or
    -not $functions.ContainsKey('Test-MySqlProcessBelongsToService')) {
    throw 'The reset must verify that the MySQL port belongs to the temporary server before trusting authentication.'
}
if (-not $powerShellSource.Contains('$existingListenerProcessIds = @(Get-MySqlListeningProcessIds -Port $dbPort)') -or
    $powerShellSource -notmatch 'Assert-MySqlTemporaryServerOwnsPort\s+`?\s*-Port \$dbPort\s+`?\s*-ExpectedProcessId \$script:tempProcess\.Id' -or
    -not $powerShellSource.Contains('if (-not (Assert-MySqlTemporaryServerOwnsPort `') -or
    -not $powerShellSource.Contains('if ($temporaryServerIsListening) {') -or
    -not $powerShellSource.Contains('Temporary MySQL had already stopped after the successful password check.') -or
    -not $powerShellSource.Contains('Assert-MySqlServiceOwnsPort -Port $dbPort -ServiceProcessId $serviceProcessIds[0]')) {
    throw 'The reset must check for an occupied port, verify the temporary server, and verify the restored service process.'
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

$temporaryServerGuard = [scriptblock]::Create($functions['Assert-MySqlTemporaryServerOwnsPort'].Extent.Text)
. $temporaryServerGuard
$temporaryServerExe = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqld.exe'
$temporaryInitFile = 'C:\ProgramData\MySQLPasswordReset\run_test\init.sql'
$temporaryCommandLine = '"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqld.exe" --defaults-file="C:\ProgramData\MySQL\MySQL Server 8.0\my.ini" --init-file="C:/ProgramData/MySQLPasswordReset/run_test/init.sql"'
$temporaryProcessTree = @(
    [pscustomobject]@{
        ProcessId = 6552; ParentProcessId = 1200
        ExecutablePath = $temporaryServerExe; CommandLine = $temporaryCommandLine
    }
    [pscustomobject]@{
        ProcessId = 2952; ParentProcessId = 6552
        ExecutablePath = $temporaryServerExe; CommandLine = $temporaryCommandLine
    }
)
$directTemporaryServerOwner = Assert-MySqlTemporaryServerOwnsPort -Port 3306 -ExpectedProcessId 6552 `
    -ExpectedExecutablePath $temporaryServerExe -InitFilePath $temporaryInitFile `
    -ListenerProcessIds @(6552) -Processes @($temporaryProcessTree[0])
$temporaryChildServerOwner = Assert-MySqlTemporaryServerOwnsPort -Port 3306 -ExpectedProcessId 6552 `
    -ExpectedExecutablePath $temporaryServerExe -InitFilePath $temporaryInitFile `
    -ListenerProcessIds @(2952) -Processes $temporaryProcessTree
if (-not $directTemporaryServerOwner -or -not $temporaryChildServerOwner) {
    throw 'The launched mysqld process and its verified child must be accepted as the temporary server.'
}
$temporaryServerStoppedAfterProbe = Assert-MySqlTemporaryServerOwnsPort -Port 3306 -ExpectedProcessId 6552 `
    -ExpectedExecutablePath $temporaryServerExe -InitFilePath $temporaryInitFile `
    -ListenerProcessIds @() -Processes @($temporaryProcessTree[0])
if ($temporaryServerStoppedAfterProbe) {
    throw 'A temporary server that stopped after the successful password probe must be reported as no longer listening.'
}
$unrelatedTemporaryOwnerRejected = $false
try {
    Assert-MySqlTemporaryServerOwnsPort -Port 3306 -ExpectedProcessId 6552 `
        -ExpectedExecutablePath $temporaryServerExe -InitFilePath $temporaryInitFile `
        -ListenerProcessIds @(7777) -Processes @(
            $temporaryProcessTree
            [pscustomobject]@{
                ProcessId = 7777; ParentProcessId = 1200
                ExecutablePath = $temporaryServerExe; CommandLine = $temporaryCommandLine
            }
        )
} catch {
    $unrelatedTemporaryOwnerRejected = $_.Exception.Message -match 'has ancestry'
}
if (-not $unrelatedTemporaryOwnerRejected) {
    throw 'A separate mysqld process must not be accepted as the temporary server.'
}
$wrongExecutableRejected = $false
try {
    Assert-MySqlTemporaryServerOwnsPort -Port 3306 -ExpectedProcessId 6552 `
        -ExpectedExecutablePath $temporaryServerExe -InitFilePath $temporaryInitFile `
        -ListenerProcessIds @(2952) -Processes @(
            $temporaryProcessTree[0]
            [pscustomobject]@{
                ProcessId = 2952; ParentProcessId = 6552
                ExecutablePath = 'C:\Other\mysqld.exe'; CommandLine = $temporaryCommandLine
            }
        )
} catch {
    $wrongExecutableRejected = $_.Exception.Message -match 'has ancestry'
}
if (-not $wrongExecutableRejected) {
    throw 'A child process from another mysqld executable must not be accepted.'
}
$wrongInitFileRejected = $false
try {
    Assert-MySqlTemporaryServerOwnsPort -Port 3306 -ExpectedProcessId 6552 `
        -ExpectedExecutablePath $temporaryServerExe -InitFilePath 'C:\ProgramData\MySQLPasswordReset\other.sql' `
        -ListenerProcessIds @(2952) -Processes $temporaryProcessTree
} catch {
    $wrongInitFileRejected = $_.Exception.Message -match 'expected init-file argument'
}
if (-not $wrongInitFileRejected) {
    throw 'The launched process must use the exact init file created for this run before its listener is trusted.'
}
Write-Output 'PASS: direct and child mysqld owners are verified; unrelated owners are rejected.'

$listenerQueryTest = [scriptblock]::Create(
    $functions['Get-MySqlListeningProcessIds'].Extent.Text +
    @'
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$Namespace, [string]$ClassName, [string]$Filter)
    $connections = @(
        [pscustomobject]@{ LocalPort = 3306; State = 'Listen'; OwningProcess = 4321 }
        [pscustomobject]@{ LocalPort = 3306; State = 'Listen'; OwningProcess = 4321 }
        [pscustomobject]@{ LocalPort = 3307; State = 'Listen'; OwningProcess = 9876 }
    )
    $port = [int]([regex]::Match($Filter, 'LocalPort = (\d+)').Groups[1].Value)
    return @($connections | Where-Object { $_.LocalPort -eq $port })
}
$matchingListeners = @(Get-MySqlListeningProcessIds -Port 3306)
$missingListeners = @(Get-MySqlListeningProcessIds -Port 65001)
[pscustomobject]@{ Matching = $matchingListeners; MissingCount = $missingListeners.Count }
'@
)
$listenerLookupResult = & $listenerQueryTest
if (@($listenerLookupResult.Matching).Count -ne 1 -or
    $listenerLookupResult.Matching[0] -ne 4321 -or
    $listenerLookupResult.MissingCount -ne 0) {
    throw 'Port listener lookup must return unique owners and treat an unused port as an empty result.'
}
Write-Output 'PASS: listener lookup handles a free TCP port without hiding query errors.'

$servicePortGuard = [scriptblock]::Create(
    $functions['Test-MySqlProcessBelongsToService'].Extent.Text +
    "`n" +
    $functions['Assert-MySqlServiceOwnsPort'].Extent.Text
)
. $servicePortGuard
$serviceProcesses = @(
    [pscustomobject]@{ ProcessId = 4440; ParentProcessId = 14704 }
    [pscustomobject]@{ ProcessId = 14704; ParentProcessId = 740 }
    [pscustomobject]@{ ProcessId = 740; ParentProcessId = 932 }
)
Assert-MySqlServiceOwnsPort -Port 3306 -ServiceProcessId 14704 -ListenerProcessIds @(4440) -Processes $serviceProcesses
$unrelatedServiceListenerRejected = $false
try {
    Assert-MySqlServiceOwnsPort -Port 3306 -ServiceProcessId 14704 -ListenerProcessIds @(9876) -Processes $serviceProcesses
} catch {
    $unrelatedServiceListenerRejected = $_.Exception.Message -match 'not owned by service'
}
if (-not $unrelatedServiceListenerRejected) {
    throw 'Post-reset login must reject a listener outside the selected Windows service process tree.'
}
Write-Output 'PASS: service-owned child mysqld listeners are accepted and unrelated listeners rejected.'
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
if ($powerShellSource -notmatch '(?s)if \(-not \$Preflight -and -not \$SkipUpdateCheck -and -not \$Elevated -and\s+\(Test-MySqlResetUiSupported') {
    throw 'Preflight, elevated reruns, and older PowerShell versions must not perform automatic update checks.'
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

$serviceCompletion = [regex]::Match(
    $powerShellSource,
    '(?s)Write-Log "\[OK\] Wiped and deleted init SQL file\.".{0,8000}?Write-Log "\[SUCCESS\] MySQL root password reset and verified\."'
)
if (-not $serviceCompletion.Success -or
    $serviceCompletion.Value -match 'if \(\$serviceWasRunning\)\s*\{\s*Write-Log "\[INFO\] Restoring service' -or
    $serviceCompletion.Value -notmatch 'Start-Service -Name \$ServiceName -ErrorAction Stop' -or
    $serviceCompletion.Value -match 'leaving it stopped|remains stopped') {
    throw 'A successful reset must start and verify the selected service even if it was stopped before the reset.'
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

if ($launcherSource -notmatch 'set "STAGE_DIR=%TEMP%') {
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

$nativeProbeFunction = $functions['Invoke-MySqlAuthenticationProbe']
if (-not $nativeProbeFunction) {
    throw 'Transient MySQL connection errors must be captured without aborting the startup retry loop.'
}
$nativeProbeTest = [scriptblock]::Create(
    $nativeProbeFunction.Extent.Text +
    "`nInvoke-MySqlAuthenticationProbe -MySqlExe `$env:ComSpec -Arguments @('/d', '/c', 'echo transient connect error 1>&2 & exit /b 1') -Password 'test-only'"
)
$ErrorActionPreference = 'Stop'
$env:MYSQL_PWD = $null
$probeResult = & $nativeProbeTest
if ($probeResult.ExitCode -ne 1 -or
    $probeResult.Output -notmatch 'transient connect error' -or
    $ErrorActionPreference -ne 'Stop' -or
    $null -ne $env:MYSQL_PWD) {
    throw 'A failed native MySQL probe must be captured, preserve strict error handling, and clear the password environment variable.'
}
if ($powerShellSource -notmatch '(?s)\$probeResult = Invoke-MySqlAuthenticationProbe\s+`?\s*-MySqlExe \$mysqlExe') {
    throw 'The temporary-server readiness loop must use the retry-safe authentication probe.'
}
$global:LASTEXITCODE = 0
Write-Output 'PASS: transient native connection errors do not abort readiness retries.'

$waitResultFunction = $functions['Wait-ForResult']
if (-not $waitResultFunction) {
    throw 'Interactive reset results must remain visible until the user acknowledges them.'
}
$waitResultCases = @(
    @{ NoWait = '$false'; Preflight = '$false'; ExpectedPrompts = 1 },
    @{ NoWait = '$true'; Preflight = '$false'; ExpectedPrompts = 0 },
    @{ NoWait = '$false'; Preflight = '$true'; ExpectedPrompts = 0 }
)
foreach ($waitCase in $waitResultCases) {
    $global:waitResultPromptCount = 0
    $waitResultTest = [scriptblock]::Create(
        $waitResultFunction.Extent.Text +
        "`nfunction Read-Host { `$global:waitResultPromptCount++; return '' }" +
        "`n`$NoWait = $($waitCase.NoWait); `$Preflight = $($waitCase.Preflight); Wait-ForResult"
    )
    & $waitResultTest
    if ($global:waitResultPromptCount -ne $waitCase.ExpectedPrompts) {
        throw 'Reset results must wait for acknowledgment except in preflight or explicit no-wait mode.'
    }
}
if ($functions['Fail-WithReport'].Extent.Text -notmatch '\bWait-ForResult\b' -or
    ([regex]::Matches($powerShellSource, '(?m)^\s*Wait-ForResult\s*$')).Count -lt 3) {
    throw 'Failure, cancellation, and success outcomes must all keep the result visible.'
}
if ($powerShellSource -notmatch '\[switch\]\$NoWait' -or
    $powerShellSource -notmatch 'if \(\$NoWait\) \{ \$argList \+= "-NoWait" \}') {
    throw 'The no-wait option must also be preserved across the UAC handoff.'
}
Write-Output 'PASS: reset outcomes stay visible and automation can explicitly skip waiting.'

$script:appVersion = $appVersion
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

$resetUiFunctionNames = @('New-MySqlResetForm', 'Submit-MySqlResetForm')
foreach ($functionName in $resetUiFunctionNames) {
    if (-not $functions.ContainsKey($functionName)) {
        throw "The password reset workflow must provide its own native reset UI ($functionName)."
    }
}
$resetUiFunctions = [scriptblock]::Create(
    $functions['Assert-ResetPassword'].Extent.Text +
    "`n" +
    $functions['Set-MySqlResetTheme'].Extent.Text +
    "`n" +
    $functions['New-MySqlResetForm'].Extent.Text +
    "`n" +
    $functions['Submit-MySqlResetForm'].Extent.Text
)
. $resetUiFunctions
$resetUi = New-MySqlResetForm -ServiceNames @('MySQL80', 'MySQL_80') -InitialServiceName 'MySQL80'
try {
    if ($resetUi.Form.Text -ne 'MySQL Password Reset' -or
    -not $resetUi.ThemeToggle.Checked -or
    $resetUi.ThemeToggle.AccessibleName -ne 'Toggle dark mode' -or
    $resetUi.Form.BackColor -ne [System.Drawing.Color]::FromArgb(28, 36, 46) -or
    $resetUi.PasswordBox.BackColor -ne [System.Drawing.Color]::FromArgb(42, 53, 66) -or
    $resetUi.ProgressLog.BackColor -ne [System.Drawing.Color]::FromArgb(20, 27, 36) -or
        $resetUi.ServiceSelector.SelectedItem.Name -ne 'MySQL80' -or
        $resetUi.ServiceSelector.GetItemText($resetUi.ServiceSelector.SelectedItem) -ne 'MySQL80' -or
        -not $resetUi.PasswordBox.UseSystemPasswordChar -or
        -not $resetUi.ConfirmPasswordBox.UseSystemPasswordChar -or
        -not $resetUi.ResultDetails.Multiline -or
        $resetUi.ResultDetails.ScrollBars -ne [System.Windows.Forms.ScrollBars]::Vertical -or
        $resetUi.ResetButton.Text -ne 'Reset password' -or
        $resetUi.OpenLogButton.Text -ne 'Open reset log' -or
        -not $resetUi.ProgressLog.ReadOnly -or
        $resetUi.Form.AcceptButton -ne $resetUi.ResetButton) {
        throw 'The reset UI must provide a masked password form, service choice, live log, and accessible actions.'
    }

    $resetUi.ThemeToggle.Checked = $false
    if ($resetUi.Form.BackColor -ne [System.Drawing.Color]::FromArgb(245, 247, 250) -or
        $resetUi.PasswordBox.BackColor -ne [System.Drawing.Color]::White -or
        $resetUi.ProgressLog.BackColor -ne [System.Drawing.Color]::White) {
        throw 'Turning off dark mode must restore the light theme.'
    }
    $resetUi.ThemeToggle.Checked = $true
    if ($resetUi.Form.BackColor -ne [System.Drawing.Color]::FromArgb(28, 36, 46)) {
        throw 'Turning on dark mode must restore the dark theme.'
    }

    $resetUi.PasswordBox.Text = 'LocalTest!Password9'
    $resetUi.ConfirmPasswordBox.Text = 'LocalTest!Password9'
    $resetUi.ConfirmationCheckBox.Checked = $true
    if (-not (Submit-MySqlResetForm -Ui $resetUi) -or
        -not $resetUi.State.Submitted -or
        $resetUi.State.ServiceName -ne 'MySQL80' -or
        $resetUi.State.SecurePassword.Length -ne 19 -or
        $resetUi.PasswordBox.Text -or
        $resetUi.ConfirmPasswordBox.Text) {
        throw 'A confirmed reset submission must capture a secure password and clear both UI fields.'
    }
} finally {
    if ($resetUi.State.SecurePassword) { $resetUi.State.SecurePassword.Dispose() }
    $resetUi.Form.Dispose()
}

$invalidResetUi = New-MySqlResetForm -ServiceNames @('MySQL80') -InitialServiceName 'MySQL80'
try {
    $invalidResetUi.PasswordBox.Text = 'LocalTest!Password9'
    $invalidResetUi.ConfirmPasswordBox.Text = 'DifferentLocalTest!9'
    $invalidResetUi.ConfirmationCheckBox.Checked = $true
    if ((Submit-MySqlResetForm -Ui $invalidResetUi) -or
        $invalidResetUi.State.Submitted -or
        $invalidResetUi.StatusLabel.Text -notmatch 'do not match') {
        throw 'The reset UI must reject mismatched password confirmation before starting.'
    }
} finally {
    if ($invalidResetUi.State.SecurePassword) { $invalidResetUi.State.SecurePassword.Dispose() }
    $invalidResetUi.Form.Dispose()
}

$unconfirmedResetUi = New-MySqlResetForm -ServiceNames @('MySQL80')
try {
    $unconfirmedResetUi.PasswordBox.Text = 'LocalTest!Password9'
    $unconfirmedResetUi.ConfirmPasswordBox.Text = 'LocalTest!Password9'
    if ((Submit-MySqlResetForm -Ui $unconfirmedResetUi) -or
        $unconfirmedResetUi.State.Submitted -or
        $unconfirmedResetUi.StatusLabel.Text -notmatch 'Confirm') {
        throw 'The reset UI must require explicit confirmation before starting.'
    }
} finally {
    $unconfirmedResetUi.Form.Dispose()
}

$shortPasswordResetUi = New-MySqlResetForm -ServiceNames @('MySQL80')
try {
    $shortPasswordResetUi.PasswordBox.Text = 'Short9!'
    $shortPasswordResetUi.ConfirmPasswordBox.Text = 'Short9!'
    $shortPasswordResetUi.ConfirmationCheckBox.Checked = $true
    if ((Submit-MySqlResetForm -Ui $shortPasswordResetUi) -or
        $shortPasswordResetUi.State.Submitted -or
        $shortPasswordResetUi.StatusLabel.Text -notmatch 'at least 8 characters' -or
        $shortPasswordResetUi.PasswordBox.Text -or
        $shortPasswordResetUi.ConfirmPasswordBox.Text) {
        throw 'The reset UI must reject and clear passwords shorter than the minimum.'
    }
} finally {
    $shortPasswordResetUi.Form.Dispose()
}
Write-Output 'PASS: reset dialog requires explicit confirmation and rejects short passwords.'

Write-Output 'PASS: reset dialog constructs, masks and validates credentials, and clears inputs after submit.'

$uiLoggingFunction = [scriptblock]::Create($functions['Write-Log'].Extent.Text)
. $uiLoggingFunction
$progressLog = New-Object System.Windows.Forms.RichTextBox
$statusLabel = New-Object System.Windows.Forms.Label
$openLogButton = New-Object System.Windows.Forms.Button
$script:loggingEnabled = $false
$script:logFile = $null
$script:resetUi = [pscustomobject]@{
    ProgressLog = $progressLog
    StatusLabel = $statusLabel
    OpenLogButton = $openLogButton
}
try {
    Write-Log '[INFO] UI progress logging regression check.'
    if ($progressLog.Text -notmatch '\[INFO\] UI progress logging regression check\.' -or
        $statusLabel.Text -ne '[INFO] UI progress logging regression check.') {
        throw 'Reset progress messages must appear in both the UI log and current status.'
    }
} finally {
    $script:resetUi = $null
    $progressLog.Dispose()
    $statusLabel.Dispose()
    $openLogButton.Dispose()
}
Write-Output 'PASS: reset progress messages are streamed to the UI.'

$resetResultFunction = [scriptblock]::Create($functions['Show-MySqlResetUiResult'].Extent.Text)
. $resetResultFunction
$resultUi = New-MySqlResetForm -ServiceNames @('MySQL80')
$script:resetUi = $resultUi
$script:logFile = $null
try {
    Show-MySqlResetUiResult -Success:$false -Title 'Reset failed: test step' -Details "Reason: test failure.`r`nSuggested fix: retry."
    if (-not $resultUi.State.Completed -or
        $resultUi.ResultLabel.Text -ne 'Reset failed: test step' -or
        $resultUi.ResultDetails.Text -notmatch 'Reason: test failure\.' -or
        $resultUi.ResultDetails.Text -notmatch 'Suggested fix: retry\.' -or
        $resultUi.CancelButton.Text -ne 'Close') {
        throw 'Reset failures must persist their reason and suggested fix in the result view.'
    }
} finally {
    $script:resetUi = $null
}
Write-Output 'PASS: reset failure results retain the reason, suggested fix, and close action.'

$successResultUi = New-MySqlResetForm -ServiceNames @('MySQL80')
$script:resetUi = $successResultUi
try {
    Show-MySqlResetUiResult -Success:$true -Title 'Password reset completed' -Details 'Password reset was verified.'
    if (-not $successResultUi.State.Completed -or
        $successResultUi.ResultLabel.Text -ne 'Password reset completed' -or
        $successResultUi.ResultDetails.Text -ne 'Password reset was verified.' -or
        $successResultUi.ProgressBar.Value -ne 100 -or
        $successResultUi.StatusLabel.Text -notmatch 'successfully') {
        throw 'Reset success must be clearly shown and marked complete in the result view.'
    }
} finally {
    $script:resetUi = $null
}
Write-Output 'PASS: reset success results are clearly shown as complete.'
