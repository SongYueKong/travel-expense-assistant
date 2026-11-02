param([switch]$Release)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskFlutter = Join-Path $taskRoot '.tools/flutter/bin/flutter.bat'
$taskMode = if ($Release) { 'Release' } else { 'Debug' }
$taskExe = Join-Path $taskRoot "apps/desktop/build/windows/x64/runner/$taskMode/travel_assistant.exe"
$taskCmakeCache = Join-Path $taskRoot 'apps/desktop/build/windows/x64/CMakeCache.txt'
if (Test-Path -LiteralPath $taskCmakeCache) {
    $taskCmake = [regex]::Match((Get-Content -LiteralPath $taskCmakeCache -Raw),'(?m)^CMAKE_COMMAND:INTERNAL=(.+)$').Groups[1].Value.Trim()
    & $taskCmake -S (Join-Path $taskRoot 'apps/desktop/windows') -B (Split-Path -Parent $taskCmakeCache) "-DCMAKE_INSTALL_PREFIX=$(Split-Path -Parent $taskExe)"
    if ($LASTEXITCODE -ne 0) { throw '无法设置开发版输出目录' }
}
Push-Location (Join-Path $taskRoot 'apps/desktop')
try {
    if ($Release) {
        $taskKernel = Join-Path $taskRoot 'apps/desktop/build/flutter_assets/kernel_blob.bin'
        if (Test-Path -LiteralPath $taskKernel) { Remove-Item -LiteralPath $taskKernel -Force }
    }
    & $taskFlutter build windows "--$($taskMode.ToLowerInvariant())" --no-pub "--dart-define=PROJECT_ROOT=$taskRoot"
    if ($LASTEXITCODE -ne 0) { throw '开发版构建失败，请检查前面的编译错误；如提示EXE被占用，请关闭对应窗口后重试' }
} finally {
    Pop-Location
    if ($Release -and $taskCmake) {
        $taskDebug = Join-Path $taskRoot 'apps/desktop/build/windows/x64/runner/Debug'
        & $taskCmake -S (Join-Path $taskRoot 'apps/desktop/windows') -B (Split-Path -Parent $taskCmakeCache) "-DCMAKE_INSTALL_PREFIX=$taskDebug"
    }
}
$taskManifest = Join-Path (Split-Path -Parent $taskExe) 'data/flutter_assets/NativeAssetsManifest.json'
$taskNativeAssets = Get-Content -LiteralPath $taskManifest -Raw | ConvertFrom-Json
$taskSqlite = $taskNativeAssets.'native-assets'.windows_x64.'package:sqlite3/src/ffi/libsqlite3.g.dart'
if (-not $taskSqlite -or -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $taskExe) 'sqlite3.dll'))) {
    throw 'SQLite原生库或加载清单缺失，构建结果未通过校验'
}
# 自检通过显式环境变量使用独立目录，原项目和邮箱凭据均不参与。
$taskTestRoot = Join-Path $taskRoot ('.local/dev-startup-checks/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[void][System.IO.Directory]::CreateDirectory($taskTestRoot)
$taskOldData = $env:TRAVEL_ASSISTANT_DATA_DIR
try {
    $env:TRAVEL_ASSISTANT_DATA_DIR = $taskTestRoot
    $taskCheck = Start-Process -FilePath $taskExe -ArgumentList '--portable-self-test' -WorkingDirectory $taskTestRoot -WindowStyle Hidden -PassThru
    if (-not $taskCheck.WaitForExit(90000)) { $taskCheck.Kill(); throw '隔离启动自检超时' }
    $taskCheck.Refresh()
    $taskReport = Join-Path $taskTestRoot 'self-test.txt'
    if ($taskCheck.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $taskReport)) { throw "启动自检失败，报告目录：$taskTestRoot" }
    if (-not (Get-Content -LiteralPath $taskReport -Raw).StartsWith('OK')) { throw "启动自检未通过：$taskTestRoot" }
    Write-Host "PASS: SQLite manifest + actual EXE startup. Report: $taskReport"
    Write-Host "EXE: $taskExe"
} finally { $env:TRAVEL_ASSISTANT_DATA_DIR = $taskOldData }
