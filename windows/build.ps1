# Builds a self-contained Windows executable.
#
# Needs the .NET 8 SDK (https://dotnet.microsoft.com/download/dotnet/8.0).
# The result is a single file that runs on Windows 10/11 without a .NET install.
#
#   pwsh -File windows\build.ps1
#   pwsh -File windows\build.ps1 -OutputDir dist\win-x64

param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist\win-x64'),
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '找不到 dotnet。请先安装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0'
}

$project = Join-Path $PSScriptRoot 'src\DSHStatusBox.App\DSHStatusBox.App.csproj'
$core = Join-Path $PSScriptRoot 'src\DSHStatusBox.Core\DSHStatusBox.Core.csproj'

Write-Host "== 冒烟测试（协议层）" -ForegroundColor Cyan
Push-Location (Join-Path $PSScriptRoot 'tests\BridgeSmoke')
try {
    dotnet run -c Release
    if ($LASTEXITCODE -ne 0) { throw '冒烟测试失败' }
}
finally {
    Pop-Location
}

Write-Host "== 发布 $Runtime 自包含单文件" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
dotnet publish $project `
    -c Release `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $OutputDir

if ($LASTEXITCODE -ne 0) { throw '发布失败' }

Copy-Item -Force (Join-Path $PSScriptRoot 'install.ps1') $OutputDir
Copy-Item -Force (Join-Path $PSScriptRoot 'uninstall.ps1') $OutputDir
Copy-Item -Force (Join-Path $PSScriptRoot 'README.md') $OutputDir

$exe = Join-Path $OutputDir 'DSHStatusBox.exe'
$size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "== 完成：$exe（$size MB）" -ForegroundColor Green
Write-Host "下一步：pwsh -File $(Join-Path $OutputDir 'install.ps1')"
