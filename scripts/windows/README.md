# Windows launchers

English | [中文](README.zh.md)

`dsh web` runs in the foreground, so the terminal that starts it owns the server and closing that window stops it. These scripts install shortcuts that start the server hidden and open the Web UI in a window of its own.

## Install

Run this from a repository checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1
```

The script checks for a supported Node.js, installs `@deepseek-ai/dsh` globally from npm, and creates Desktop, Start Menu, and logon shortcuts. The checkout needs neither `pnpm install` nor a build, because the CLI comes from npm rather than from the working tree.

| Flag | Effect |
| --- | --- |
| `-Port <n>` | Port the server listens on. Defaults to 3080, the server's own default. |
| `-Autostart none\|server\|window` | What logon starts: nothing, the server alone, or the server and its window. Defaults to `window`. |
| `-Update` | Reinstall the CLI from npm even when it is already present. |
| `-InstallNode` | Install Node.js through winget when it is missing or too old. |
| `-Uninstall` | Remove the shortcuts and launcher scripts. The log and `~/.dsh` are left alone. |

## Files

| File | Role |
| --- | --- |
| `setup.ps1` | One-command entry point: Node check, CLI install, shortcut install. |
| `install-dsh-shortcuts.ps1` | Creates the shortcuts and renders the icon from the Web UI favicon. |
| `dsh-web.vbs` | Starts the server hidden, with no console window of its own. |
| `dsh-app.vbs` | Waits for the server to bind, then opens the Web UI in an app window. |
| `sync-upstream.ps1` | Rebases onto upstream and verifies the contracts these launchers depend on. |

## Upgrading

Upgrade the repository and the installed CLI separately, so a code sync never disturbs a running server.

To rebase this branch onto the latest upstream:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync-upstream.ps1 -CheckOnly
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync-upstream.ps1
```

The launchers hard-code facts about the published CLI: its package name, its bin entry, its `--port` flag, its default port, and its supported Node range. A rebase can merge cleanly while any of those has moved, so `sync-upstream.ps1` asserts each one afterwards and names the launcher that breaks when one drifts. It never pushes and never touches the running installation.

To upgrade the installed CLI, stop the running server first: its native modules are loaded and locked while it runs, so an in-place global install can fail or leave a broken installation behind.

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*dsh*lib\bin.js*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Update
```

Then start it again from the Desktop shortcut.
