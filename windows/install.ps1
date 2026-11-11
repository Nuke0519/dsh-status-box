# Installs 状态盒 for the current Windows user.
#
#   pwsh -File install.ps1                 # 复制、登记开机启动并立即运行
#   pwsh -File install.ps1 -NoStart        # 只复制，不启动
#   pwsh -File install.ps1 -NoAutoStart    # 不登记开机启动
#
# 安装位置：%LOCALAPPDATA%\Programs\DSHStatusBox\DSHStatusBox.exe
# 数据目录：%APPDATA%\DSHStatusBox\（config.json / queue.json / status.json / companion.log）

param(
    [string]$SourceExe,
    [switch]$NoStart,
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'

$name = 'DSHStatusBox'
$installDir = Join-Path $env:LOCALAPPDATA "Programs\$name"
$target = Join-Path $installDir "$name.exe"

if (-not $SourceExe) {
    $candidates = @(
        (Join-Path $PSScriptRoot "$name.exe"),
        (Join-Path $PSScriptRoot 'dist\win-x64\' | Join-Path -ChildPath "$name.exe"),
        (Join-Path $PSScriptRoot '..\dist\win-x64\' | Join-Path -ChildPath "$name.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { $SourceExe = $candidate; break }
    }
}

if (-not $SourceExe -or -not (Test-Path $SourceExe)) {
    throw "找不到 $name.exe。先运行 windows\build.ps1 生成它，或用 -SourceExe 指定路径。"
}

Write-Host "== 停止已经在运行的实例" -ForegroundColor Cyan
Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

Write-Host "== 复制到 $installDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -Force $SourceExe $target

Write-Host "== 创建开始菜单快捷方式" -ForegroundColor Cyan
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
$shortcutPath = Join-Path $startMenu 'DSH 状态盒.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = 'DSH 状态盒：菜单栏状态 + 快速新建任务'
$shortcut.Save()

if ($NoAutoStart) {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $name -ErrorAction SilentlyContinue
    Write-Host '== 未登记开机启动（-NoAutoStart）' -ForegroundColor Yellow
} else {
    Write-Host '== 登记开机启动（HKCU Run）' -ForegroundColor Cyan
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $name -Value "`"$target`""
}

if (-not $NoStart) {
    Write-Host '== 启动状态盒' -ForegroundColor Cyan
    Start-Process -FilePath $target
    Start-Sleep -Milliseconds 800
    $running = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host '== 已启动：看任务栏右下角的小鲸鱼；按 Ctrl+Alt+Shift+D 打开输入窗' -ForegroundColor Green
    } else {
        Write-Host '== 进程没能留下，检查 %APPDATA%\DSHStatusBox\companion.log' -ForegroundColor Yellow
    }
} else {
    Write-Host '== 已安装（未启动）' -ForegroundColor Green
}
