<#
.SYNOPSIS
Install Windows shortcuts that run the DeepSeek Harness web UI without a terminal.

.DESCRIPTION
`dsh web` is a foreground server, so the PowerShell window that starts it owns
its console and closing that window kills it. This installs the two launcher
scripts next to a log under %LOCALAPPDATA%, renders a shortcut icon from the web
UI's favicon, and creates Desktop, Start Menu, and optional logon shortcuts that
start the server hidden and open it as a chromeless window.

Requires `dsh` on PATH or under the npm global prefix:
`npm i -g @deepseek-ai/dsh`.

.PARAMETER Port
Port the web server listens on. Defaults to 3080, the server's own default.

.PARAMETER InstallDir
Where the launcher scripts, icon, and log live. Defaults to %LOCALAPPDATA%\dsh.

.PARAMETER Autostart
What runs at logon: `window` starts the server and opens the window, `server`
starts the server only and leaves opening it to the Desktop shortcut, and `none`
installs no logon entry.

.PARAMETER Uninstall
Remove the shortcuts and installed scripts. The log and the harness home under
~/.dsh are left alone.

.EXAMPLE
pwsh -File scripts/windows/install-dsh-shortcuts.ps1

.EXAMPLE
pwsh -File scripts/windows/install-dsh-shortcuts.ps1 -Port 8899 -Autostart server

.EXAMPLE
pwsh -File scripts/windows/install-dsh-shortcuts.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 65535)]
  [int]$Port = 3080,

  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'dsh'),

  [ValidateSet('none', 'server', 'window')]
  [string]$Autostart = 'window',

  [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ShortcutName = 'DeepSeek Harness.lnk'

# Windows PowerShell raises a terminating NativeCommandError for any stderr line
# a native command writes while $ErrorActionPreference is Stop, and browsers
# chatter on stderr about components they did not find. Relax the policy around
# native calls and discard their stderr; the exit code still decides.
function Invoke-NativeQuiet {
  param([string]$FilePath, [string[]]$ArgumentList)

  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $FilePath @ArgumentList 2>$null | Out-Null
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
}
$DesktopDir = [Environment]::GetFolderPath('Desktop')
$StartMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$StartupDir = [Environment]::GetFolderPath('Startup')

# The `dsh` launcher as a batch file, because the shortcuts run it through
# cmd.exe. npm installs `dsh`, `dsh.cmd`, and `dsh.ps1` side by side, and a bare
# `Get-Command dsh` in PowerShell answers with the PowerShell one, which cmd
# cannot execute. PATH is consulted first so a custom install location wins over
# the npm default. Returns an empty string when the package is not installed.
function Resolve-DshCommand {
  $onPath = Get-Command dsh.cmd -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  $npmDefault = Join-Path $env:APPDATA 'npm\dsh.cmd'
  if (Test-Path -LiteralPath $npmDefault) { return $npmDefault }
  # A dsh on PATH with no .cmd beside it: cmd resolves the bare name itself.
  if (Get-Command dsh -ErrorAction SilentlyContinue) { return 'dsh' }
  return ''
}

# First installed Chromium-family browser, from the App Paths keys installers
# register. Used to render the icon; the launcher repeats this lookup itself.
function Resolve-Browser {
  foreach ($exe in 'msedge.exe', 'chrome.exe') {
    foreach ($hive in 'HKLM:', 'HKCU:') {
      $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
      $item = Get-ItemProperty -LiteralPath $key -Name '(default)' -ErrorAction SilentlyContinue
      if ($item) {
        $value = $item.'(default)'
        if ($value -and (Test-Path -LiteralPath $value)) { return $value }
      }
    }
  }
  return ''
}

# The web UI's favicon as shipped on disk, so the icon can be built without a
# running server. The frontend package is installed per profile under the
# harness home, and again beneath the CLI's own dependencies.
function Resolve-FaviconSource {
  $roots = @()
  if ($env:DSH_HOME) { $roots += $env:DSH_HOME } else { $roots += (Join-Path $env:USERPROFILE '.dsh') }
  # npm is absent when dsh was resolved from PATH by some other install method.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $npmRoot = & npm root -g 2>$null
    if ($npmRoot) { $roots += ([string]$npmRoot).Trim() }
  } catch {
    Write-Verbose "npm not available for the global root lookup: $_"
  } finally {
    $ErrorActionPreference = $previous
  }

  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter 'favicon.svg' -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -like '*dsh-web-frontend*' } |
      Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return ''
}

# Render an SVG to a single-image .ico. Windows shortcuts need .ico, and the
# format has embedded PNG entries since Vista, so the rendered PNG goes in whole
# behind a six-byte directory and one sixteen-byte entry.
function New-IconFromSvg {
  param([string]$SvgPath, [string]$IcoPath, [string]$Browser)

  $work = Join-Path ([IO.Path]::GetTempPath()) ("dsh-icon-" + [Guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    Copy-Item -LiteralPath $SvgPath -Destination (Join-Path $work 'favicon.svg')
    # A wrapper pins the raster size: an SVG opened directly scales to the window.
    $html = '<style>html,body{margin:0;padding:0;background:transparent}' +
            'img{width:256px;height:256px;display:block}</style><img src="favicon.svg">'
    Set-Content -LiteralPath (Join-Path $work 'icon.html') -Value $html -Encoding UTF8

    $png = Join-Path $work 'icon.png'
    $url = 'file:///' + ((Join-Path $work 'icon.html') -replace '\\', '/')
    Invoke-NativeQuiet -FilePath $Browser -ArgumentList @(
      '--headless', '--disable-gpu', '--hide-scrollbars',
      '--default-background-color=00000000', '--force-device-scale-factor=1',
      '--window-size=256,256', "--screenshot=$png", $url
    ) | Out-Null
    if (-not (Test-Path -LiteralPath $png)) { return $false }

    $bytes = [IO.File]::ReadAllBytes($png)
    $stream = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($stream)
    try {
      $writer.Write([UInt16]0)              # reserved
      $writer.Write([UInt16]1)              # type: icon
      $writer.Write([UInt16]1)              # image count
      $writer.Write([Byte]0)                # width, 0 meaning 256
      $writer.Write([Byte]0)                # height, 0 meaning 256
      $writer.Write([Byte]0)                # palette size, 0 for direct colour
      $writer.Write([Byte]0)                # reserved
      $writer.Write([UInt16]1)              # colour planes
      $writer.Write([UInt16]32)             # bits per pixel
      $writer.Write([UInt32]$bytes.Length)  # image bytes
      $writer.Write([UInt32]22)             # offset past this header
      $writer.Write($bytes)
      $writer.Flush()
      [IO.File]::WriteAllBytes($IcoPath, $stream.ToArray())
    } finally {
      $writer.Dispose()
      $stream.Dispose()
    }
    return $true
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function New-LauncherShortcut {
  param([string]$Path, [string]$Script, [string]$Arguments, [string]$IconPath, [string]$Description)

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $shortcut.Arguments = """$Script"" $Arguments"
  $shortcut.WorkingDirectory = Split-Path -Parent $Script
  $shortcut.Description = $Description
  # Hidden: wscript itself has no UI, and the launcher opens the real window.
  $shortcut.WindowStyle = 7
  if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { $shortcut.IconLocation = "$IconPath,0" }
  $shortcut.Save()
}

if ($Uninstall) {
  foreach ($dir in $DesktopDir, $StartMenuDir, $StartupDir) {
    $lnk = Join-Path $dir $ShortcutName
    if (Test-Path -LiteralPath $lnk) {
      Remove-Item -LiteralPath $lnk -Force
      Write-Host "removed $lnk"
    }
  }
  foreach ($name in 'dsh-web.vbs', 'dsh-app.vbs', 'dsh.ico') {
    $file = Join-Path $InstallDir $name
    if (Test-Path -LiteralPath $file) {
      Remove-Item -LiteralPath $file -Force
      Write-Host "removed $file"
    }
  }
  Write-Host ''
  Write-Host "The log and your harness home were left in place."
  Write-Host "A running server is not stopped: close it from Task Manager, or reboot."
  return
}

$dshCommand = Resolve-DshCommand
if (-not $dshCommand) {
  throw "dsh was not found on PATH or under $env:APPDATA\npm. Install it with: npm i -g @deepseek-ai/dsh"
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
  New-Item -ItemType Directory -Path $InstallDir | Out-Null
}

$sourceDir = Split-Path -Parent $PSCommandPath
foreach ($name in 'dsh-web.vbs', 'dsh-app.vbs') {
  Copy-Item -LiteralPath (Join-Path $sourceDir $name) -Destination (Join-Path $InstallDir $name) -Force
}

$icon = Join-Path $InstallDir 'dsh.ico'
$browser = Resolve-Browser
$favicon = Resolve-FaviconSource
if (-not $browser) {
  Write-Warning "No Edge or Chrome found: shortcuts get the default script icon, and the UI opens as an ordinary browser tab."
} elseif (-not $favicon) {
  Write-Warning "No favicon.svg found under the harness home: shortcuts get the default script icon. Run the web UI once, then re-run this installer."
} elseif (-not (New-IconFromSvg -SvgPath $favicon -IcoPath $icon -Browser $browser)) {
  Write-Warning "Rendering the icon failed: shortcuts get the default script icon."
}

$appScript = Join-Path $InstallDir 'dsh-app.vbs'
$webScript = Join-Path $InstallDir 'dsh-web.vbs'
$common = "/port:$Port /dsh:""$dshCommand"""

New-LauncherShortcut -Path (Join-Path $DesktopDir $ShortcutName) -Script $appScript -Arguments $common `
  -IconPath $icon -Description 'DeepSeek Harness web UI'
New-LauncherShortcut -Path (Join-Path $StartMenuDir $ShortcutName) -Script $appScript -Arguments $common `
  -IconPath $icon -Description 'DeepSeek Harness web UI'

$startupShortcut = Join-Path $StartupDir $ShortcutName
if (Test-Path -LiteralPath $startupShortcut) { Remove-Item -LiteralPath $startupShortcut -Force }
switch ($Autostart) {
  'window' {
    New-LauncherShortcut -Path $startupShortcut -Script $appScript -Arguments $common `
      -IconPath $icon -Description 'Start the DeepSeek Harness web UI and open its window at logon'
  }
  'server' {
    New-LauncherShortcut -Path $startupShortcut -Script $webScript -Arguments $common `
      -IconPath $icon -Description 'Start the DeepSeek Harness web server at logon'
  }
}

Write-Host "installed to      $InstallDir"
Write-Host "dsh launcher      $dshCommand"
Write-Host "url               http://127.0.0.1:$Port/"
Write-Host "logon behaviour   $Autostart"
Write-Host "log               $(Join-Path $InstallDir 'web.log')"
Write-Host ''
Write-Host "Open it from the Desktop or Start Menu shortcut. A cold start takes"
Write-Host "20-40 seconds before the window appears; the launcher waits for the"
Write-Host "server rather than failing early."
