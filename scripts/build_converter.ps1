param(
    [ValidateSet('windows')]
    [string]$Platform = 'windows'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$converterRoot = Join-Path $repoRoot 'converter'

Push-Location $converterRoot
try {
    uv sync --dev
    if ($LASTEXITCODE -ne 0) {
        throw "uv sync failed with exit code $LASTEXITCODE"
    }
    uv run pyinstaller --noconfirm --clean any2md_converter.spec
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$source = Join-Path $converterRoot 'dist\any2md_converter'
$destination = Join-Path $repoRoot "build\sidecar\$Platform\any2md_converter"
if (-not (Test-Path -LiteralPath (Join-Path $source 'any2md_converter.exe'))) {
    throw "Converter output is missing: $source"
}
if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
}
New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $destination -Recurse
Write-Host "Converter created at $destination"
