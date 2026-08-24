# Windows 启动器

[English](README.md) | 中文

`dsh web` 运行在前台，启动它的终端拥有该服务，关闭该窗口即停止服务。这些脚本会安装快捷方式，以隐藏方式启动服务，并在独立窗口中打开 Web UI。

## 安装

请在仓库检出目录下运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1
```

该脚本会检查 Node.js 版本是否受支持，从 npm 全局安装 `@deepseek-ai/dsh`，并创建桌面、开始菜单与登录启动快捷方式。检出目录既不需要 `pnpm install`，也不需要构建，因为 CLI 来自 npm，而非工作区。

| 参数 | 作用 |
| --- | --- |
| `-Port <n>` | 服务监听的端口。默认 3080，即服务自身的默认值。 |
| `-Autostart none\|server\|window` | 登录时启动什么：不启动、仅启动服务，或同时启动服务与窗口。默认为 `window`。 |
| `-Update` | 即使 CLI 已安装，也从 npm 重新安装。 |
| `-InstallNode` | 当 Node.js 缺失或版本过低时，通过 winget 安装。 |
| `-Uninstall` | 移除快捷方式与启动器脚本。日志和 `~/.dsh` 保持不动。 |

## 文件

| 文件 | 职责 |
| --- | --- |
| `setup.ps1` | 一条命令的入口：检查 Node、安装 CLI、安装快捷方式。 |
| `install-dsh-shortcuts.ps1` | 创建快捷方式，并由 Web UI 的 favicon 渲染图标。 |
| `dsh-web.vbs` | 以隐藏方式启动服务，不带自己的控制台窗口。 |
| `dsh-app.vbs` | 等待服务完成绑定，然后在应用窗口中打开 Web UI。 |
| `sync-upstream.ps1` | 变基到上游，并校验这些启动器所依赖的契约。 |

## 升级

仓库与已安装的 CLI 分开升级，这样同步代码就永远不会干扰正在运行的服务。

将本分支变基到最新上游：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync-upstream.ps1 -CheckOnly
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync-upstream.ps1
```

启动器硬编码了已发布 CLI 的若干事实：包名、bin 入口、`--port` 参数、默认端口，以及支持的 Node 版本范围。其中任何一项挪动之后，变基仍可能干净完成，因此 `sync-upstream.ps1` 会在变基后逐项断言，并指出某项漂移会弄坏哪个启动器。它从不推送，也从不触碰已安装的运行环境。

升级已安装的 CLI 前，请先停止正在运行的服务：服务运行期间其原生模块处于已加载且被锁定的状态，就地执行全局安装可能失败，或留下一个损坏的安装。

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*dsh*lib\bin.js*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Update
```

然后从桌面快捷方式重新启动。
