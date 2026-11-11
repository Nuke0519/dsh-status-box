# 在 Windows 虚拟机（Parallels / VMware / Hyper-V）里自动验证状态盒。
#
#   pwsh -File smoke-vm.ps1
#   powershell -ExecutionPolicy Bypass -File smoke-vm.ps1     # 老式 PowerShell 也行
#
# 它会：启动 exe → 等桥就绪 → 上报一份假状态 → 用真的 Win32 合成热键打开输入窗
# → 截图 → 输入一条任务并回车 → 确认任务进了队列 → 读配置 → 收尾并打包
# 产物到桌面：smoke-report.txt + smoke-screenshot.png（+ 同名 .zip）
#
# 不需要 DSH 在这台机器上：这条脚本只验证 Windows 外壳本身（托盘 / 热键 / 窗口 / 桥 / 队列）。

param(
    [string]$ExePath = $env:DSH_SMOKE_EXE,          # 已有 exe 时直接给路径
    [string]$ExeUrl  = $env:DSH_SMOKE_EXE_URL,      # 否则从这个 URL 下载
    [string]$ReportUrl = $env:DSH_SMOKE_REPORT_URL, # 结果回传地址（POST 纯文本）
    [int]$Port = 59421
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

$base = "http://127.0.0.1:$Port"
$report = New-Object System.Collections.Generic.List[string]
$failures = 0

function Step($name) { $script:report.Add(""); $script:report.Add("== $name"); Write-Host "`n== $name" -ForegroundColor Cyan }
function Check($name, $ok, $detail = '') {
    if ($ok) { $script:report.Add("PASS  $name  $detail") | Out-Null; Write-Host "PASS  $name" -ForegroundColor Green }
    else { $script:report.Add("FAIL  $name  $detail") | Out-Null; Write-Host "FAIL  $name  $detail" -ForegroundColor Red; $script:failures++ }
}

function Invoke-Bridge([string]$path, [string]$method = 'GET', [string]$body = $null) {
    $params = @{ Uri = "$base$path"; Method = $method; TimeoutSec = 5; UseBasicParsing = $true }
    if ($body) { $params['Body'] = $body; $params['ContentType'] = 'text/plain;charset=UTF-8' }
    Invoke-RestMethod @params
}

# ---------------------------------------------------------------- locate the exe
if (-not $ExePath -and $ExeUrl) {
    $ExePath = Join-Path $env:TEMP 'DSHStatusBox.exe'
    Write-Host "downloading $ExeUrl"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ExeUrl -OutFile $ExePath -UseBasicParsing
    Write-Host "downloaded $(([math]::Round((Get-Item $ExePath).Length / 1MB, 1))) MB"
}

if (-not $ExePath) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'DSHStatusBox.exe'),
        (Join-Path $PSScriptRoot '..\src\DSHStatusBox.App\bin\Release\net8.0-windows\win-x64\publish\DSHStatusBox.exe'),
        (Join-Path $PSScriptRoot '..\..\dist\win-x64\DSHStatusBox.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DSHStatusBox\DSHStatusBox.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { $ExePath = (Resolve-Path $candidate).Path; break }
    }
}

$startedHere = $false
$proc = $null
Step 'environment'
$report.Add("OS: $([Environment]::OSVersion.VersionString)") | Out-Null
$report.Add("64-bit process: $([Environment]::Is64BitProcess)") | Out-Null
$report.Add("PSVersion: $($PSVersionTable.PSVersion)") | Out-Null
if (-not $ExePath) { throw '找不到 DSHStatusBox.exe：把脚本和 exe 放同一个目录，或用 -ExePath 指定' }
$report.Add("exe: $ExePath") | Out-Null
Write-Host "exe: $ExePath"

$already = Get-Process -Name DSHStatusBox -ErrorAction SilentlyContinue
if ($already) {
    Write-Host '已经有一个状态盒在跑，直接复用它（不会重复启动）' -ForegroundColor Yellow
    $proc = $already[0]
} else {
    $env:DSH_STATUS_BOX_DEBUG = '1'
    $proc = Start-Process -FilePath $ExePath -PassThru
    $startedHere = $true
    Write-Host "started pid $($proc.Id)"
}

try {
    # ------------------------------------------------------------ bridge ready
    Step 'bridge reachable'
    $ping = $null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        try { $ping = Invoke-Bridge '/ping'; break } catch { Start-Sleep -Milliseconds 600 }
    }
    Check '/ping answers' ($null -ne $ping -and $ping.ok) ($(if ($ping) { $ping | ConvertTo-Json -Compress } else { 'no response' }))

    if (-not $ping) { throw '桥没有起来，后面没法继续。看看 %APPDATA%\DSHStatusBox\companion.log' }

    # ------------------------------------------------------------ status ingest
    Step 'status ingest'
    $payload = @{
        totals     = @{ waiting = 1; running = 2; done = 1; idle = 4; total = 8 }
        workspaces = @(
            @{ id = 'vm-workspace'; title = 'VM 工作区'; waiting = 1; running = 2; done = 1 }
        )
        sessions   = @(
            @{ title = 'vm smoke session'; state = 'running'; workspace = 'VM 工作区' }
        )
    } | ConvertTo-Json -Depth 6
    Invoke-Bridge '/status' 'POST' $payload | Out-Null
    Start-Sleep -Milliseconds 500
    $debug = Invoke-Bridge '/debug'
    Check 'totals parsed' ($debug.totals.running -eq 2 -and $debug.totals.waiting -eq 1) ($debug.totals | ConvertTo-Json -Compress)
    Check 'workspace parsed' ($debug.workspaces[0].title -eq 'VM 工作区') ($debug.workspaces[0] | ConvertTo-Json -Compress)

    # ------------------------------------------------------------ tray + hotkey
    Step 'tray icon and global hotkey'
    $before = Invoke-Bridge '/panelstate'
    Check 'panel starts hidden' ($before.visible -eq 0) ($before | ConvertTo-Json -Compress)

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DshKeys {
    [DllImport("user32.dll", SetLastError = true)] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void SetCursorPos(int x, int y);
    public static void Combo(byte[] keys) {
        foreach (var k in keys) keybd_event(k, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        for (int i = keys.Length - 1; i >= 0; i--) keybd_event(keys[i], 0, 2, UIntPtr.Zero);
    }
}
'@
    [DshKeys]::Combo(@([byte]0x11, [byte]0x12, [byte]0x10, [byte]0x44))   # Ctrl, Alt, Shift, D
    Start-Sleep -Milliseconds 900
    $after = Invoke-Bridge '/panelstate'
    Check 'hotkey opens the capture window' ($after.visible -eq 1) ($after | ConvertTo-Json -Compress)
    $hot = Invoke-Bridge '/hotkey'
    Check 'hotkey registered' ($hot.register -eq 0) (($hot | ConvertTo-Json -Compress))

    # ------------------------------------------------------------ screenshot
    Step 'screenshot'
    $shot = Join-Path $env:USERPROFILE 'Desktop\smoke-screenshot.png'
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
        $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bmp.Dispose()
        Check 'desktop screenshot saved' (Test-Path $shot) $shot
    } catch {
        Check 'desktop screenshot saved' $false $_.Exception.Message
    }

    # ------------------------------------------------------------ submit a task
    Step 'submit a task from the capture window'
    $text = "vm smoke $(Get-Date -Format HHmmss)"
    [System.Windows.Forms.SendKeys]::SendWait($text)
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 1200
    $command = Invoke-Bridge '/command'
    $task = $command.tasks | Select-Object -First 1
    Check 'task reached the queue' ($null -ne $task -and $task.text -eq $text) (($task | ConvertTo-Json -Compress))
    if ($task) {
        Invoke-Bridge '/command/ack' 'POST' (@{ id = $task.id; ok = $true } | ConvertTo-Json) | Out-Null
        Start-Sleep -Milliseconds 300
        $again = Invoke-Bridge '/command'
        Check 'acked task is not redelivered' (@($again.tasks).Count -eq 0) (($again | ConvertTo-Json -Compress))
    }

    # ------------------------------------------------------------ settings round trip
    Step 'settings round trip'
    Invoke-Bridge '/config' 'POST' '{"openOnSend":true}' | Out-Null
    $config = Invoke-Bridge '/config'
    Check 'config accepts true' ($config.openOnSend -eq $true) ($config | ConvertTo-Json -Compress)
    Invoke-Bridge '/config' 'POST' '{"openOnSend":false}' | Out-Null
    $config = Invoke-Bridge '/config'
    Check 'config accepts false' ($config.openOnSend -eq $false) ($config | ConvertTo-Json -Compress)

    # ------------------------------------------------------------ diagnostics
    Step 'diagnostics'
    $report.Add("process: $((Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) | Select-Object Id, ProcessName, WorkingSet64 | Out-String)") | Out-Null
    $logPath = Join-Path $env:APPDATA 'DSHStatusBox\companion.log'
    if (Test-Path $logPath) {
        $report.Add("--- companion.log (tail 20) ---") | Out-Null
        Get-Content $logPath -Tail 20 | ForEach-Object { $report.Add($_) | Out-Null }
    } else {
        $report.Add("no log at $logPath") | Out-Null
    }
}
catch {
    $failures++
    $report.Add("EXCEPTION: $($_.Exception.Message)") | Out-Null
    Write-Host "EXCEPTION: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Step 'result'
    if ($failures -eq 0) {
        $report.Add('ALL CHECKS PASSED') | Out-Null
        Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
    } else {
        $report.Add("$failures CHECK(S) FAILED") | Out-Null
        Write-Host "$failures CHECK(S) FAILED" -ForegroundColor Red
    }

    if ($startedHere) {
        Get-Process -Name DSHStatusBox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $reportPath = Join-Path $env:USERPROFILE 'Desktop\smoke-report.txt'
    $report | Set-Content -Path $reportPath -Encoding UTF8
    $shot = Join-Path $env:USERPROFILE 'Desktop\smoke-screenshot.png'
    $zip = Join-Path $env:USERPROFILE 'Desktop\smoke-report.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $files = @($reportPath)
    if (Test-Path $shot) { $files += $shot }
    Compress-Archive -Path $files -DestinationPath $zip -Force

    Write-Host "`n报告：$reportPath"
    if (Test-Path $shot) { Write-Host "截图：$shot" }
    Write-Host "打包：$zip  ← 把这个发回来就行"

    if ($ReportUrl) {
        try {
            $body = ($report -join "`r`n")
            Invoke-WebRequest -Uri $ReportUrl -Method POST -Body $body -ContentType 'text/plain; charset=UTF-8' -UseBasicParsing -TimeoutSec 10 | Out-Null
            Write-Host "报告已回传 $ReportUrl"
        } catch {
            Write-Host "回传失败（不影响本地报告）：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
