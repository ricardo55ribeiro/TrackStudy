param([ValidateSet('Debug','Release')][string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (!$env:JAVA_HOME) {
    $studioJava = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'
    if (Test-Path -LiteralPath "$studioJava\bin\java.exe") { $env:JAVA_HOME = $studioJava }
}
if (!$env:ANDROID_HOME) {
    $standardSdk = Join-Path $env:LOCALAPPDATA 'Android\sdk'
    if (Test-Path -LiteralPath $standardSdk) { $env:ANDROID_HOME = $standardSdk }
}
$signingFile = Join-Path $projectRoot 'android\key.properties'
if ($Configuration -eq 'Release' -and !(Test-Path -LiteralPath $signingFile)) {
    $keyDirectory = Join-Path $projectRoot 'android\signing'
    $keyPath = Join-Path $keyDirectory 'trackstudy-release.p12'
    if (Test-Path -LiteralPath $keyPath) { throw 'Signing key already exists without key.properties. Restore its original credentials; it has not been overwritten.' }
    $keytool = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\keytool.exe' } else { (Get-Command keytool -ErrorAction Stop).Source }
    New-Item -ItemType Directory -Force -Path $keyDirectory | Out-Null
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = [Convert]::ToBase64String($bytes)
    $env:TRACKSTUDY_STORE_PASS = $password
    try {
        & $keytool -genkeypair -keystore $keyPath -storetype PKCS12 -storepass:env TRACKSTUDY_STORE_PASS -keypass:env TRACKSTUDY_STORE_PASS -alias trackstudy -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=TrackStudy Personal Release'
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the Android signing key.' }
        [IO.File]::WriteAllText($signingFile, "storeFile=../signing/trackstudy-release.p12`nstorePassword=$password`nkeyPassword=$password`nkeyAlias=trackstudy`n")
    } finally { Remove-Item Env:TRACKSTUDY_STORE_PASS -ErrorAction SilentlyContinue }
    Write-Output 'Created a persistent, ignored personal signing key. Back up android/signing and android/key.properties securely for future APK updates.'
}
Push-Location $projectRoot
try {
    $mode = $Configuration.ToLowerInvariant()
    & "$PSScriptRoot\flutter.ps1" build apk "--$mode"
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed; no APK was packaged.' }
    $source = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-$mode.apk"
    if (!(Test-Path -LiteralPath $source)) { throw 'Built APK was not found.' }
    $distribution = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Force -Path $distribution | Out-Null
    $destination = Join-Path $distribution "TrackStudy-android-$mode.apk"
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Output "Android APK: $destination"
} finally { Pop-Location }
