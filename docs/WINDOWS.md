# TrackStudy on Windows

## Run the portable build

Download the `TrackStudy-windows-x64` artifact from a successful Windows workflow run while the artifact is available. The workflow sets a seven-day retention period. Sign in to GitHub to download it. The artifact contains the portable app ZIP. [GitHub Actions](https://github.com/ricardo55ribeiro/TrackStudy/actions)

Extract the entire app ZIP to a permanent folder. Run `trackstudy.exe` and keep its DLLs and `data` folder alongside it. To create or update a desktop shortcut, run **Create Desktop Shortcut.bat** from that folder. The script supports redirected desktops and paths with spaces. It needs no administrator access. Run it again if you move the folder.

Before replacing the extracted files, export a JSON backup and quit the running app. The database lives outside the app folder. [Data and backups](DATA.md)

## Build from source

Install Git, Flutter 3.47.5 (Dart 3.13.4) and Visual Studio 2022 or Build Tools with **Desktop development with C++**, the Windows SDK and CMake. Enable Windows Developer Mode for plugin symlinks.

From the repository root in PowerShell, fetch dependencies and run the app.

```powershell
./tool/flutter.ps1 pub get
./tool/flutter.ps1 run -d windows
```

Run `./tool/package.ps1` to build `dist/TrackStudy-windows-x64.zip`. The Flutter wrapper can use a local SDK in `.tools/flutter` or Flutter on PATH. If you already have the extracted MSVC and SDK toolchain, the portable build script supports that setup. [Portable build script](../tool/build-portable.ps1)

## Tray and startup

TrackStudy opens maximized, including when you select **Open TrackStudy** in the tray. With **Run in background** enabled, closing the window hides it to the tray. Use **Quit** in the tray menu to exit. **Start with Windows** launches the app at sign-in and keeps it in the tray if background mode is also enabled.

## Local checks and demo data

Run build and test commands sequentially in one checkout.

```powershell
./tool/flutter.ps1 analyze
./tool/flutter.ps1 test
./tool/test-windows.ps1
./tool/test-windows.ps1 -SkipBuild -Autostart
```

The Windows integration tests use isolated databases and startup settings. To open a separate instance for demo data, pass `--data-dir` a new folder. An explicit data directory disables cloud sign-in and sync.

```powershell
./trackstudy.exe --data-dir=./trackstudy-demo
```

Test commands are also available for [Android native tests](ANDROID.md#native-tests) and [local database policy checks](SUPABASE.md#local-policy-checks).
