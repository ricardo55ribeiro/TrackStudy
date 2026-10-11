# Optional local fallback when Visual Studio cannot be installed.
# Requires official MSVC/SDK extracted into .tools/msvc, plus portable CMake/Ninja.
param([ValidateSet('Debug','Release')][string]$Configuration = 'Release', [string]$Target = 'lib/main.dart')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\supabase-config.ps1"
$clientDefines = if ($Target -eq 'lib/main.dart') { @(Get-TrackStudyDefines $projectRoot) } else { @() }
$defineArguments = @($clientDefines | ForEach-Object { "--dart-define=$_" })
$encodedDefines = ($clientDefines | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }) -join ','
$compilerRoot = Join-Path $projectRoot '.tools\msvc'
$cmake = Join-Path $projectRoot '.tools\cmake-3.31.8-windows-x86_64\bin\cmake.exe'
$ninja = Join-Path $projectRoot '.tools\ninja'
$flutter = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
foreach ($required in @($cmake, $flutter, "$compilerRoot\setup_x64.bat", "$ninja\ninja.exe")) {
    if (!(Test-Path -LiteralPath $required)) { throw "Missing portable tool: $required" }
}
$toolVersion = (Get-ChildItem -LiteralPath "$compilerRoot\VC\Tools\MSVC" -Directory | Select-Object -First 1).Name
$sdkVersion = (Get-ChildItem -LiteralPath "$compilerRoot\Windows Kits\10\bin" -Directory | Where-Object Name -Like '10.*' | Select-Object -First 1).Name
$vc = "$compilerRoot\VC\Tools\MSVC\$toolVersion"
$sdk = "$compilerRoot\Windows Kits\10"
$env:PATH = "$vc\bin\Hostx64\x64;$sdk\bin\$sdkVersion\x64;$sdk\bin\$sdkVersion\x64\ucrt;$ninja;$env:PATH"
$env:INCLUDE = "$vc\include;$vc\atlmfc\include;$sdk\Include\$sdkVersion\ucrt;$sdk\Include\$sdkVersion\shared;$sdk\Include\$sdkVersion\um;$sdk\Include\$sdkVersion\winrt;$sdk\Include\$sdkVersion\cppwinrt"
$env:LIB = "$vc\lib\x64;$vc\atlmfc\lib\x64;$sdk\Lib\$sdkVersion\ucrt\x64;$sdk\Lib\$sdkVersion\um\x64"
$env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
$env:FLUTTER_ROOT = Join-Path $projectRoot '.tools\flutter'
$env:PROJECT_DIR = $projectRoot
$env:FLUTTER_TARGET = $Target
$env:VCToolsInstallDir = "$vc\"
$env:WindowsSdkDir = "$sdk\"
$env:WindowsSDKVersion = "$sdkVersion\"
Push-Location $projectRoot
try {
    # NTFS junctions give Flutter plugins directory links without Developer Mode.
    $plugins = Get-Content .flutter-plugins-dependencies -Raw | ConvertFrom-Json
    $links = Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $links | Out-Null
    foreach ($plugin in $plugins.plugins.windows) {
        $link = Join-Path $links $plugin.name
        if (!(Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null }
    }
    # Flutter writes the versioned CMake environment before checking for VS.
    $mode = $Configuration.ToLowerInvariant()
    $configurationOutput = & $flutter build windows "--$mode" --no-pub --config-only --target $Target @defineArguments 2>&1
    if ($LASTEXITCODE -ne 0 -and ($configurationOutput -join "`n") -notmatch 'Unable to find suitable Visual Studio toolchain') {
        throw 'Flutter could not generate its Windows build configuration. Check the local SDK and build target.'
    }
    Write-Output 'Flutter configuration generated; building with portable MSVC.'
    $output = Join-Path $projectRoot "build\windows\portable-$mode"
    $bundle = Join-Path $projectRoot "dist\TrackStudy-$Configuration"
    # Ninja requires the import library before its first dependency scan.
    & $flutter assemble --output=build -dTargetPlatform=windows-x64 "-dBuildMode=$mode" "-dTargetFile=$Target" "-dDartDefines=$encodedDefines" -dTreeShakeIcons=true "${mode}_bundle_windows-x64_assets"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter asset/AOT assembly failed.' }
    & $cmake -S windows -B $output -G Ninja "-DCMAKE_BUILD_TYPE=$Configuration" "-DCMAKE_INSTALL_PREFIX=$bundle" -DFLUTTER_TARGET_PLATFORM=windows-x64
    if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
    & $cmake --build $output --target install --config $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'Native Windows compilation failed.' }
    # App-local MSVC runtime deployment; the end user needs no toolchain.
    $runtime = Get-ChildItem "$compilerRoot\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT\*.dll" -ErrorAction SilentlyContinue
    foreach ($dll in $runtime) { Copy-Item -LiteralPath $dll.FullName -Destination $bundle }
    if ($Configuration -eq 'Debug') {
        Get-ChildItem "$vc\bin\Hostx64\x64\*d.dll" | Copy-Item -Destination $bundle
        Copy-Item -LiteralPath "$sdk\bin\$sdkVersion\x64\ucrt\ucrtbased.dll" -Destination $bundle
    }
    Copy-Item -LiteralPath "$PSScriptRoot\install-shortcut.ps1", "$PSScriptRoot\Create Desktop Shortcut.bat" -Destination $bundle
    if ($Configuration -eq 'Release') {
        Compress-Archive -Path "$bundle\*" -DestinationPath (Join-Path $projectRoot 'dist\TrackStudy-windows-x64.zip') -Force
    }
    Write-Output "Windows bundle: $bundle"
} finally { Pop-Location }
