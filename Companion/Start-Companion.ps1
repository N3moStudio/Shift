$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not (Test-Path -LiteralPath '.venv\Scripts\python.exe')) {
    $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $bundledPython) { $companionPython = $bundledPython }
    elseif ($pythonCommand) { $companionPython = $pythonCommand.Source }
    else { throw 'Install Python 3.12 or 3.13 with Add Python to PATH enabled, then open this launcher again.' }
    & $companionPython -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.13 first, with Add Python to PATH enabled.' }
}
$dependencyStamp = ((Get-FileHash requirements.txt).Hash + (Get-FileHash requirements-windows.lock.txt).Hash)
$stampPath = '.venv\shift-dependencies.txt'
$savedStamp = if (Test-Path -LiteralPath $stampPath) { (Get-Content -Raw -LiteralPath $stampPath).Trim() } else { '' }
if ($savedStamp -ne $dependencyStamp) {
    & '.venv\Scripts\python.exe' -m pip install -r requirements.txt -c requirements-windows.lock.txt
    if ($LASTEXITCODE -ne 0) { throw 'The helper dependencies did not install. Keep the error text and report it.' }
    Set-Content -LiteralPath $stampPath -Value $dependencyStamp
}
& '.venv\Scripts\python.exe' companion.py
