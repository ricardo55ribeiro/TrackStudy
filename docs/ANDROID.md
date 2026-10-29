# TrackStudy on Android

Android 7.0 (API 24) or newer is supported. The application ID is `dev.trackstudy.trackstudy`. Windows and Android share the same tracking rules, SQLite storage, journal, planning features and optional sync engine.

## Build

Install Flutter 3.47.5, Android SDK platform 36 and a compatible JDK (JDK 21 is used by this project). Accept the Android SDK licenses. The build uses NDK 28.2.13676358; Gradle can download missing SDK components. The PowerShell helper detects standard Windows Android Studio/SDK locations, or uses `JAVA_HOME` and `ANDROID_HOME`.

From the project root:

```powershell
./tool/flutter.ps1 pub get
./tool/package-android.ps1
```

Output: `dist/TrackStudy-android-release.apk`. The helper reads optional public Supabase configuration from the ignored `.env.local`; see [Supabase setup](SUPABASE.md).

On first use, the helper creates a persistent personal release key in `android/signing/trackstudy-release.p12` and credentials in `android/key.properties`. Both are ignored by Git. **Back up both privately**: later updates require the same key. An existing key is reused, and an orphaned key is not overwritten. Direct `flutter build apk --release` requires the signing configuration first; a release is never silently signed with the debug key.

## Install and update

Copy the signed APK to your phone and open it in Files. If prompted, allow that app to install APKs, then choose Install or Update. For updates, **do not uninstall TrackStudy or clear its storage**: that would remove the local database and unsynchronized work. Debug builds use a different signing identity and are for test devices.

On a fresh installation, sign in to the same Supabase project/account before entering data if you want to adopt an existing cloud dataset. Settings shows sync status and pending changes. Android may suspend background work, so reopen/resume TrackStudy to allow uploads and downloads to finish.

## Data and backup

SQLite is stored in the app's private support directory; **Settings → Data** shows the path. Export JSON and Restore backup use Android's system document picker. No broad storage permission is needed. Local data and exported JSON are plaintext; authentication sessions use platform secure storage.

Automatic OS backup/device transfer is disabled. Use Supabase or explicit JSON exports to transfer data, and retain private copies of backups and release signing material.

## Native tests

Use a dedicated emulator or test device, not your everyday installation. The debug test runner may replace an existing release installation because its certificate differs.

```powershell
./tool/flutter.ps1 devices
./tool/flutter.ps1 test integration_test/android_test.dart --device-id=<test-device-id>
```

Tests use fixture sessions/databases and a simulated second client/cloud. They do not sign into a real Supabase account. Run test/build commands sequentially in one checkout.
