# Builds and drives the native runner with an isolated database/test registry.
param([switch]$Autostart, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
$flutter = Join-Path $projectRoot '.tools/flutter/bin/flutter.bat'
if (Test-Path -LiteralPath $flutter) { $env:PUB_CACHE = Join-Path $projectRoot '.tools/pub-cache' }
else { $flutter = (Get-Command flutter -ErrorAction Stop).Source }
$portable = Test-Path -LiteralPath '.tools/msvc/setup_x64.bat'
$executable = if ($portable) { Join-Path $projectRoot 'dist/TrackStudy-Debug/trackstudy.exe' } else { Join-Path $projectRoot 'build/windows/x64/runner/Debug/trackstudy.exe' }
if (!$SkipBuild) {
    if ($portable) { & "$PSScriptRoot/build-portable.ps1" -Configuration Debug -Target integration_test/desktop_test.dart }
    else { & $flutter build windows --debug --target integration_test/desktop_test.dart }
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'Native test build failed' }
}
New-Item -ItemType Directory -Force -Path '.tools/native-tests' | Out-Null
$ErrorActionPreference='Stop'

$env:FLUTTER_ENGINE_SWITCHES='2'
$env:FLUTTER_ENGINE_SWITCH_1='enable-dart-profiling=true'
$env:FLUTTER_ENGINE_SWITCH_2='enable-checked-mode=true'
$fixture=Join-Path $PWD ('.tools/native-tests/data ' + [guid]::NewGuid().ToString('N'))
$outFile=".tools/native-tests/run-$([guid]::NewGuid().ToString('N')).out"
$errFile="$outFile.err"
$launchArgs=@('--data-dir="'+$fixture+'"'); if($Autostart){$launchArgs+="--autostart"}
$app=Start-Process $executable -ArgumentList $launchArgs -WorkingDirectory (Split-Path $executable -Parent) -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru
try {
 $service=$null
 for($i=0;$i -lt 40;$i++) {
  Start-Sleep -Milliseconds 500
  $output=Get-Content $outFile -Raw -ErrorAction SilentlyContinue
  if($output -match 'http://127\.0\.0\.1:\d+/[^\s]+') {$service=$Matches[0];break}
  if($app.HasExited){throw 'Native runner exited before VM service'}
 }
 if(!$service){throw 'Native VM service did not start'}
 & $flutter drive --no-pub --device-id=windows --target=integration_test/desktop_test.dart --driver=test_driver/integration_test.dart "--use-existing-app=$service" *> .tools/native-tests/driver.log
 if($LASTEXITCODE -ne 0){Get-Content .tools/native-tests/driver.log -Tail 60;throw 'Native Windows tests failed'}
 Get-Content .tools/native-tests/driver.log -Tail 6
 if (!('PlanningClose' -as [type])) { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PlanningClose { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd); [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); }' }
 $app.Refresh();$window=$app.MainWindowHandle
 foreach($mode in @(0,7)) {
  [PlanningClose]::ShowWindow($window,$mode)|Out-Null
  $duplicate=Start-Process $executable -ArgumentList ('--data-dir="'+$fixture+'"') -WorkingDirectory (Split-Path $executable -Parent) -WindowStyle Hidden -PassThru
  if(!$duplicate.WaitForExit(5000)){Stop-Process -Id $duplicate.Id;throw 'Duplicate instance did not exit'}
  for($i=0;$i -lt 20;$i++) {
   if([PlanningClose]::IsWindowVisible($window) -and [PlanningClose]::IsZoomed($window) -and ![PlanningClose]::IsIconic($window)){break}
   Start-Sleep -Milliseconds 100
  }
  if($app.HasExited -or ![PlanningClose]::IsWindowVisible($window) -or ![PlanningClose]::IsZoomed($window) -or [PlanningClose]::IsIconic($window)){throw "Duplicate launch failed to maximize existing window from show-state $mode"}
  Write-Output "PASS: duplicate launch restores and maximizes existing instance from show-state $mode"
 }
 if($window -eq 0){throw 'Missing test window'}
 if(![PlanningClose]::PostMessage($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)){throw 'Could not post Close to the tested window'}
 if(!$app.WaitForExit(30000)){throw 'Close with background off did not exit'}
 Write-Output 'PASS: closing with background mode off terminates the app'
} finally {
 if(!$app.HasExited){Stop-Process -Id $app.Id -ErrorAction SilentlyContinue}
 Remove-Item Env:FLUTTER_ENGINE_SWITCHES,Env:FLUTTER_ENGINE_SWITCH_1,Env:FLUTTER_ENGINE_SWITCH_2 -ErrorAction SilentlyContinue
 Pop-Location
}
