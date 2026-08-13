<#
.SYNOPSIS
One-command Windows setup: install the dsh CLI and the shortcuts that run its
web UI without a terminal.

.DESCRIPTION
Checks for a supported Node.js, installs `@deepseek-ai/dsh` globally when it is
missing, then hands off to install-dsh-shortcuts.ps1. Nothing here needs the
repository to be built or its dependencies installed — the CLI comes from npm —
so a fresh clone is enough:

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1

Re-running is safe: an installed CLI is left alone unless -Update is passed, and
the shortcuts are rewritten in place.

.PARAMETER Port
Port the web server listens on. Defaults to 3080.

.PARAMETER Autostart
What runs at logon: `window` starts the server and opens the window, `server`
starts the server only, `none` installs no logon entry.

.PARAMETER InstallDir
Where the launcher scripts, icon, and log live. Defaults to %LOCALAPPDATA%\dsh.

.PARAMETER Update
Reinstall the CLI even when it is already present, picking up a newer release.

.PARAMETER InstallNode
Install Node.js through winget when it is missing or too old, instead of
stopping with instructions.

.PARAMETER Uninstall
Remove the shortcuts and launcher scripts. The globally installed CLI, the log,
and the harness home under ~/.dsh are left alone.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Port 8899 -Autostart server

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 65535)]
  [int]$Port = 3080,

  [ValidateSet('none', 'server', 'window')]
  [string]$Autostart = 'window',

  [string]$InstallDir,

  [switch]$Update,

  [switch]$InstallNode,

  [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CliPackage = '@deepseek-ai/dsh'
# The CLI's own engines range: ^22.19.0 || >=24.0.0, so 23.x is excluded.
$MinimumNode22 = [version]'22.19.0'

# Windows PowerShell raises a terminating NativeCommandError for any stderr line
# a native command writes while $ErrorActionPreference is Stop, and npm reports
# ordinary warnings there. Run native commands with that policy relaxed; their
# exit code still decides. Output is left on the console so a slow global
# install shows progress.
function Invoke-Native {
  param([string]$FilePath, [string[]]$ArgumentList, [switch]$Quiet)

  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Quiet) {
      $output = & $FilePath @ArgumentList 2>$null
      return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Host $_ }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $null }
  } finally {
    $ErrorActionPreference = $previous
  }
}

# The installed Node.js version, or $null when node is not on PATH.
function Get-NodeVersion {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $null }
  $result = Invoke-Native -FilePath 'node' -ArgumentList @('-v') -Quiet
  if ($result.ExitCode -ne 0 -or -not $result.Output) { return $null }
  $text = ([string]$result.Output).Trim().TrimStart('v')
  try { return [version]$text } catch { return $null }
}

function Test-NodeSupported {
  param([version]$Version)
  if (-not $Version) { return $false }
  if ($Version.Major -eq 22) { return $Version -ge $MinimumNode22 }
  return $Version.Major -ge 24
}

$scriptDir = Split-Path -Parent $PSCommandPath
$shortcutInstaller = Join-Path $scriptDir 'install-dsh-shortcuts.ps1'
if (-not (Test-Path -LiteralPath $shortcutInstaller)) {
  throw "install-dsh-shortcuts.ps1 is missing from $scriptDir. Clone the repository rather than copying this file alone."
}

# Forwarded verbatim so this script owns no defaults of its own.
$forwarded = @{ Port = $Port; Autostart = $Autostart }
if ($InstallDir) { $forwarded['InstallDir'] = $InstallDir }

if ($Uninstall) {
  $uninstallArguments = @{ Uninstall = $true }
  if ($InstallDir) { $uninstallArguments['InstallDir'] = $InstallDir }
  & $shortcutInstaller @uninstallArguments
  Write-Host ''
  Write-Host "The CLI is still installed. Remove it with: npm uninstall -g $CliPackage"
  return
}

Write-Host '== Node.js =='
$nodeVersion = Get-NodeVersion
if (Test-NodeSupported -Version $nodeVersion) {
  Write-Host "found v$nodeVersion"
} else {
  $found = if ($nodeVersion) { "v$nodeVersion" } else { 'none' }
  if (-not $InstallNode) {
    throw "Node.js ^22.19.0 || >=24.0.0 is required, found $found. Install it from https://nodejs.org, or re-run with -InstallNode to let winget do it."
  }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "-InstallNode needs winget, which is not available. Install Node.js from https://nodejs.org instead."
  }
  Write-Host "found $found; installing the current LTS through winget"
  $winget = Invoke-Native -FilePath 'winget' -ArgumentList @(
    'install', '--id', 'OpenJS.NodeJS.LTS', '--exact',
    '--accept-source-agreements', '--accept-package-agreements'
  )
  if ($winget.ExitCode -ne 0) { throw "winget failed with exit code $($winget.ExitCode)." }
  Write-Host ''
  Write-Host 'Node.js was installed, but this session still has the old PATH.'
  Write-Host 'Open a new terminal and run this script again.'
  return
}

Write-Host ''
Write-Host '== dsh CLI =='
$installed = [bool](Get-Command dsh.cmd -ErrorAction SilentlyContinue)
if ($installed -and -not $Update) {
  Write-Host "already installed at $((Get-Command dsh.cmd).Source)"
  Write-Host "pass -Update to reinstall from npm"
} else {
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw 'npm was not found on PATH, although node was. Repair the Node.js installation.'
  }
  Write-Host "installing $CliPackage globally; this takes a minute"
  $npm = Invoke-Native -FilePath 'npm' -ArgumentList @('install', '--global', $CliPackage)
  if ($npm.ExitCode -ne 0) { throw "npm install failed with exit code $($npm.ExitCode)." }
}

Write-Host ''
Write-Host '== shortcuts =='
& $shortcutInstaller @forwarded

Write-Host ''
Write-Host 'Setup is complete. The API key is not part of this setup: open the UI'
Write-Host 'and enter it once, and it is kept in ~/.dsh/.credentials.yaml.'
