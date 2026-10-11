import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/repository.dart';
import '../application/sync_controller.dart';

final backgroundProvider = ChangeNotifierProvider<WindowsBackground>(
  (ref) => WindowsBackground(),
);

/// The native runner owns the tray and user-level startup entry. SQLite stores
/// only this installation's choices. No new synchronization mechanism is used.
class WindowsBackground extends ChangeNotifier {
  static const channel = MethodChannel('dev.trackstudy/background');
  StudyRepository? _repository;
  bool available = false, background = false, startup = false, busy = false;
  String? error;
  Future<void> initialize(
    StudyRepository repository,
    SyncController sync,
  ) async {
    _repository = repository;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sync') await sync.sync(manual: true);
    });
    background = repository.preference('windows.background', 'false') == 'true';
    startup = repository.preference('windows.startup', 'false') == 'true';
    try {
      await _apply(background, startup);
      available = true;
      sync.setWindowsBackground(background);
    } catch (_) {
      error =
          'Windows background settings could not be applied. Retry in Settings.';
    }
    notifyListeners();
  }

  Future<void> _apply(bool run, bool start) =>
      channel.invokeMethod('configure', {'background': run, 'startup': start});
  Future<void> configure(SyncController sync, {bool? run, bool? start}) async {
    if (busy || _repository == null) return;
    busy = true;
    error = null;
    notifyListeners();
    final nextRun = run ?? background, nextStart = start ?? startup;
    try {
      await _apply(nextRun, nextStart);
      _repository!.setPreference('windows.background', '$nextRun');
      _repository!.setPreference('windows.startup', '$nextStart');
      background = nextRun;
      startup = nextStart;
      available = true;
      sync.setWindowsBackground(background);
    } catch (_) {
      try {
        await _apply(background, startup);
      } catch (_) {
        /* Report the failure below; never change local choices. */
      }
      error =
          'Could not apply Windows settings. Your previous choices are retained.';
    }
    busy = false;
    notifyListeners();
  }

  @override
  void dispose() {
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
