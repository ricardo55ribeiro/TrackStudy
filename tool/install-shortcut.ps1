# Run from the extracted release directory. No administrator access required.
$ErrorActionPreference = 'Stop'
try {
    $executable = Join-Path $PSScriptRoot 'trackstudy.exe'
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "trackstudy.exe could not be found in '$PSScriptRoot'. Extract the complete TrackStudy ZIP and keep this installer beside trackstudy.exe."
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop) -or !(Test-Path -LiteralPath $desktop -PathType Container)) {
        throw 'Windows could not locate your Desktop folder. Check that your Desktop is available and try again.'
    }
    $shortcutPath = Join-Path $desktop 'TrackStudy.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = "$executable,0"
    $shortcut.Arguments = ''
    $shortcut.Hotkey = ''
    $shortcut.WindowStyle = 1
    $shortcut.Description = 'TrackStudy weekly execution tracker'
    $shortcut.Save()
    Write-Output 'TrackStudy shortcut created on Desktop.'
    Write-Output $shortcutPath
} catch {
    [Console]::Error.WriteLine("Could not create the TrackStudy shortcut: $($_.Exception.Message)")
    exit 1
}
