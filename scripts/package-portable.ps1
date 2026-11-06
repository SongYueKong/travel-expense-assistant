param([string]$Version = '',[switch]$SkipChecks)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskFlutter = Join-Path $taskRoot '.tools/flutter/bin/flutter.bat'
$taskPython = Join-Path $taskRoot '.venv/Scripts/python.exe'
if (-not $Version) {
    $taskPubspec = Get-Content -LiteralPath (Join-Path $taskRoot 'apps/desktop/pubspec.yaml') -Raw
    $Version = [regex]::Match($taskPubspec,'(?m)^version:\s*([^+\s]+)').Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw '版本号格式应为1.0.0' }
$taskStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$taskBuildRoot = Join-Path $taskRoot ".local/release-builds/$taskStamp"
$taskPackage = Join-Path $taskBuildRoot '差旅报账助手'
# 始终从独立源码副本构建，发布不占用或覆盖用户正在使用的开发版。
$taskSourceRoot = Join-Path $taskBuildRoot 'source'
& $taskPython (Join-Path $taskRoot 'scripts/prepare-portable-source.py') --root $taskRoot --destination $taskSourceRoot
if ($LASTEXITCODE -ne 0) { throw '建立独立发布工作区失败' }
# 使用目录联接复用已解析的插件缓存，不要求系统启用开发者符号链接权限。
$taskPluginMetadata = Join-Path $taskSourceRoot 'apps/desktop/.flutter-plugins-dependencies'
if (Test-Path -LiteralPath $taskPluginMetadata) {
    $taskPluginLinks = Join-Path $taskSourceRoot 'apps/desktop/windows/flutter/ephemeral/.plugin_symlinks'
    [void][System.IO.Directory]::CreateDirectory($taskPluginLinks)
    $taskPlugins = (Get-Content -LiteralPath $taskPluginMetadata -Raw | ConvertFrom-Json).plugins.windows
    foreach ($taskPlugin in $taskPlugins) {
        if ($taskPlugin.name -notmatch '^[A-Za-z0-9_]+$') { throw '插件名称格式无效' }
        [void](New-Item -ItemType Junction -Path (Join-Path $taskPluginLinks $taskPlugin.name) -Target $taskPlugin.path)
    }
}

$taskCmakeCache = Join-Path $taskSourceRoot 'apps/desktop/build/windows/x64/CMakeCache.txt'
$taskReleaseDirectory = Join-Path $taskSourceRoot 'apps/desktop/build/windows/x64/runner/Release'
$taskCmake = $null
if (Test-Path -LiteralPath $taskCmakeCache) {
    $taskCmake = [regex]::Match((Get-Content -LiteralPath $taskCmakeCache -Raw),'(?m)^CMAKE_COMMAND:INTERNAL=(.+)$').Groups[1].Value.Trim()
    & $taskCmake -S (Join-Path $taskSourceRoot 'apps/desktop/windows') -B (Split-Path -Parent $taskCmakeCache) "-DCMAKE_INSTALL_PREFIX=$taskReleaseDirectory"
    if ($LASTEXITCODE -ne 0) { throw '无法设置独立Release输出目录' }
}
[void][System.IO.Directory]::CreateDirectory($taskBuildRoot)
Push-Location (Join-Path $taskSourceRoot 'apps/desktop')
try {
    & $taskFlutter --no-version-check pub get --offline
    if ($LASTEXITCODE -ne 0) { throw '依赖未就绪，请先安装开发依赖' }
    if (-not $SkipChecks) {
        & $taskFlutter --no-version-check analyze --no-pub lib test tool
        if ($LASTEXITCODE -ne 0) { throw '静态检查失败' }
        & $taskFlutter --no-version-check test --no-pub --reporter expanded *> (Join-Path $taskBuildRoot 'flutter-tests.log')
        if ($LASTEXITCODE -ne 0) { throw "Flutter回归失败，见 $taskBuildRoot/flutter-tests.log" }
        $ErrorActionPreference = 'Continue'
        & $taskPython -m unittest discover -s (Join-Path $taskRoot 'engine') -v *> (Join-Path $taskBuildRoot 'engine-tests.log')
        $taskEngineExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($taskEngineExit -ne 0) { throw "处理引擎回归失败，见 $taskBuildRoot/engine-tests.log" }
    }
    # Flutter切换Debug/Release后可能遗留共享构建缓存中的调试内核。
    # 只删除该已知生成文件；已安装的Debug程序和用户数据不受影响。
    $taskDebugKernel = Join-Path $taskSourceRoot 'apps/desktop/build/flutter_assets/kernel_blob.bin'
    if (Test-Path -LiteralPath $taskDebugKernel) { Remove-Item -LiteralPath $taskDebugKernel -Force }
    & $taskFlutter --no-version-check build windows --release --no-pub "--build-name=$Version"
    if ($LASTEXITCODE -ne 0) { throw 'Release构建失败' }
} finally {
    Pop-Location
    if (-not $taskCmake -and (Test-Path -LiteralPath $taskCmakeCache)) { $taskCmake = [regex]::Match((Get-Content -LiteralPath $taskCmakeCache -Raw),'(?m)^CMAKE_COMMAND:INTERNAL=(.+)$').Groups[1].Value.Trim() }
    if ($taskCmake) {
        & $taskCmake --install (Split-Path -Parent $taskCmakeCache) --config Release --prefix $taskReleaseDirectory
        $taskInstallExit = $LASTEXITCODE
        $taskDebugDirectory = Join-Path $taskSourceRoot 'apps/desktop/build/windows/x64/runner/Debug'
        & $taskCmake -S (Join-Path $taskSourceRoot 'apps/desktop/windows') -B (Split-Path -Parent $taskCmakeCache) "-DCMAKE_INSTALL_PREFIX=$taskDebugDirectory"
        if ($taskInstallExit -ne 0 -or $LASTEXITCODE -ne 0) { throw '发布文件安装或恢复开发配置失败' }
    }
}
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$taskVs = & $taskVswhere -latest -products '*' -property installationPath
if (-not $taskVs) { throw '未找到Visual Studio的可再分发运行库' }
$taskRedist = Get-ChildItem -LiteralPath (Join-Path $taskVs 'VC/Redist/MSVC') -Directory |
    Sort-Object Name -Descending | ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'x64/Microsoft.VC*.CRT') -Directory -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $taskRedist) { throw '未找到x64 MSVC运行库' }
& $taskPython (Join-Path $taskRoot 'scripts/build-portable.py') --root $taskRoot --stage $taskPackage --version $Version --redist $taskRedist.FullName --release-directory $taskReleaseDirectory
if ($LASTEXITCODE -ne 0) { throw '收集发布文件失败' }
$taskRuntime = Join-Path $taskPackage 'runtime/python/python.exe'
$taskReport = Join-Path $taskBuildRoot 'portable-check.json'
& $taskRuntime -B -E -s -X utf8 (Join-Path $taskPackage 'verify-portable.py') --package $taskPackage --report $taskReport
if ($LASTEXITCODE -ne 0) { throw "免安装自检失败，见 $taskBuildRoot" }
$taskOutput = Join-Path $taskRoot 'output/releases'
[void][System.IO.Directory]::CreateDirectory($taskOutput)
$taskZip = Join-Path $taskOutput "TravelExpenseAssistant-$Version-windows-x64-$taskStamp.zip"
& $taskPython (Join-Path $taskRoot 'scripts/archive-portable.py') --package $taskPackage --output $taskZip
if ($LASTEXITCODE -ne 0) { throw '生成压缩包失败' }
Write-Output "已生成：$taskZip"
Write-Output "自检报告：$taskReport"
