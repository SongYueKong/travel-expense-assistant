$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
# 仅为当前进程及其子进程继承 Windows 已有代理，不改系统设置。
if (-not $env:HTTPS_PROXY) {
    $taskDownloadUri = [uri]'https://storage.googleapis.com'
    $taskSystemProxy = [System.Net.WebRequest]::DefaultWebProxy.GetProxy($taskDownloadUri)
    if ($taskSystemProxy.Authority -ne $taskDownloadUri.Authority) {
        $env:HTTPS_PROXY = $taskSystemProxy.AbsoluteUri
        $env:HTTP_PROXY = $taskSystemProxy.AbsoluteUri
        $env:NO_PROXY = 'localhost,127.0.0.1,::1'
    }
}
$taskFlutter = Join-Path $taskRoot '.tools\flutter\bin\flutter.bat'
$taskDart = Join-Path $taskRoot '.tools\flutter\bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path -LiteralPath $taskDart)) {
    throw 'Flutter 编译工具尚未下载完成。请先运行项目内 .tools\flutter\bin\flutter.bat --version 完成初始化。'
}
$taskPython = Join-Path $taskRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $taskPython)) { throw '请先创建项目 .venv 并安装 engine/requirements.txt。' }
& $taskDart (Join-Path $taskRoot 'packages\travel_core\test\rules_check.dart')
if ($LASTEXITCODE -ne 0) { throw '业务金额规则检查失败' }
Push-Location (Join-Path $taskRoot 'apps\desktop')
try {
    if (-not (Test-Path -LiteralPath '.\windows\CMakeLists.txt')) {
        & $taskFlutter create --platforms=windows --empty --project-name=travel_assistant .
        if ($LASTEXITCODE -ne 0) { throw 'Windows 平台工程生成失败' }
    }
    & $taskFlutter pub get
    if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath '.flutter-plugins-dependencies')) {
        # Flutter Windows 插件支持项目内目录联接，无需更改系统开发者模式。
        $taskPlugins = Get-Content -LiteralPath '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
        $taskPluginDirectory = Join-Path (Get-Location) 'windows\flutter\ephemeral\.plugin_symlinks'
        [void][System.IO.Directory]::CreateDirectory($taskPluginDirectory)
        foreach ($taskPlugin in $taskPlugins.plugins.windows) {
            if ($taskPlugin.name -notmatch '^[a-zA-Z0-9_]+$') { throw 'Invalid plugin name' }
            $taskLinkPath = Join-Path $taskPluginDirectory $taskPlugin.name
            if (-not (Test-Path -LiteralPath $taskLinkPath)) {
                New-Item -ItemType Junction -Path $taskLinkPath -Target $taskPlugin.path | Out-Null
            }
        }
        & $taskFlutter pub get
    }
    if ($LASTEXITCODE -ne 0) { throw '客户端依赖下载失败' }
    & $taskFlutter analyze lib
    if ($LASTEXITCODE -ne 0) { throw '客户端静态检查失败' }
    & $taskFlutter run -d windows "--dart-define=PROJECT_ROOT=$taskRoot"
} finally { Pop-Location }
