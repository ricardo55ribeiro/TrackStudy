$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $visualStudio = $null
    if (Test-Path -LiteralPath $vswhere) {
        $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if (!$visualStudio -and (Test-Path -LiteralPath "$projectRoot\.tools\msvc\setup_x64.bat")) {
        & "$PSScriptRoot\build-portable.ps1"
        if ($LASTEXITCODE -ne 0) { throw 'Portable Windows build failed.' }
        return
    }
    & "$PSScriptRoot\flutter.ps1" build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed; no package was produced.' }
    $release = Join-Path $projectRoot 'build\windows\x64\runner\Release'
    if (!(Test-Path -LiteralPath (Join-Path $release 'trackstudy.exe'))) { throw 'Release executable is missing.' }
    $distribution = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Force -Path $distribution | Out-Null
    if ($visualStudio) {
        Get-ChildItem "$visualStudio\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT\*.dll" | Copy-Item -Destination $release
    }
    Copy-Item -LiteralPath "$PSScriptRoot\install-shortcut.ps1", "$PSScriptRoot\Create Desktop Shortcut.bat" -Destination $release
    Compress-Archive -Path "$release\*" -DestinationPath "$distribution\TrackStudy-windows-x64.zip" -Force
    Write-Output "Portable package: $distribution\TrackStudy-windows-x64.zip"
} finally { Pop-Location }
