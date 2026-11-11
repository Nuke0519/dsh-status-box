# 状态盒 · Windows 版

DeepSeek Harness 的 Windows 状态助手：**任务栏托盘**常驻一条小鲸鱼看全局任务状态，按 **Ctrl+Alt+Shift+D** 弹出单输入框，把任务丢进任意工作区——不用切回 DSH。

协议层（`127.0.0.1:59421` 的本机回环桥、队列、配置、状态存储）与 macOS 版**完全一致**，所以 DSH 插件侧（顶部胶囊、设置页开关）不用改一行：同一份 `client.js` 在 Windows 上连的就是这个托盘程序。

## 三个入口

| 入口 | 位置 | 作用 |
| --- | --- | --- |
| 托盘图标 | 任务栏右下角通知区域 | **DeepSeek 小鲸鱼** + 数字，随状态变色；左键开输入窗，右键看按工作区分组的菜单 |
| 悬浮输入窗 | Ctrl+Alt+Shift+D（全局，任何 App 前台都生效） | 只有一个输入框：敲需求 → Enter 直接发起；Enter 发起 / Esc 关闭 / Tab 切换工作区；发送失败会自己弹回来，原文保留、红字写明原因 |
| DSH 设置页 | DSH → 设置 → **状态盒** | 一个开关：发送后打开对话页，还是留在原地继续忙 |

状态配色：橙 `◉` 等你处理 / 绿 `●` 运行中 / 蓝 `✓` 刚完成 / 灰 `○` 空闲或未连接。

## 安装（用现成的 exe）

1. 从 [Releases](https://github.com/Nuke0519/dsh-status-box/releases) 下载 `DSHStatusBox-win-x64.zip`，解压。
2. 右键 `install.ps1` → 用 PowerShell 运行（或在解压目录 `pwsh -File install.ps1`）。

装完会在 `%LOCALAPPDATA%\Programs\DSHStatusBox\` 放一份 exe，登记开机启动（HKCU Run），并立即运行；任务栏右下角出现小鲸鱼即可。

```powershell
pwsh -File install.ps1            # 安装并启动
pwsh -File install.ps1 -NoStart   # 只安装
pwsh -File install.ps1 -NoAutoStart  # 不登记开机启动
pwsh -File uninstall.ps1          # 卸载（保留配置）
pwsh -File uninstall.ps1 -PurgeData  # 卸载并删除配置与队列
```

## 自己构建

需要 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)（Windows 上装一次即可）。

```powershell
pwsh -File windows\build.ps1
# 产物：windows\dist\win-x64\DSHStatusBox.exe（自包含单文件，约 63 MB，无需目标机装 .NET）
```

`build.ps1` 会先跑协议层冒烟测试（36 项，纯 .NET、不碰 UI），再发布 `win-x64` 自包含单文件。

## 数据与日志

| 文件 | 说明 |
| --- | --- |
| `%APPDATA%\DSHStatusBox\config.json` | `{"openOnSend":false}`；可选 `"dshExe":"C:\\...\\DeepSeek Harness.exe"` 指定 DSH 路径 |
| `%APPDATA%\DSHStatusBox\queue.json` | 待发送队列；DSH 没开时任务在这里排队，开起来后 2 秒内自动发出 |
| `%APPDATA%\DSHStatusBox\status.json` | 最后已知状态（DSH 关掉后托盘仍显示最后状态） |
| `%APPDATA%\DSHStatusBox\companion.log` | 排障日志 |

## 故障排查

- **托盘没有小鲸鱼**：`tasklist | findstr DSHStatusBox` 看进程在不在；看 `%APPDATA%\DSHStatusBox\companion.log` 最后几行。
- **热键没反应**：如果别的程序占了 `Ctrl+Alt+Shift+D`，`RegisterHotKey` 会失败——日志里会有 `hotkey register failed: <错误码>`；换掉冲突程序或告我换组合键。
- **设置页提示"没连上菜单栏小助手"**：确认 `curl http://127.0.0.1:59421/ping` 返回 `{"ok":true}`；端口被占用时会回退失败，日志里有记录。可用环境变量 `DSH_STATUS_BOX_PORT` 改端口（插件侧也要对应改）。
- **发送失败会自己弹回来**：面板会保留原文并红字写原因（例如 DSH 里没有可用工作区服务）。
- **DSH 装在非标准路径**：在 `config.json` 里加 `"dshExe":"完整路径\\DeepSeek Harness.exe"`，或用注册表 `Uninstall` 项里能自动找到的标准安装。

## 已知限制

- 目前只做 **win-x64**；ARM64 Windows 可用 x64 兼容层运行（性能略降）。
- 菜单里的会话条目点一下是**把 DSH 窗口切到前台**，不能直接跳到某个会话（DSH 桌面端只认 `dsh://open`，没有会话级深链）。
- 全屏（独占全屏游戏等）下悬浮窗可能被系统挡在后面，退出全屏即可。
- 与 macOS 版一样：**跨机不共享状态**，状态来自本机 DSH 页面每 8 秒一次的心跳。

## 与 macOS 版的关系

```
DSH 页面（client.js 胶囊 + 桥）
        │  POST /status   GET /command   POST /command/ack   GET|POST /config
        ▼
127.0.0.1:59421  ← 同一套协议、同一套白名单与 PNA 预检头
        ▲
        ├── macOS: menubar/main.m（Objective-C，菜单栏 + NSPanel）
        └── Windows: windows/src/DSHStatusBox.App（C# WinForms，托盘 + 无边框输入窗）
```

两边可以同时装（同一台机器上不同时跑两份），配置/队列文件格式一致。

## 在虚拟机里自测（无需 DSH）

```powershell
# 在 Windows 虚拟机里执行（Parallels / VMware / Hyper-V 都行）
powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke-vm.ps1
```

脚本会自己找到 exe（当前目录 → publish 目录 → `%LOCALAPPDATA%\Programs\DSHStatusBox`），
启动后验证：桥就绪 → 状态上报与解析 → 托盘/热键（用真的 `user32!keybd_event` 合成
`Ctrl+Alt+Shift+D`）→ 输入窗可见性 → 截图 → 输入一条任务并确认进入队列 → 配置往返。
结果写到桌面：`smoke-report.txt`、`smoke-screenshot.png`，并打包成 `smoke-report.zip`。

不需要在这台机器上装 DSH：这条脚本验证的是 Windows 外壳自身（托盘 / 热键 / 输入窗 / 桥 / 队列）。
