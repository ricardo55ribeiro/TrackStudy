# Preserve Flutter switches verbatim; an advanced PowerShell parameter block
# would consume Flutter's -d as PowerShell's -Debug parameter.
$FlutterArguments = @($args)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\supabase-config.ps1"
if ($FlutterArguments.Count -gt 0 -and $FlutterArguments[0] -in @('run','build') -and
    !($FlutterArguments | Where-Object { $_ -like '--dart-define*' })) {
    foreach ($define in @(Get-TrackStudyDefines $projectRoot)) { $FlutterArguments += "--dart-define=$define" }
}
$localSdk = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
if (Test-Path -LiteralPath $localSdk) {
    $env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
    & $localSdk @FlutterArguments
} else {
    & flutter @FlutterArguments
}
exit $LASTEXITCODE
