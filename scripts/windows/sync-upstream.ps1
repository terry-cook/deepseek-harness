<#
.SYNOPSIS
Rebase this fork's enhancement branch onto the latest upstream and verify that
the contracts the Windows launchers depend on still hold.

.DESCRIPTION
The Windows launchers hard-code facts about the published CLI: its npm package
name, its bin entry (which `dsh-web.vbs` matches against a running process's
command line), its `--port` flag, its default port, and its supported Node
range. A textual rebase can succeed while any of those has silently moved, so
this script rebases and then asserts each one against the upstream tree.

It never pushes and never touches the running installation. Upgrading the
installed CLI is `setup.ps1 -Update`, a separate and deliberate step.

.PARAMETER Branch
The enhancement branch to rebase. Defaults to the current branch.

.PARAMETER Upstream
The upstream ref to rebase onto. Defaults to origin/master.

.PARAMETER CheckOnly
Fetch, report what is new, run the contract checks against the upstream tree,
and stop without rebasing.

.PARAMETER NoFetch
Skip the fetch and use the already-fetched upstream ref.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync-upstream.ps1

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync-upstream.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
  [string]$Branch,

  [string]$Upstream = 'origin/master',

  [switch]$CheckOnly,

  [switch]$NoFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if (-not $RepoRoot) { throw 'Not inside a Git repository.' }
Set-Location $RepoRoot

$script:Failures = @()

function Write-Section {
  param([string]$Text)
  Write-Host ''
  Write-Host "== $Text =="
}

# Git writes progress to stderr, which `$ErrorActionPreference = 'Stop'` would
# turn into a terminating error, so every native call goes through here.
function Invoke-Git {
  param([string[]]$Arguments, [switch]$AllowFailure)

  # Git writes progress and diagnostics to stderr. Merging that stream with
  # 2>&1 turns each line into an ErrorRecord, which PowerShell would render as
  # a NativeCommandError even for an expected failure, so flatten the records
  # to plain strings before they reach the host.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    $output = & git @Arguments 2>&1 |
      ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } } |
      Out-String
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  if ($code -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code ${code}:`n$output"
  }
  [pscustomobject]@{ Output = $output.TrimEnd(); ExitCode = $code }
}

# One file's contents at a ref, or $null when the path does not exist there.
function Get-RefFile {
  param([string]$Ref, [string]$Path)

  $result = Invoke-Git -Arguments @('show', "${Ref}:${Path}") -AllowFailure
  if ($result.ExitCode -ne 0) { return $null }
  $result.Output
}

# A path vanishing is drift like any other: record it and keep checking, so one
# relocated file cannot hide the state of every remaining contract.
function Get-RefJson {
  param([string]$Ref, [string]$Path)

  $raw = Get-RefFile -Ref $Ref -Path $Path
  if (-not $raw) {
    Write-Host ("  DRIFT {0} does not exist at {1}" -f $Path, $Ref) -ForegroundColor Red
    Write-Host '        breaks   : every contract this file owns; the upstream layout moved'
    $script:Failures += $Path
    return $null
  }
  try {
    return $raw | ConvertFrom-Json
  } catch {
    Write-Host ("  DRIFT {0} at {1} is not valid JSON" -f $Path, $Ref) -ForegroundColor Red
    $script:Failures += $Path
    return $null
  }
}

# Each contract pins one upstream fact a launcher hard-codes. `UsedBy` names
# what breaks when it moves, so a drift report is actionable on its own.
function Test-Contract {
  param([string]$Name, [string]$Expected, [string]$Actual, [string]$UsedBy)

  if ($Actual -eq $Expected) {
    Write-Host ("  OK    {0}: {1}" -f $Name, $Actual)
    return
  }
  $shown = if ($Actual) { $Actual } else { '<not found>' }
  Write-Host ("  DRIFT {0}" -f $Name) -ForegroundColor Red
  Write-Host ("        expected : {0}" -f $Expected)
  Write-Host ("        upstream : {0}" -f $shown)
  Write-Host ("        breaks   : {0}" -f $UsedBy)
  $script:Failures += $Name
}

function Test-ContractContains {
  param([string]$Name, [string]$Haystack, [string]$Needle, [string]$UsedBy)

  if ($Haystack -and $Haystack.Contains($Needle)) {
    Write-Host ("  OK    {0}" -f $Name)
    return
  }
  Write-Host ("  DRIFT {0}: '{1}' is gone" -f $Name, $Needle) -ForegroundColor Red
  Write-Host ("        breaks   : {0}" -f $UsedBy)
  $script:Failures += $Name
}

function Invoke-ContractChecks {
  param([string]$Ref)

  Write-Section "launcher contracts at $Ref"

  $cli = Get-RefJson -Ref $Ref -Path 'apps/cli/package.json'
  if ($cli) {
    Test-Contract -Name 'npm package name' -Expected '@deepseek-ai/dsh' -Actual $cli.name `
      -UsedBy 'setup.ps1 $CliPackage (npm install --global)'
    Test-Contract -Name 'bin entry' -Expected 'lib/bin.js' -Actual $cli.bin.dsh `
      -UsedBy 'dsh-web.vbs process match on "\dsh\lib\bin.js"'
  }

  $root = Get-RefJson -Ref $Ref -Path 'package.json'
  if ($root) {
    Test-Contract -Name 'node engines' -Expected '^22.19.0 || >=24.0.0' -Actual $root.engines.node `
      -UsedBy 'setup.ps1 $MinimumNode22 and Test-NodeSupported'
  }

  $startup = Get-RefFile -Ref $Ref -Path 'packages/bundle/web-app/src/startup.ts'
  Test-ContractContains -Name '--port flag' -Haystack $startup -Needle '--port <port>' `
    -UsedBy 'both VBS launchers, which always pass "web --port <n>"'
  Test-ContractContains -Name '--no-open flag' -Haystack $startup -Needle '--no-open' `
    -UsedBy 'the README run instructions'

  $patch = Get-RefFile -Ref $Ref -Path 'packages/bundle/web-app/cordis.patch.yml'
  Test-ContractContains -Name 'default port 3080' -Haystack $patch -Needle 'ctx.webStartup.port ?? 3080' `
    -UsedBy 'DEFAULT_PORT in both VBS launchers and the -Port default'
}

if (-not $Branch) {
  $Branch = (Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Output
}

if (-not $NoFetch) {
  Write-Section 'fetch'
  $remote = $Upstream.Split('/')[0]
  Invoke-Git -Arguments @('fetch', $remote, '--tags') | Out-Null
  Write-Host "fetched $remote"
}

$behind = (Invoke-Git -Arguments @('rev-list', '--count', "$Branch..$Upstream")).Output
$ahead = (Invoke-Git -Arguments @('rev-list', '--count', "$Upstream..$Branch")).Output

Write-Section 'status'
Write-Host "branch                 $Branch"
Write-Host "upstream               $Upstream"
Write-Host "new upstream commits   $behind"
Write-Host "your own commits       $ahead"
$describe = Invoke-Git -Arguments @('describe', '--tags', '--abbrev=0', $Upstream) -AllowFailure
if ($describe.ExitCode -eq 0 -and $describe.Output) {
  Write-Host "latest upstream tag    $($describe.Output)"
}

if ($CheckOnly) {
  Invoke-ContractChecks -Ref $Upstream
  Write-Section 'result'
  if ($script:Failures.Count -gt 0) {
    Write-Host "$($script:Failures.Count) contract(s) drifted; update the launchers before rebasing." -ForegroundColor Red
    exit 1
  }
  Write-Host 'Every contract holds. Re-run without -CheckOnly to rebase.'
  exit 0
}

if ($behind -eq '0') {
  Write-Host ''
  Write-Host 'Already up to date with upstream; nothing to rebase.'
  Invoke-ContractChecks -Ref $Upstream
  if ($script:Failures.Count -gt 0) { exit 1 }
  exit 0
}

# Only the rebase needs a clean tree; -CheckOnly reads and mutates nothing.
$dirty = (Invoke-Git -Arguments @('status', '--porcelain')).Output
if ($dirty) {
  throw "The working tree has uncommitted changes. Commit or stash them first:`n$dirty"
}

$current = (Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Output
if ($current -ne $Branch) { throw "Check out $Branch first; the working tree is on $current." }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "backup/$Branch-$stamp"
Invoke-Git -Arguments @('branch', $backup, $Branch) | Out-Null
$backupHead = (Invoke-Git -Arguments @('rev-parse', '--short', $backup)).Output

Write-Section 'backup'
Write-Host "created $backup at $backupHead"
Write-Host "restore with: git reset --hard $backup"

Write-Section 'rebase'
$rebase = Invoke-Git -Arguments @('rebase', $Upstream) -AllowFailure
Write-Host $rebase.Output
if ($rebase.ExitCode -ne 0) {
  Write-Host ''
  Write-Host 'The rebase stopped on a conflict.' -ForegroundColor Yellow
  Write-Host '  1. resolve the files git status lists as unmerged'
  Write-Host '  2. for *.i18n.yaml records: pnpm run resolve-translation-pairing-conflicts'
  Write-Host '  3. git add <files>; git rebase --continue'
  Write-Host ''
  Write-Host "Abandon the attempt with: git rebase --abort"
  Write-Host 'With rerere enabled this resolution is remembered for next time.'
  exit 1
}

Invoke-ContractChecks -Ref 'HEAD'

Write-Section 'result'
if ($script:Failures.Count -gt 0) {
  Write-Host "The rebase succeeded, but $($script:Failures.Count) contract(s) drifted." -ForegroundColor Red
  Write-Host 'Update the launcher scripts before trusting the shortcuts.'
  exit 1
}

Write-Host "Rebased $Branch onto $Upstream; every launcher contract still holds."
Write-Host ''
Write-Host 'Next, at your discretion:'
Write-Host "  push the branch       git push --force-with-lease fork $Branch"
Write-Host '  upgrade the install   stop the running node process, then'
Write-Host '                        scripts\windows\setup.ps1 -Update -Autostart none'
