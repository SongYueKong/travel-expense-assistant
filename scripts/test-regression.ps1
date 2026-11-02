param([string]$Dataset = '', [switch]$SkipUnitTests)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $Dataset) { $Dataset = Join-Path $taskRoot '.local/regression-dataset/v1' }
if (-not (Test-Path -LiteralPath (Join-Path $Dataset 'dataset.json'))) { throw '缺少本地数据集 dataset.json，请参阅 testdata/README.md' }
$taskDataset = (Resolve-Path -LiteralPath $Dataset).Path
$taskReports = Join-Path $taskRoot ('.local/regression-reports/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[void][System.IO.Directory]::CreateDirectory($taskReports)
$taskPython = Join-Path $taskRoot '.venv/Scripts/python.exe'
$taskFlutter = Join-Path $taskRoot '.tools/flutter/bin/flutter.bat'
$taskDart = Join-Path $taskRoot '.tools/flutter/bin/dart.bat'
$taskFailed = $false
$taskSuites = @{}
$taskPrevious = $null
$taskLatest = Join-Path $taskRoot '.local/regression-reports/latest.json'
if (Test-Path -LiteralPath $taskLatest) { $taskPrevious = (Get-Content -LiteralPath $taskLatest -Raw | ConvertFrom-Json).directory }
# 单元测试和真实材料回归均执行；任一失败最终返回非零，不修改预期答案。
if (-not $SkipUnitTests) {
    $ErrorActionPreference = 'Continue'
    & $taskPython -m unittest discover -s (Join-Path $taskRoot 'engine') -v 2>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath (Join-Path $taskReports 'python-tests.log') -Encoding UTF8
    $taskSuites['pythonExitCode'] = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { $taskFailed = $true }
    $ErrorActionPreference = 'Stop'
}
Push-Location (Join-Path $taskRoot 'apps/desktop')
try {
    if (-not $SkipUnitTests) {
        $ErrorActionPreference = 'Continue'
        & $taskFlutter test --no-pub --reporter expanded 2>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath (Join-Path $taskReports 'flutter-tests.log') -Encoding UTF8
        $taskSuites['flutterExitCode'] = $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { $taskFailed = $true }
        $ErrorActionPreference = 'Stop'
    }
    $ErrorActionPreference = 'Continue'
    & $taskDart run tool/regression_dataset.dart $taskRoot $taskDataset $taskReports 2>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath (Join-Path $taskReports 'dataset-run.log') -Encoding UTF8
    $taskSuites['datasetExitCode'] = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { $taskFailed = $true }
    $ErrorActionPreference = 'Stop'
    Get-Content -LiteralPath (Join-Path $taskReports 'dataset-run.log') -Tail 40
} finally { Pop-Location }
$taskSuites['unitTestsSkipped'] = [bool]$SkipUnitTests
$taskSuites | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskReports 'suites.json') -Encoding UTF8
if ($taskPrevious -and (Test-Path -LiteralPath (Join-Path $taskPrevious 'report.json')) -and (Test-Path -LiteralPath (Join-Path $taskReports 'report.json'))) {
    & $taskPython (Join-Path $taskRoot 'scripts/compare-regression.py') $taskPrevious $taskReports
    if ($LASTEXITCODE -ne 0) { $taskFailed = $true }
}
@{ directory = $taskReports; failed = $taskFailed } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot '.local/regression-reports/latest.json') -Encoding UTF8
Write-Host "Reports: $taskReports"
if ($taskFailed) { exit 1 }
