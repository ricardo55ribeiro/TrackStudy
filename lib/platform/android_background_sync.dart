import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';
import '../data/database.dart';
import '../data/installation_data.dart';
import '../data/local_repository.dart';
import '../sync/android_sync_session.dart';
import '../sync/auth_service.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_gate.dart';
import '../sync/sync_gateway.dart';
import '../sync/sync_store.dart';

class AndroidBackgroundSync {
  static const taskName = 'dev.trackstudy.hourly-sync';
  static const preferenceKey = 'android_background_sync';
  static const interval = Duration(hours: 1);
  static const _retryKey = 'android_background_retry_after';
  final SyncStore _store;
  final SupabaseConfiguration _config;
  final Workmanager _work;
  Future<void> _queue = Future.value();
  bool _initialized = false;

  AndroidBackgroundSync(this._store, this._config, {Workmanager? work})
    : _work = work ?? Workmanager();

  bool canEnable(String? account) =>
      _config.configured &&
      account != null &&
      _store.meta('account') == account &&
      _store.meta('project') == _config.url &&
      _store.meta(AndroidSyncSession.signingOutKey).isEmpty;

  bool enabled(String? account) =>
      canEnable(account) && _store.meta(preferenceKey).startsWith('$account:');

  Future<void> setEnabled(bool value, String? account) async {
    if (value && !canEnable(account)) return;
    final preference = value ? '$account:${const Uuid().v4()}' : '';
    _store.database.transaction(() {
      _store.setMeta(preferenceKey, preference);
      _store.setMeta(_retryKey, '');
    });
    try {
      await reconcile(account);
    } catch (_) {
      if (value && _store.meta(preferenceKey) == preference) {
        _store.setMeta(preferenceKey, '');
      }
      rethrow;
    }
  }

  Future<void> reconcile(String? account) {
    if (!enabled(account) && _store.meta(preferenceKey).isNotEmpty) {
      _store.setMeta(preferenceKey, '');
    }
    final operation = _queue.then((_) async {
      if (!enabled(account)) {
        await _work.cancelByUniqueName(taskName);
        return;
      }
      if (!_initialized) {
        await _work.initialize(trackStudyBackgroundDispatcher);
        _initialized = true;
      }
      await _work.registerPeriodicTask(
        taskName,
        taskName,
        frequency: interval,
        initialDelay: interval,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 5),
      );
    });
    // Let callers report this error while keeping the scheduling queue usable
    _queue = operation.then((_) {}, onError: (Object _) {});
    return operation;
  }
}

@pragma('vm:entry-point')
void trackStudyBackgroundDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, _) {
    if (task != AndroidBackgroundSync.taskName) return Future.value(true);
    final run = _BackgroundRun();
    _running = run;
    return run.result.whenComplete(() => _running = null);
  }, onTaskStopped: (_, _) async => _running?.stop());
}

_BackgroundRun? _running;

class _BackgroundRun {
  final _stopwatch = Stopwatch()..start();
  static const _budget = Duration(seconds: 90);
  bool _stopped = false;
  AndroidSyncSession? _session;
  late final result = _run();

  Future<void> stop() async {
    _stopped = true;
    _session?.abortRequests();
    await result;
  }

  Future<bool> _run() async {
    const config = SupabaseConfiguration();
    if (!Platform.isAndroid || !config.configured) return true;
    final timer = Timer(_budget, () => _session?.abortRequests());
    try {
      final path = await installationDatabasePath();
      return await runAndroidBackgroundSync(
        path,
        config,
        SecureSessionStorage.forProject(config.url),
        active: () => !_stopped && _stopwatch.elapsed < _budget,
        onSession: (session) => _session = session,
      );
    } catch (_) {
      return true;
    } finally {
      timer.cancel();
    }
  }
}

Future<bool> runAndroidBackgroundSync(
  String path,
  SupabaseConfiguration config,
  LocalStorage storage, {
  required bool Function() active,
  void Function(AndroidSyncSession)? onSession,
  Client Function()? createHttpClient,
}) async {
  if (!config.configured || !active()) return true;
  final database = StudyDatabase.openExisting(path);
  try {
    final repository = LocalStudyRepository(
      database,
      location: path,
      seed: false,
    );
    final store = SyncStore(database);
    final account = store.meta('account');
    final permission = store.meta(AndroidBackgroundSync.preferenceKey);
    bool allowed() =>
        active() &&
        store.meta(AndroidBackgroundSync.preferenceKey) == permission &&
        store.meta(AndroidSyncSession.signingOutKey).isEmpty;
    if (repository.preference('initialized', '') != 'yes' ||
        account.isEmpty ||
        store.meta('project') != config.url ||
        !permission.startsWith('$account:') ||
        !allowed()) {
      return true;
    }
    final session = AndroidSyncSession(
      configuration: config,
      store: store,
      gate: SyncGate('$path.sync-lock'),
      storage: storage,
      headless: true,
      createHttpClient: createHttpClient,
    );
    try {
      onSession?.call(session);
      await session.withSession(account, allowed, () async {
        final engine = SyncEngine(
          store,
          session.gateway,
          backup: () => backupBeforeFirstSync(repository),
        );
        await engine.synchronize(account, config.url, allowed);
      });
    } on SyncBusy {
      // The foreground pass already owns the dataset
    } on SyncCancelled {
      // WorkManager discards the result of a stopped worker
    } catch (error) {
      if (_retryable(error) && allowed()) {
        var retry = false;
        database.transaction(() {
          final now = DateTime.now().toUtc();
          final retryAfter = DateTime.tryParse(
            store.meta(AndroidBackgroundSync._retryKey),
          );
          if (allowed() && (retryAfter == null || !now.isBefore(retryAfter))) {
            store.setMeta(
              AndroidBackgroundSync._retryKey,
              now.add(AndroidBackgroundSync.interval).toIso8601String(),
            );
            retry = true;
          }
        });
        return !retry;
      }
    } finally {
      await session.dispose();
    }
    // Only SyncEngine records a successful sync. Other outcomes wait for the
    // next periodic run instead of requesting an immediate retry
    return true;
  } finally {
    database.close();
  }
}

bool _retryable(Object error) {
  if (error is PostgrestException) {
    final code = int.tryParse(error.code ?? '') ?? 0;
    return code >= 500 && code < 600;
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is ClientException ||
      error is AuthRetryableFetchException;
}
