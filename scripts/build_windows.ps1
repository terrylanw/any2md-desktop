[CmdletBinding()]
param(
    [string]$InnoCompiler = $env:INNO_SETUP_COMPILER
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Find-InnoCompiler {
    param([string]$Override)

    if ($Override) {
        if (Test-Path -LiteralPath $Override -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Override).Path
        }
        throw "The specified Inno Setup compiler does not exist: $Override"
    }

    $pathCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($pathCommand) {
        return $pathCommand.Source
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installations = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Inno Setup*' }
    foreach ($installation in $installations) {
        if ($installation.InstallLocation) {
            $candidate = Join-Path $installation.InstallLocation 'ISCC.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    $defaultCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $defaultCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

& (Join-Path $PSScriptRoot 'build_converter.ps1')
if (-not $?) {
    throw 'Converter build failed.'
}

Push-Location $repoRoot
try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Windows build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$releaseRoot = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$flutterExecutable = Join-Path $releaseRoot 'any2md_desktop.exe'
$converterSource = Join-Path $repoRoot 'build\sidecar\windows\any2md_converter'
$converterDestination = Join-Path $releaseRoot 'converter'
if (-not (Test-Path -LiteralPath $flutterExecutable -PathType Leaf)) {
    throw "Flutter executable is missing: $flutterExecutable"
}
if (-not (Test-Path -LiteralPath (Join-Path $converterSource 'any2md_converter.exe') -PathType Leaf)) {
    throw "Converter executable is missing: $converterSource"
}
if (Test-Path -LiteralPath $converterDestination) {
    Remove-Item -LiteralPath $converterDestination -Recurse -Force
}
Copy-Item -LiteralPath $converterSource -Destination $converterDestination -Recurse

$resolvedInnoCompiler = Find-InnoCompiler -Override $InnoCompiler
if ($resolvedInnoCompiler) {
    Write-Host "Using Inno Setup compiler: $resolvedInnoCompiler"
    & $resolvedInnoCompiler (Join-Path $repoRoot 'installer\any2md.iss')
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
    }
    Write-Host 'Installer created under installer\Output.'
} else {
    Write-Warning 'Inno Setup 6 is not installed; the unpackaged release is ready.'
}
