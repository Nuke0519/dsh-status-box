# Removes 状态盒 for the current Windows user.
#
#   pwsh -File uninstall.ps1              # 保留数据目录（config.json / 队列 / 日志）
#   pwsh -File uninstall.ps1 -PurgeData   # 连同 %APPDATA%\DSHStatusBox 一起删除

param(
    [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'

$name = 'DSHStatusBox'
$installDir = Join-Path $env:LOCALAPPDATA "Programs\$name"
$dataDir = Join-Path $env:APPDATA $name
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $startMenu 'DSH 状态盒.lnk'

Write-Host '== 停止状态盒' -ForegroundColor Cyan
Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

Write-Host '== 移除开机启动' -ForegroundColor Cyan
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $name -ErrorAction SilentlyContinue

Write-Host '== 移除开始菜单快捷方式' -ForegroundColor Cyan
Remove-Item -Force $shortcutPath -ErrorAction SilentlyContinue

Write-Host "== 删除 $installDir" -ForegroundColor Cyan
Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue

if ($PurgeData) {
    Write-Host "== 删除数据目录 $dataDir" -ForegroundColor Cyan
    Remove-Item -Recurse -Force $dataDir -ErrorAction SilentlyContinue
} else {
    Write-Host "== 保留数据目录：$dataDir（要一起删就加 -PurgeData）" -ForegroundColor Yellow
}

Write-Host '== 卸载完成' -ForegroundColor Green
