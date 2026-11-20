# vprod-env setup for Windows (Windows PowerShell 5.1 and PowerShell 7).
# Sets up a remote Ubuntu server for Claude Code: a user with an SSH key, Claude Code,
# a desktop for the Claude login, a firewall. Then prepares VS Code Remote-SSH.
#
# Run in Windows PowerShell 5.1 (for PowerShell 7 use pwsh instead of powershell):
#   [Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb <BASE_URL>/setup.ps1 -OutFile "$env:TEMP\vprod-setup.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\vprod-setup.ps1"
# Other actions: add -Action desktop, -Action login or -Action check.
#
# Settings: the parameters -ServerHost, -SshPort, -User, -Alias, -Desktop, or the
# environment variables VPROD_HOST, VPROD_SSH_PORT, VPROD_USER, VPROD_SSH_ALIAS,
# VPROD_DESKTOP, VPROD_BASE_URL. A parameter wins over its environment variable.
#
# Keep this file ASCII only: Windows PowerShell 5.1 reads a file without a BOM as ANSI.
# VPROD_ENV_VERSION=0.1.0

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Colored output for the user in the console')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive installer, every step is announced')]
[CmdletBinding()]
param(
    [string]$Action = '',
    [string]$ServerHost = '',
    [string]$SshPort = '',
    [string]$User = '',
    [string]$Alias = '',
    [string]$Desktop = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The parameters, copied to the script scope for the functions below.
$script:ArgAction = $Action
$script:ArgHost = $ServerHost
$script:ArgPort = $SshPort
$script:ArgUser = $User
$script:ArgAlias = $Alias
$script:ArgDesktop = $Desktop

$script:Version = '0.1.0'
$script:DefaultBaseUrl = 'https://raw.githubusercontent.com/ggender/vprod-env/v' + $script:Version
$script:ServerDir = '/var/lib/vprod-env'
$script:ServerScript = '/var/lib/vprod-env/server.sh'
$script:StepTotal = 10
$script:SshCommon = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=6')
# Probes must never reuse a shared connection from the user's own SSH config.
$script:SshProbe = @('-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none')
$script:PasswordOpts = @('-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password,keyboard-interactive')

$script:ActionName = 'setup'
$script:HostName = ''
$script:Port = 22
$script:SrvUser = ''
$script:AliasName = ''
$script:DesktopValue = '1'
$script:BaseUrl = ''
$script:SshDir = ''
$script:ConfigPath = ''
$script:BeginMark = ''
$script:EndMark = ''
$script:KeyPath = ''
$script:KeyB64 = ''
$script:PreflightPath = ''
$script:ServerPath = ''
$script:TempFiles = New-Object System.Collections.ArrayList
$script:TunnelProc = $null
$script:Login = ''
$script:UseAlias = $false
$script:Sudo = ''
$script:Rerun = $false
$script:NeedPassword = $false
$script:VsCodeOk = $false
$script:ErrorHint = 'none'
$script:CapOut = ''
$script:CapErr = ''
$script:CapRc = 0
$script:LastRc = 0
$script:SrvVersion = ''
$script:SrvDesktop = ''
$script:SrvPrepared = '0'
$script:SrvHardened = '0'
$script:PhaseRc = 0
$script:FollowCount = 0
$script:ExitCode = 0
$script:OldOutputEncoding = $null
$script:UseColor = $false

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-Colored {
    param([string]$Text, [ConsoleColor]$Color)
    if ($script:UseColor) {
        Write-Host $Text -ForegroundColor $Color
    }
    else {
        Write-Host $Text
    }
}

function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ''
    Write-Colored ('[{0}/{1}] {2}' -f $Number, $script:StepTotal, $Title) Cyan
}

function Write-StepDone {
    Write-Colored 'Done' Green
}

# One of the key warnings, on its own line with empty lines around it.
function Show-KeyWarning {
    param([string]$Text)
    Write-Host ''
    Write-Colored $Text Yellow
    Write-Host ''
}

# The command that runs an action of this script.
function Get-ActionCommand {
    param([string]$Name)
    $exe = 'powershell'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $exe = 'pwsh'
    }
    $base = $script:BaseUrl
    if (-not $base) {
        $base = $script:DefaultBaseUrl
    }
    $prefix = ''
    if ($base -ne $script:DefaultBaseUrl) {
        $prefix = '$env:VPROD_BASE_URL=''' + $base + '''; '
    }
    $extra = ''
    if ($script:AliasName -and $script:AliasName -ne 'vprod') {
        $extra = ' -Alias ' + $script:AliasName
    }
    return $prefix + '[Net.ServicePointManager]::SecurityProtocol=''Tls12''; iwr -useb ' + $base +
    '/setup.ps1 -OutFile "$env:TEMP\vprod-setup.ps1"; ' + $exe +
    ' -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\vprod-setup.ps1" -Action ' + $Name + $extra
}

# Prints the error and a hint, then stops the script with exit code 1.
function Stop-Setup {
    param([string]$What, [string]$Todo = '')
    Write-Host ''
    Write-Colored ('ERROR: ' + $What) Red
    if ($Todo) {
        Write-Host $Todo
    }
    if ($script:ErrorHint -eq 'rerun') {
        Show-KeyWarning 'Nothing is broken. Run the same command again to continue.'
    }
    elseif ($script:ErrorHint -eq 'check') {
        Write-Host ''
        Write-Host 'To check the server, run:'
        Write-Host ('  ' + (Get-ActionCommand 'check'))
    }
    $script:ExitCode = 1
    throw 'vprod-env-stop'
}

# Stops the script with the given exit code, without an error message.
function Exit-Setup {
    param([int]$Code)
    $script:ExitCode = $Code
    throw 'vprod-env-stop'
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

function Read-Answer {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) {
        $text = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
    }
    else {
        $text = Read-Host $Prompt
    }
    if ($null -eq $text) {
        $text = ''
    }
    $text = $text.Trim()
    if ($text -eq '') {
        $text = $Default
    }
    return $text
}

function Test-Yes {
    param([string]$Text)
    return ($Text -ceq 'y' -or $Text -ceq 'Y' -or $Text -ceq 'yes' -or $Text -ceq 'Yes' -or $Text -ceq 'YES')
}

# The validators return $null if the value is fine, or a message if it is not.
function Test-HostValue {
    param([string]$Value)
    if ($Value -eq '') {
        return 'The server address is empty. Type the IPv4 address of the server, like 203.0.113.10.'
    }
    if ($Value.Contains('://')) {
        return 'Type only the server address, without http:// or ssh://.'
    }
    if ($Value.Contains(':')) {
        return 'IPv6 is not supported. Use the IPv4 address of the server.'
    }
    if ($Value -match '[\s@/\\]') {
        return 'Type only the server address, like 203.0.113.10. Do not add a user name, spaces or a path.'
    }
    if ($Value -cmatch '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$') {
        foreach ($part in $Value.Split('.')) {
            if ([int]$part -gt 255) {
                return ('The address {0} is not a valid IPv4 address. Each of the four numbers must be from 0 to 255.' -f $Value)
            }
        }
        return $null
    }
    if ($Value -cmatch '^[0-9.]+$') {
        return ('The address {0} is not a valid IPv4 address. It must have four numbers, like 203.0.113.10.' -f $Value)
    }
    if ($Value.Length -le 253 -and $Value -cmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$') {
        return $null
    }
    return ('The server address "{0}" is not valid. Use the IPv4 address of the server, like 203.0.113.10.' -f $Value)
}

# The port is checked as a string first, so a wrong value gives a clear message.
function Test-PortValue {
    param([string]$Value)
    if ($Value -cmatch '^[0-9]{1,5}$') {
        $number = [int]$Value
        if ($number -ge 1 -and $number -le 65535) {
            return $null
        }
    }
    return ('The port "{0}" is not valid. Type a number from 1 to 65535. The usual SSH port is 22.' -f $Value)
}

function Test-UserValue {
    param([string]$Value)
    if ($Value -ceq 'root') {
        return 'The user name cannot be root. Choose another name, like vprod.'
    }
    if ($Value -cmatch '^[a-z][a-z0-9_-]{0,30}$') {
        return $null
    }
    return ('The user name "{0}" is not valid. Use lowercase letters, digits, - and _, and start with a letter.' -f $Value)
}

function Test-AliasValue {
    param([string]$Value)
    if ($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$') {
        return $null
    }
    return ('The connection name "{0}" is not valid. Use letters, digits, ., - and _, and start with a letter or a digit.' -f $Value)
}

# The name is valid, and the SSH config has no other "Host <name>".
function Test-AliasFree {
    param([string]$Value)
    $message = Test-AliasValue $Value
    if ($message) {
        return $message
    }
    Set-Marker $Value
    if (-not (Test-ConfigMarker)) {
        Stop-Setup ('Your SSH config {0} has the line "{1}" but no line "{2}".' -f $script:ConfigPath, $script:BeginMark, $script:EndMark) 'Open the file, fix or delete that block, and run the command again.'
    }
    if (Test-ForeignHost $Value) {
        return ('Your SSH config {0} already has "Host {1}", and the setup did not write it. Choose another connection name.' -f $script:ConfigPath, $Value)
    }
    return $null
}

# Takes the value from the parameter, then from the environment, or asks for it.
function Get-Setting {
    param([string]$ParamValue, [string]$ParamName, [string]$EnvName, [string]$Prompt, [string]$Default, [scriptblock]$Check)
    $source = $ParamName
    $value = $ParamValue
    if ([string]::IsNullOrEmpty($value)) {
        $value = [Environment]::GetEnvironmentVariable($EnvName)
        $source = $EnvName
    }
    if ($null -eq $value) {
        $value = ''
    }
    $value = $value.Trim()
    if ($value -ne '') {
        $message = & $Check $value
        if ($message) {
            Stop-Setup ('{0}: {1}' -f $source, $message) ('Fix {0} and run the command again.' -f $source)
        }
        return $value
    }
    while ($true) {
        $answer = Read-Answer $Prompt $Default
        $message = & $Check $answer
        if (-not $message) {
            return $answer
        }
        Write-Host $message
    }
}

function Read-BaseUrl {
    $value = [Environment]::GetEnvironmentVariable('VPROD_BASE_URL')
    if ($null -eq $value) {
        $value = ''
    }
    $value = $value.Trim()
    if ($value -eq '') {
        $value = $script:DefaultBaseUrl
    }
    $script:BaseUrl = $value.TrimEnd('/')
}

function Read-Setting {
    $script:HostName = Get-Setting -ParamValue $script:ArgHost -ParamName '-ServerHost' -EnvName 'VPROD_HOST' -Prompt 'Server IPv4 address' -Default '' -Check { param($v) Test-HostValue $v }
    $script:Port = [int](Get-Setting -ParamValue $script:ArgPort -ParamName '-SshPort' -EnvName 'VPROD_SSH_PORT' -Prompt 'SSH port' -Default '22' -Check { param($v) Test-PortValue $v })
    $script:SrvUser = Get-Setting -ParamValue $script:ArgUser -ParamName '-User' -EnvName 'VPROD_USER' -Prompt 'User name on the server' -Default 'vprod' -Check { param($v) Test-UserValue $v }
    $script:AliasName = Get-Setting -ParamValue $script:ArgAlias -ParamName '-Alias' -EnvName 'VPROD_SSH_ALIAS' -Prompt 'Connection name' -Default 'vprod' -Check { param($v) Test-AliasFree $v }
    Set-Marker $script:AliasName
    $value = $script:ArgDesktop
    $source = '-Desktop'
    if ([string]::IsNullOrEmpty($value)) {
        $value = [Environment]::GetEnvironmentVariable('VPROD_DESKTOP')
        $source = 'VPROD_DESKTOP'
    }
    if ([string]::IsNullOrEmpty($value)) {
        $value = '1'
    }
    $value = $value.Trim()
    if ($value -ne '0' -and $value -ne '1') {
        Stop-Setup ('{0} must be 1 or 0.' -f $source) ('Fix {0} and run the command again.' -f $source)
    }
    $script:DesktopValue = $value
    Write-Host ''
    Write-Host ('Server: {0}, port {1}. User: {2}. Connection name: {3}.' -f $script:HostName, $script:Port, $script:SrvUser, $script:AliasName)
}

# ---------------------------------------------------------------------------
# This computer
# ---------------------------------------------------------------------------

function Test-Client {
    if ($env:OS -ne 'Windows_NT') {
        Stop-Setup 'This script is for Windows.' ('On macOS or Linux, run setup.sh: curl -fsSL {0}/setup.sh | bash' -f $script:BaseUrl)
    }
    $missing = @()
    foreach ($name in @('ssh.exe', 'scp.exe', 'ssh-keygen.exe')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            $missing += $name
        }
    }
    if ($missing.Count -gt 0) {
        Stop-Setup ('These programs are missing: {0}.' -f ($missing -join ', ')) 'Turn on OpenSSH Client: Settings -> System -> Optional features -> Add a feature -> OpenSSH Client. Then open a new PowerShell window and run the command again.'
    }
}

function New-TempPath {
    param([string]$Name)
    $path = Join-Path $env:TEMP ('vprod-env-{0}-{1}' -f [guid]::NewGuid().ToString('N'), $Name)
    [void]$script:TempFiles.Add($path)
    return $path
}

# Runs a program quietly. Sets CapOut, CapErr and CapRc.
function Invoke-Quiet {
    param([string]$Exe, [string[]]$ArgList)
    $old = $ErrorActionPreference
    # In 5.1 with 'Stop', every stderr line of a redirected program becomes an exception.
    $ErrorActionPreference = 'Continue'
    try {
        $all = & $Exe @ArgList 2>&1
        $script:CapRc = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }
    $outs = New-Object System.Collections.ArrayList
    $errs = New-Object System.Collections.ArrayList
    foreach ($item in @($all)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            [void]$errs.Add($item.ToString())
        }
        else {
            [void]$outs.Add([string]$item)
        }
    }
    $script:CapOut = ($outs -join "`n")
    $script:CapErr = ($errs -join "`n")
}

# ---------------------------------------------------------------------------
# SSH config
# ---------------------------------------------------------------------------

function Set-Marker {
    param([string]$Name)
    $script:BeginMark = '# BEGIN vprod-env ' + $Name
    $script:EndMark = '# END vprod-env ' + $Name
}

function Read-SshConfig {
    if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) {
        return [IO.File]::ReadAllText($script:ConfigPath, [Text.Encoding]::UTF8)
    }
    return ''
}

function Get-ConfigLine {
    $text = Read-SshConfig
    if ($text -eq '') {
        return @()
    }
    return ($text -split "`n")
}

# False if the begin marker has no end marker.
function Test-ConfigMarker {
    $open = $false
    $bad = $false
    foreach ($raw in @(Get-ConfigLine)) {
        $line = $raw.TrimEnd("`r")
        if ($line -ceq $script:BeginMark) {
            if ($open) {
                $bad = $true
            }
            $open = $true
        }
        elseif ($line -ceq $script:EndMark) {
            $open = $false
        }
    }
    return (-not ($open -or $bad))
}

function Test-ConfigBlock {
    foreach ($raw in @(Get-ConfigLine)) {
        if ($raw.TrimEnd("`r") -ceq $script:BeginMark) {
            return $true
        }
    }
    return $false
}

# True if "Host <name>" is outside our block.
function Test-ForeignHost {
    param([string]$Name)
    $inBlock = $false
    foreach ($raw in @(Get-ConfigLine)) {
        $line = $raw.TrimEnd("`r")
        if ($line -ceq $script:BeginMark) {
            $inBlock = $true
            continue
        }
        if ($line -ceq $script:EndMark) {
            $inBlock = $false
            continue
        }
        if ($inBlock) {
            continue
        }
        $trimmed = $line.TrimStart(' ', "`t")
        if ($trimmed -match '^host(\s*=\s*|\s+)(.*)$') {
            foreach ($pattern in ($Matches[2] -split '\s+')) {
                if ($pattern.Trim('"') -ieq $Name) {
                    return $true
                }
            }
        }
    }
    return $false
}

# Puts our block at the top of the SSH config (the first value wins in SSH config) and
# removes the old block. Writes UTF-8 without a BOM: a BOM breaks OpenSSH.
function Save-ConfigBlock {
    if (-not (Test-Path -LiteralPath $script:SshDir)) {
        New-Item -ItemType Directory -Path $script:SshDir | Out-Null
    }
    $text = Read-SshConfig
    $nl = "`n"
    if ($text.Contains("`r`n")) {
        $nl = "`r`n"
    }
    $block = @(
        $script:BeginMark,
        ('Host ' + $script:AliasName),
        ('    HostName ' + $script:HostName),
        ('    User ' + $script:SrvUser),
        ('    Port ' + $script:Port),
        ('    IdentityFile ~/.ssh/' + $script:AliasName + '_ed25519'),
        '    IdentitiesOnly yes',
        '    ServerAliveInterval 30',
        '    ServerAliveCountMax 6',
        'Match all',
        $script:EndMark
    ) -join $nl
    $rest = New-Object System.Collections.ArrayList
    if ($text -ne '') {
        $skip = $false
        foreach ($raw in ($text -split "`n")) {
            $line = $raw.TrimEnd("`r")
            if (-not $skip -and $line -ceq $script:BeginMark) {
                $skip = $true
                continue
            }
            if ($skip) {
                if ($line -ceq $script:EndMark) {
                    $skip = $false
                }
                continue
            }
            [void]$rest.Add($raw)
        }
    }
    $restText = ($rest -join "`n")
    $newText = $block + $nl + $restText
    [IO.File]::WriteAllText($script:ConfigPath, $newText, (New-Object System.Text.UTF8Encoding $false))
}

function Read-AliasConfig {
    Invoke-Quiet 'ssh.exe' @('-G', $script:AliasName)
    if ($script:CapRc -ne 0) {
        Stop-Setup ('ssh -G {0} does not work.' -f $script:AliasName) ('Check {0} and run the command again.' -f $script:ConfigPath)
    }
    $result = @{}
    foreach ($line in ($script:CapOut -split "`n")) {
        $parts = $line.Trim().Split(' ', 2)
        if ($parts.Count -eq 2 -and -not $result.ContainsKey($parts[0])) {
            $result[$parts[0]] = $parts[1]
        }
    }
    return $result
}

function Assert-ConfigBlock {
    $values = Read-AliasConfig
    $hint = 'Look for an Include or Match line before the vprod-env block, fix it, and run the command again.'
    $wantId = '~/.ssh/' + $script:AliasName + '_ed25519'
    if (-not $values.ContainsKey('hostname') -or $values['hostname'] -ine $script:HostName) {
        Stop-Setup ('In {0}, the connection {1} does not go to {2}.' -f $script:ConfigPath, $script:AliasName, $script:HostName) $hint
    }
    if (-not $values.ContainsKey('user') -or $values['user'] -cne $script:SrvUser) {
        Stop-Setup ('In {0}, the connection {1} does not use the user {2}.' -f $script:ConfigPath, $script:AliasName, $script:SrvUser) $hint
    }
    if (-not $values.ContainsKey('port') -or $values['port'] -ne [string]$script:Port) {
        Stop-Setup ('In {0}, the connection {1} does not use the port {2}.' -f $script:ConfigPath, $script:AliasName, $script:Port) $hint
    }
    $gotId = ''
    if ($values.ContainsKey('identityfile')) {
        $gotId = $values['identityfile']
    }
    $fullId = $script:KeyPath.Replace('\', '/')
    if ($gotId -ne $wantId -and $gotId.Replace('\', '/') -ine $fullId) {
        Stop-Setup ('In {0}, the first key of the connection {1} is "{2}", not {3}.' -f $script:ConfigPath, $script:AliasName, $gotId, $wantId) $hint
    }
}

# ---------------------------------------------------------------------------
# Key and server scripts
# ---------------------------------------------------------------------------

function Initialize-Key {
    $script:KeyPath = Join-Path $script:SshDir ($script:AliasName + '_ed25519')
    $pub = $script:KeyPath + '.pub'
    if (-not (Test-Path -LiteralPath $script:SshDir)) {
        New-Item -ItemType Directory -Path $script:SshDir | Out-Null
    }
    if ((Test-Path -LiteralPath $script:KeyPath) -and -not (Test-Path -LiteralPath $pub)) {
        Stop-Setup ('The key file {0} exists, but {1} is missing.' -f $script:KeyPath, $pub) 'Move the key file to another folder or choose another connection name, then run the command again.'
    }
    if (-not (Test-Path -LiteralPath $script:KeyPath)) {
        Write-Host ('Creating the key {0}.' -f $script:KeyPath)
        # One argument string: an empty '' in an argument array is dropped by 5.1,
        # and then ssh-keygen asks for a passphrase.
        $argLine = '-q -t ed25519 -N "" -C vprod-env-{0} -f "{1}"' -f $script:AliasName, $script:KeyPath
        $proc = Start-Process -FilePath 'ssh-keygen.exe' -ArgumentList $argLine -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Stop-Setup ('ssh-keygen could not create the key {0} (code {1}).' -f $script:KeyPath, $proc.ExitCode) 'Read the message above and run the command again.'
        }
    }
    else {
        Write-Host ('Using the key {0}.' -f $script:KeyPath)
    }
    $line = ([IO.File]::ReadAllText($pub) -split "`n")[0].Trim()
    if (-not $line.StartsWith('ssh-ed25519 ')) {
        Stop-Setup ('The key {0} is not an ed25519 key.' -f $pub) 'Move the key files to another folder and run the command again. The setup will make a new key.'
    }
    $script:KeyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($line))
}

# Downloads a server script, saves its bytes as they are, and checks it.
function Get-ServerScript {
    param([string]$Name)
    $dest = New-TempPath $Name
    $url = $script:BaseUrl + '/' + $Name
    $done = $false
    $lastError = ''
    for ($try = 1; $try -le 3 -and -not $done; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
            $done = $true
        }
        catch {
            $lastError = $_.Exception.Message
            if ($try -lt 3) {
                Start-Sleep -Seconds 2
            }
        }
    }
    if (-not $done) {
        Stop-Setup ('Cannot download {0}: {1}' -f $url, $lastError) 'Check your internet connection and the link, then run the command again.'
    }
    $bytes = [IO.File]::ReadAllBytes($dest)
    if ($bytes.Length -eq 0) {
        Stop-Setup ('The downloaded file {0} is empty.' -f $Name) 'Run the command again.'
    }
    if ([Array]::IndexOf($bytes, [byte]13) -ge 0) {
        Stop-Setup ('The downloaded file {0} has Windows line endings. It would fail on the server.' -f $Name) 'Download it from the original link, without changes, and run the command again.'
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`n"
    if ($lines[0] -cne '#!/usr/bin/env bash' -and $lines[0] -cne '#!/bin/bash') {
        Stop-Setup ('The downloaded file {0} is not a bash script.' -f $Name) 'Check the link in VPROD_BASE_URL and run the command again.'
    }
    $marker = 'VPROD_ENV_VERSION=' + $script:Version
    if (-not ($lines -ccontains $marker)) {
        Stop-Setup ('The downloaded file {0} is not version {1}.' -f $Name, $script:Version) 'Use the same link for setup.ps1 and VPROD_BASE_URL, then run the command again.'
    }
    Write-Host ('Downloaded {0}.' -f $Name)
    return $dest
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------

function Get-LoginName {
    if ($script:Login -eq 'root') {
        return 'root'
    }
    return $script:SrvUser
}

function Get-SshTarget {
    if ($script:UseAlias) {
        return @($script:AliasName)
    }
    return @('-o', 'IdentitiesOnly=yes', '-i', $script:KeyPath, '-p', [string]$script:Port, ('{0}@{1}' -f (Get-LoginName), $script:HostName))
}

function Get-ServerCommand {
    param([string]$Rest)
    return ('{0}bash {1} {2}' -f $script:Sudo, $script:ServerScript, $Rest)
}

# Runs a command on the server and shows its output. Sets LastRc.
# The remote command is one argument without quotes inside.
function Invoke-Remote {
    param([string]$Command)
    $sshArgs = @('-n') + $script:SshCommon + @(Get-SshTarget) + @($Command)
    & ssh.exe @sshArgs
    $script:LastRc = $LASTEXITCODE
}

# Runs a command on the server quietly. Sets CapOut, CapErr and CapRc.
function Invoke-RemoteQuiet {
    param([string]$Command)
    Invoke-Quiet 'ssh.exe' (@('-n') + $script:SshCommon + @(Get-SshTarget) + @($Command))
}

# Runs a shell script on the server as one base64 token.
function Invoke-RemoteScript {
    param([string]$Text)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text + "`n"))
    Invoke-Remote ('echo {0} | base64 -d | sh' -f $b64)
}

function Copy-ToServer {
    param([string]$LocalPath, [string]$RemotePath)
    $scpArgs = @('-q') + $script:SshCommon
    if ($script:UseAlias) {
        $scpArgs += @($LocalPath, ('{0}:{1}' -f $script:AliasName, $RemotePath))
    }
    else {
        $scpArgs += @('-o', 'IdentitiesOnly=yes', '-i', $script:KeyPath, '-P', [string]$script:Port, $LocalPath, ('{0}@{1}:{2}' -f (Get-LoginName), $script:HostName, $RemotePath))
    }
    & scp.exe @scpArgs
    $script:LastRc = $LASTEXITCODE
}

function Get-FirstErrorLine {
    foreach ($line in ($script:CapErr -split "`n")) {
        if ($line.Trim() -ne '' -and -not $line.StartsWith('Warning: Permanently added')) {
            return $line.Trim()
        }
    }
    return ''
}

function Test-AuthRefused {
    return $script:CapErr.Contains('Permission denied')
}

function Get-AuthMethod {
    $index = $script:CapErr.IndexOf('Permission denied (')
    if ($index -lt 0) {
        return ''
    }
    $rest = $script:CapErr.Substring($index + 'Permission denied ('.Length)
    $end = $rest.IndexOf(')')
    if ($end -lt 0) {
        return ''
    }
    return $rest.Substring(0, $end)
}

function Remove-OldHostKey {
    $entry = $script:HostName
    if ($script:Port -ne 22) {
        $entry = '[{0}]:{1}' -f $script:HostName, $script:Port
    }
    Write-Host ''
    Write-Host ('The key of the server {0} is different from the last time.' -f $script:HostName)
    Write-Host 'This is normal after the server was reinstalled. If you did not reinstall it, stop here and ask your provider.'
    $answer = Read-Answer 'Remove the old server key and continue? [y/N]' ''
    if (-not (Test-Yes $answer)) {
        Stop-Setup 'The old server key was not removed.' 'Run the command again when you are sure the server was reinstalled.'
    }
    & ssh-keygen.exe -R $entry
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup ('ssh-keygen -R {0} did not work.' -f $entry) ('Remove the lines for {0} from {1} and run the command again.' -f $entry, (Join-Path $script:SshDir 'known_hosts'))
    }
}

# A login attempt without questions (BatchMode). Handles a changed server key.
function Invoke-Probe {
    param([string[]]$ArgList)
    while ($true) {
        Invoke-Quiet 'ssh.exe' (@('-n') + $script:SshProbe + $script:SshCommon + $ArgList)
        if ($script:CapRc -ne 0 -and $script:CapErr.Contains('REMOTE HOST IDENTIFICATION HAS CHANGED')) {
            Remove-OldHostKey
            continue
        }
        return
    }
}

function Get-KeyArg {
    return @('-o', 'IdentitiesOnly=yes', '-i', $script:KeyPath, '-p', [string]$script:Port)
}

function Stop-OnConnectionError {
    Stop-Setup ('Cannot connect to {0}, port {1}: {2}' -f $script:HostName, $script:Port, (Get-FirstErrorLine)) 'Check the address and the port. Make sure the server is on, then run the command again.'
}

# Decides how to log in (step 6 of the requirements).
function Select-Login {
    Invoke-Probe (@(Get-KeyArg) + @(('{0}@{1}' -f $script:SrvUser, $script:HostName), 'sudo -n true'))
    if ($script:CapRc -eq 0) {
        $script:Login = 'user'
        $script:Rerun = $true
        Write-Host ('Logged in as {0} with the key. The server was set up before.' -f $script:SrvUser)
        return
    }
    if ($script:CapRc -eq 255 -and -not (Test-AuthRefused)) {
        Stop-OnConnectionError
    }
    Invoke-Probe (@(Get-KeyArg) + @(('root@{0}' -f $script:HostName), 'true'))
    if ($script:CapRc -eq 0) {
        $script:Login = 'root'
        Write-Host 'Logged in as root with the key. The last setup did not finish. It goes on now.'
        return
    }
    if ($script:CapRc -eq 255 -and -not (Test-AuthRefused)) {
        Stop-OnConnectionError
    }
    Invoke-Probe ($script:PasswordOpts + @('-p', [string]$script:Port, ('root@{0}' -f $script:HostName), 'true'))
    if ($script:CapRc -eq 0) {
        $script:NeedPassword = $true
        return
    }
    if (-not (Test-AuthRefused)) {
        Stop-OnConnectionError
    }
    $methods = ',' + (Get-AuthMethod) + ','
    if ($methods.Contains(',password,') -or $methods.Contains(',keyboard-interactive,')) {
        $script:NeedPassword = $true
        return
    }
    Stop-Setup 'This server is already set up with another key, and it does not accept passwords.' 'To get access back, use the console in the control panel of your provider.'
}

# The first root login with the password; adds our key for root.
function Invoke-Preflight {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:PreflightPath))
    Show-KeyWarning 'Type the root password. Characters are not shown while you type. This is normal.'
    # Start-Process keeps the console as it is, so the password prompt and the
    # memory question work. The remote command has no quotes inside.
    $argList = @('-t') + $script:SshCommon + $script:PasswordOpts + @('-p', [string]$script:Port, ('root@{0}' -f $script:HostName))
    $argLine = ($argList -join ' ') + (' "echo {0} | base64 -d | bash -s -- {1}"' -f $b64, $script:KeyB64)
    $proc = Start-Process -FilePath 'ssh.exe' -ArgumentList $argLine -NoNewWindow -Wait -PassThru
    $rc = $proc.ExitCode
    if ($rc -eq 0) {
        $script:Login = 'root'
        return
    }
    if ($rc -eq 10) {
        Write-Host ''
        Write-Host 'No changes were made on the server.'
        Exit-Setup 1
    }
    if ($rc -eq 11) {
        Exit-Setup 1
    }
    Stop-Setup ('The first login as root did not work (code {0}).' -f $rc) 'Check the root password in the email or the control panel of your provider.'
}

# Puts server.sh to /var/lib/vprod-env/server.sh (root, 0700).
function Install-ServerScript {
    if ($script:Login -eq 'root' -and -not $script:UseAlias) {
        Invoke-Remote ('install -d -m 0700 {0}' -f $script:ServerDir)
        if ($script:LastRc -ne 0) {
            Stop-Setup ('Cannot create {0} on the server.' -f $script:ServerDir) 'Read the message above and run the command again.'
        }
        # scp keeps the mode of the local file, and from Windows there is no x bit.
        Copy-ToServer $script:ServerPath $script:ServerScript
        if ($script:LastRc -ne 0) {
            Stop-Setup 'Cannot copy server.sh to the server.' 'Read the message above and run the command again.'
        }
        Invoke-Remote ('chmod 0700 {0}' -f $script:ServerScript)
        if ($script:LastRc -ne 0) {
            Stop-Setup ('Cannot set the permissions of {0}.' -f $script:ServerScript) 'Read the message above and run the command again.'
        }
    }
    else {
        Invoke-RemoteQuiet 'mktemp /tmp/vprod-env.XXXXXX'
        $tmp = $script:CapOut.Trim()
        if ($script:CapRc -ne 0 -or $tmp -cnotmatch '^/tmp/vprod-env\.[A-Za-z0-9]+$') {
            Stop-Setup ('Cannot create a temporary file on the server: {0}' -f (Get-FirstErrorLine)) 'Run the command again.'
        }
        Copy-ToServer $script:ServerPath $tmp
        if ($script:LastRc -ne 0) {
            Stop-Setup 'Cannot copy server.sh to the server.' 'Read the message above and run the command again.'
        }
        $text = @(
            ("trap 'rm -f {0}' EXIT" -f $tmp),
            'set -e',
            ('sudo -n install -d -m 0700 {0}' -f $script:ServerDir),
            ('sudo -n install -m 0700 -o root -g root {0} {1}' -f $tmp, $script:ServerScript)
        ) -join "`n"
        Invoke-RemoteScript $text
        if ($script:LastRc -ne 0) {
            Stop-Setup 'Cannot install server.sh on the server.' 'Read the message above and run the command again.'
        }
    }
    Write-Host 'Copied server.sh to the server.'
}

function Read-ServerInfo {
    $script:SrvVersion = ''
    $script:SrvDesktop = ''
    $script:SrvPrepared = '0'
    $script:SrvHardened = '0'
    foreach ($line in ($script:CapOut -split "`n")) {
        $line = $line.Trim()
        if ($line.StartsWith('version=')) { $script:SrvVersion = $line.Substring(8) }
        elseif ($line.StartsWith('desktop=')) { $script:SrvDesktop = $line.Substring(8) }
        elseif ($line.StartsWith('prepared=')) { $script:SrvPrepared = $line.Substring(9) }
        elseif ($line.StartsWith('hardened=')) { $script:SrvHardened = $line.Substring(9) }
    }
}

function Get-ServerInfo {
    Invoke-RemoteQuiet (Get-ServerCommand 'info')
    if ($script:CapRc -ne 0) {
        if ($script:CapOut) {
            Write-Host $script:CapOut
        }
        Stop-Setup ('Cannot read the state of the server (code {0}): {1}' -f $script:CapRc, (Get-FirstErrorLine)) 'Read the message above and run the command again.'
    }
    Read-ServerInfo
}

# Starts a phase in the background on the server; tries again if the connection breaks.
function Start-Phase {
    param([string]$Phase)
    # The SSH port is the last field of SSH_CONNECTION. It must be read before sudo,
    # because sudo and systemd-run remove this variable.
    $launcher = 'p=${SSH_CONNECTION##* }' + "`n" +
    ('exec {0}bash {1} start {2} {3} {4} "$p" {5}' -f $script:Sudo, $script:ServerScript, $Phase, $script:SrvUser, $script:KeyB64, $script:DesktopValue)
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        Invoke-RemoteScript $launcher
        if ($script:LastRc -eq 0) {
            return
        }
        if ($script:LastRc -ne 255) {
            Stop-Setup ('Cannot start the {0} step on the server (code {1}).' -f $Phase, $script:LastRc) 'Read the message above and run the command again.'
        }
        if ((Get-Date) -ge $deadline) {
            Stop-Setup 'There is no connection to the server for 10 minutes.' 'Check your internet connection and run the same command again.'
        }
        Write-Colored 'No connection to the server. Trying again in 10 seconds...' Yellow
        Start-Sleep -Seconds 10
    }
}

# Prints the phase log until the phase ends; reconnects if SSH breaks.
function Watch-Phase {
    param([string]$Phase)
    $count = 0
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        $script:FollowCount = $count
        $sshArgs = @('-n') + $script:SshCommon + @(Get-SshTarget) + @(Get-ServerCommand ('follow {0} {1}' -f $Phase, $count))
        & ssh.exe @sshArgs | ForEach-Object {
            Write-Host $_
            $script:FollowCount++
        }
        $rc = $LASTEXITCODE
        if ($rc -ne 255) {
            $script:PhaseRc = $rc
            return
        }
        if ($script:FollowCount -gt $count) {
            $deadline = (Get-Date).AddMinutes(10)
        }
        $count = $script:FollowCount
        if ((Get-Date) -ge $deadline) {
            Stop-Setup 'There is no connection to the server for 10 minutes.' 'Check your internet connection. Then run the same command again. The setup on the server goes on without this window.'
        }
        Write-Colored 'The connection to the server is lost. Trying again in 10 seconds...' Yellow
        Start-Sleep -Seconds 10
    }
}

function Invoke-Phase {
    param([string]$Phase)
    Start-Phase $Phase
    Watch-Phase $Phase
    if ($script:PhaseRc -ne 0) {
        Stop-Setup ('The {0} step on the server failed.' -f $Phase) ('Read the error above. The full log is on the server: /var/log/vprod-env/{0}.log' -f $Phase)
    }
}

function Assert-UserLogin {
    Invoke-Probe (@(Get-KeyArg) + @(('{0}@{1}' -f $script:SrvUser, $script:HostName), 'sudo -n true'))
    if ($script:CapRc -ne 0) {
        if ($script:CapErr) {
            Write-Host $script:CapErr
        }
        Stop-Setup ('Cannot log in as {0} with the key, or sudo does not work.' -f $script:SrvUser) 'Root login and passwords are still on, so you do not lose access to the server.'
    }
    $script:Login = 'user'
    $script:Sudo = 'sudo -n '
    Write-Host ('The login as {0} with the key works, and sudo works.' -f $script:SrvUser)
}

function Assert-Hardened {
    Invoke-Probe (@(Get-KeyArg) + @(('{0}@{1}' -f $script:SrvUser, $script:HostName), 'true'))
    if ($script:CapRc -ne 0) {
        Stop-Setup ('After the security step, the login as {0} does not work: {1}' -f $script:SrvUser, (Get-FirstErrorLine)) 'Open the console in the control panel of your provider and check the SSH server.'
    }
    Invoke-Probe (@(Get-KeyArg) + @(('root@{0}' -f $script:HostName), 'true'))
    if ($script:CapRc -eq 0) {
        Stop-Setup 'The server still lets root log in.' 'Run the same command again.'
    }
    if (-not (Test-AuthRefused)) {
        Stop-Setup ('Cannot check the root login: {0}' -f (Get-FirstErrorLine)) 'Check your internet connection and run the same command again.'
    }
    Invoke-Probe ($script:PasswordOpts + @('-p', [string]$script:Port, ('root@{0}' -f $script:HostName), 'true'))
    $methods = Get-AuthMethod
    if ($script:CapRc -eq 0 -or $methods -ne 'publickey') {
        if (-not $methods) {
            $methods = 'unknown'
        }
        Stop-Setup ('The server still accepts passwords (it offers: {0}).' -f $methods) 'Run the same command again.'
    }
    Write-Host 'Checked from this computer: the key login works, root login and passwords are off.'
}

# ---------------------------------------------------------------------------
# VS Code and the desktop
# ---------------------------------------------------------------------------

function Find-VsCode {
    $found = Get-Command 'code' -ErrorAction SilentlyContinue
    if ($found) {
        return $found.Source
    }
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return ''
}

function Install-VsCodeExtension {
    $code = Find-VsCode
    if (-not $code) {
        Write-Host 'VS Code is not found on this computer.'
        Write-Host 'Install VS Code from https://code.visualstudio.com, then the extension "Remote - SSH" (ms-vscode-remote.remote-ssh).'
        return
    }
    & $code --install-extension ms-vscode-remote.remote-ssh
    if ($LASTEXITCODE -eq 0) {
        $script:VsCodeOk = $true
    }
    else {
        Write-Host 'Could not install the extension "Remote - SSH". In VS Code, open Extensions, find "Remote - SSH" and install it.'
    }
}

function Test-PortFree {
    param([int]$Number)
    $listener = $null
    try {
        $listener = New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), $Number
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $listener) {
            try {
                $listener.Stop()
            }
            catch {
                $null = $_
            }
        }
    }
}

function Stop-Tunnel {
    if ($null -ne $script:TunnelProc) {
        try {
            if (-not $script:TunnelProc.HasExited) {
                $script:TunnelProc.Kill()
            }
        }
        catch {
            $null = $_
        }
        $script:TunnelProc = $null
    }
}

# SSH tunnel to noVNC on the server, then the browser.
function Open-Desktop {
    $script:ErrorHint = 'check'
    $port = 6080
    $tried = $false
    $lastRc = ''
    $started = $false
    for ($port = 6080; $port -le 6099; $port++) {
        if (-not (Test-PortFree $port)) {
            continue
        }
        $tried = $true
        # ssh -f does not work in OpenSSH for Windows. Only the alias, no paths.
        $argLine = (@('-N', '-o', 'ExitOnForwardFailure=yes') + $script:SshCommon + @('-L', ('{0}:127.0.0.1:6080' -f $port), $script:AliasName)) -join ' '
        $proc = Start-Process -FilePath 'ssh.exe' -ArgumentList $argLine -PassThru -WindowStyle Hidden
        $null = $proc.Handle
        Start-Sleep -Seconds 2
        if (-not $proc.HasExited) {
            $script:TunnelProc = $proc
            $started = $true
            break
        }
        $lastRc = [string]$proc.ExitCode
    }
    if (-not $started) {
        if (-not $tried) {
            Stop-Setup 'All ports from 6080 to 6099 on this computer are busy.' 'Close some programs and run the command again.'
        }
        Stop-Setup ('Cannot open the tunnel to the server desktop (ssh exit code {0}).' -f $lastRc) 'Check your internet connection and run the command again.'
    }

    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $response = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/vnc.html' -f $port) -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                $ok = $true
                break
            }
        }
        catch {
            $null = $_
        }
        if ($script:TunnelProc.HasExited) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $ok) {
        Stop-Tunnel
        Stop-Setup 'The server desktop does not answer.' 'Wait one minute and run the command again.'
    }

    $url = 'http://127.0.0.1:{0}/vnc.html?autoconnect=1&resize=remote&reconnect=1' -f $port
    try {
        Start-Process $url
    }
    catch {
        $null = $_
    }
    Write-Host 'The server desktop opens in your browser. If it does not open, copy this address into the browser:'
    Write-Host ('  ' + $url)
    Show-KeyWarning 'Do all login steps inside the server window. Do not open the login link in your own browser.'
    Write-Host 'In the server window, a terminal with Claude Code opens. Follow its steps. The login page opens in Firefox on the server.'
    Write-Host 'To paste text into the server window: click the small arrow on the left side of the noVNC screen, then the clipboard button. Paste your text into the box. Then paste it in the server window.'
    Write-Host ''
    Write-Host 'Press Enter when you are done.' -NoNewline
    [void][Console]::ReadLine()
    Stop-Tunnel
    Write-Host 'The connection to the server desktop is closed.'
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Show-Summary {
    Write-Host ''
    Write-Colored 'The setup is complete.' Green
    Write-Host ('  Server:          {0}, SSH port {1}' -f $script:HostName, $script:Port)
    Write-Host ('  User:            {0}, login only with the key ~/.ssh/{1}_ed25519' -f $script:SrvUser, $script:AliasName)
    Write-Host ('  Connection name: {0} (try it: ssh {0})' -f $script:AliasName)
    Write-Host '  Security:        root login and passwords are off, only SSH is open, fail2ban and security updates are on'
    if (-not $script:VsCodeOk) {
        Write-Host '  VS Code:         install VS Code and the extension "Remote - SSH" first'
    }
    if ($script:SrvDesktop -ne '1') {
        Write-Host '  Desktop:         off. To log in to Claude, run claude in the VS Code terminal.'
    }
    Write-Host ''
    Write-Colored "What's next" Cyan
    Write-Host ('  1. In VS Code, open Remote Explorer, find "{0}" and click Connect. If VS Code asks for the platform, choose Linux.' -f $script:AliasName)
    Write-Host ('  2. Open the folder /home/{0}/projects.' -f $script:SrvUser)
    Write-Host '  3. Open the terminal in VS Code (Terminal -> New Terminal) and run claude.'
    Write-Host ('  Optional: to use Claude in the editor too, find Claude Code in Extensions and click "Install in SSH: {0}".' -f $script:AliasName)
    Write-Host ''
    Write-Colored 'Other commands' Cyan
    Write-Host '  Open the server desktop again:'
    Write-Host ('    ' + (Get-ActionCommand 'desktop'))
    Write-Host '  Log in to Claude again:'
    Write-Host ('    ' + (Get-ActionCommand 'login'))
    Write-Host '  Check the server:'
    Write-Host ('    ' + (Get-ActionCommand 'check'))
}

function Invoke-Setup {
    Write-Step 1 'Checking this computer'
    Test-Client
    Write-Host 'This computer has everything the setup needs.'
    Write-StepDone
    Write-Host ''
    Read-Setting

    Write-Step 2 'Creating the SSH key'
    Initialize-Key
    Write-StepDone

    Write-Step 3 'Downloading the server scripts'
    $script:PreflightPath = Get-ServerScript 'preflight.sh'
    $script:ServerPath = Get-ServerScript 'server.sh'
    Write-StepDone

    $script:ErrorHint = 'rerun'
    Write-Step 4 'Connecting to the server'
    Select-Login
    if ($script:NeedPassword) {
        Invoke-Preflight
    }
    if ($script:Login -eq 'user') {
        $script:Sudo = 'sudo -n '
    }
    Install-ServerScript
    Get-ServerInfo
    Write-StepDone

    Write-Step 5 'Setting up the server'
    $already = $false
    if ($script:Rerun -and $script:SrvPrepared -eq '1' -and $script:SrvHardened -eq '1') {
        Invoke-Remote (Get-ServerCommand 'check')
        if ($script:LastRc -eq 0) {
            $already = $true
            Write-Host ''
            Write-Host 'Everything is already set up.'
        }
        elseif ($script:LastRc -eq 255) {
            Stop-Setup 'The connection to the server is lost.' 'Check your internet connection and run the same command again.'
        }
        else {
            Write-Host ''
            Write-Host 'Some checks failed. The setup fixes them now.'
        }
    }
    if (-not $already) {
        Invoke-Phase 'prepare'
        Write-StepDone

        Write-Step 6 ('Checking the login for {0}' -f $script:SrvUser)
        Assert-UserLogin
        Write-StepDone

        Write-Step 7 'Securing the server'
        Invoke-Phase 'harden'
        $script:ErrorHint = 'check'
        Assert-Hardened
        Write-StepDone
    }
    else {
        Write-StepDone
    }
    $script:ErrorHint = 'check'

    Write-Step 8 ('Saving the connection {0}' -f $script:AliasName)
    Save-ConfigBlock
    Assert-ConfigBlock
    Write-Host ('Saved the connection in {0}. Connect with: ssh {1}' -f $script:ConfigPath, $script:AliasName)
    Write-StepDone
    $script:UseAlias = $true
    $script:Login = 'user'
    $script:Sudo = 'sudo -n '

    Write-Step 9 'Setting up VS Code'
    Install-VsCodeExtension
    Write-StepDone

    Write-Step 10 'Opening the server desktop'
    Invoke-RemoteQuiet (Get-ServerCommand 'info')
    if ($script:CapRc -ne 0) {
        Stop-Setup ('Cannot connect to the server with "ssh {0}": {1}' -f $script:AliasName, (Get-FirstErrorLine)) 'Check your internet connection and run the command again.'
    }
    Read-ServerInfo
    if ($script:SrvDesktop -eq '1') {
        Open-Desktop
    }
    else {
        Write-Host 'The desktop is turned off on this server. Skipped.'
    }
    Write-StepDone

    Show-Summary
}

# Reads the server state; uploads server.sh again if its version differs.
function Update-ServerScript {
    while ($true) {
        Invoke-RemoteQuiet (Get-ServerCommand 'info')
        if ($script:CapRc -ne 0 -and $script:CapErr.Contains('REMOTE HOST IDENTIFICATION HAS CHANGED')) {
            Remove-OldHostKey
            continue
        }
        break
    }
    if ($script:CapRc -eq 255) {
        Stop-Setup ('Cannot connect to the server "{0}": {1}' -f $script:AliasName, (Get-FirstErrorLine)) 'Check your internet connection and that the server is on, then run the command again.'
    }
    Read-ServerInfo
    if ($script:CapRc -ne 0 -or $script:SrvVersion -ne $script:Version) {
        Write-Host ('Updating server.sh on the server to version {0}.' -f $script:Version)
        $script:ServerPath = Get-ServerScript 'server.sh'
        Install-ServerScript
        Get-ServerInfo
    }
}

function Invoke-RemoteAction {
    param([string]$Name)
    Test-Client
    $script:AliasName = Get-Setting -ParamValue $script:ArgAlias -ParamName '-Alias' -EnvName 'VPROD_SSH_ALIAS' -Prompt 'Connection name' -Default 'vprod' -Check { param($v) Test-AliasValue $v }
    Set-Marker $script:AliasName
    if (-not (Test-ConfigBlock)) {
        Write-Host 'Run setup first.'
        Write-Host ('  ' + (Get-ActionCommand 'setup'))
        Exit-Setup 1
    }
    $script:UseAlias = $true
    $script:Login = 'user'
    $script:Sudo = 'sudo -n '
    $values = Read-AliasConfig
    if ($values.ContainsKey('hostname')) {
        $script:HostName = $values['hostname']
    }
    if ($values.ContainsKey('port')) {
        $script:Port = [int]$values['port']
    }
    if ($values.ContainsKey('user')) {
        $script:SrvUser = $values['user']
    }
    if ($Name -ne 'check') {
        $script:ErrorHint = 'check'
    }
    Update-ServerScript

    if ($Name -eq 'check') {
        Invoke-Remote (Get-ServerCommand 'check')
        if ($script:LastRc -eq 255) {
            Write-Host ('Cannot connect to the server "{0}". Check your internet connection and run the command again.' -f $script:AliasName)
        }
        Exit-Setup $script:LastRc
    }
    if ($script:SrvDesktop -ne '1') {
        Write-Host 'The desktop is turned off on this server.'
        Exit-Setup 1
    }
    if ($Name -eq 'login') {
        Invoke-Remote (Get-ServerCommand 'login')
        if ($script:LastRc -ne 0) {
            Stop-Setup 'Cannot open the Claude login window on the server.' 'Read the message above.'
        }
    }
    Open-Desktop
}

function Invoke-Main {
    $script:UseColor = (-not [Console]::IsOutputRedirected) -and ($null -eq $env:NO_COLOR)
    try {
        $script:OldOutputEncoding = [Console]::OutputEncoding
        # ssh prints UTF-8 (for example, apt output from the server).
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    }
    catch {
        $script:OldOutputEncoding = $null
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $name = $script:ArgAction.Trim().ToLowerInvariant()
    if ($name -eq '') {
        $name = 'setup'
    }
    if (@('setup', 'desktop', 'login', 'check') -notcontains $name) {
        Stop-Setup ('Unknown action "{0}".' -f $script:ArgAction) 'Use one of: setup, desktop, login, check.'
    }
    $script:ActionName = $name

    $profileDir = $env:USERPROFILE
    if (-not $profileDir) {
        $profileDir = [Environment]::GetFolderPath('UserProfile')
    }
    $script:SshDir = Join-Path $profileDir '.ssh'
    $script:ConfigPath = Join-Path $script:SshDir 'config'
    Read-BaseUrl
    Write-Colored ('vprod-env ' + $script:Version) White

    if ($script:ActionName -eq 'setup') {
        Invoke-Setup
    }
    else {
        Invoke-RemoteAction $script:ActionName
    }
}

try {
    Invoke-Main
}
catch {
    if ($_.Exception.Message -ne 'vprod-env-stop') {
        $script:ExitCode = 1
        Write-Host ''
        Write-Colored ('ERROR: Something unexpected went wrong: ' + $_.Exception.Message) Red
        Write-Host ('At: ' + $_.InvocationInfo.PositionMessage)
        if ($script:ErrorHint -eq 'rerun') {
            Show-KeyWarning 'Nothing is broken. Run the same command again to continue.'
        }
        elseif ($script:ErrorHint -eq 'check') {
            Write-Host ''
            Write-Host 'To check the server, run:'
            Write-Host ('  ' + (Get-ActionCommand 'check'))
        }
    }
}
finally {
    Stop-Tunnel
    foreach ($path in $script:TempFiles) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:OldOutputEncoding) {
        try {
            [Console]::OutputEncoding = $script:OldOutputEncoding
        }
        catch {
            $null = $_
        }
    }
}
exit $script:ExitCode
