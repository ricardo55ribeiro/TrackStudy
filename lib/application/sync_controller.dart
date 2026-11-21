import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../platform/android_background_sync.dart';
import '../sync/auth_service.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_gate.dart';
import '../sync/sync_gateway.dart';
import '../sync/sync_store.dart';

final syncProvider = ChangeNotifierProvider<SyncController>(
  (ref) => SyncController(),
);

class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  final SyncStore? store;
  final String project;
  final bool configured;
  final Future<void> Function()? backup;
  final AndroidBackgroundSync? backgroundSync;
  SyncAuth? _auth;
  SyncEngine? _engine;
  ConflictArchiveGateway? _archive;
  StreamSubscription<SyncAccount?>? _subscription;
  StreamSubscription<dynamic>? _localSubscription;
  Timer? _debounce, _retry, _backoff;
  bool syncing = false,
      authenticating = false,
      archiving = false,
      signingOut = false,
      changingBackgroundSync = false,
      _disposed = false;
  String? error;
  String? backgroundSyncError;
  int _generation = 0;
  String? _accountId;
  VoidCallback? onApplied;
  final bool watchLifecycle;
  final Duration debounceDelay, retryDelay, pollInterval;
  bool _windowsBackground = false;
  void setWindowsBackground(bool enabled) {
    _windowsBackground = enabled;
    if (_auth != null) _startPolling();
  }

  void _startPolling() {
    _retry?.cancel();
    _retry = Timer.periodic(
      _windowsBackground ? const Duration(seconds: 45) : pollInterval,
      (_) => sync(),
    );
  }

  SyncController({
    this.store,
    this.project = '',
    this.configured = false,
    this.backup,
    this.backgroundSync,
    this.watchLifecycle = false,
    this.debounceDelay = const Duration(seconds: 2),
    this.retryDelay = const Duration(seconds: 30),
    this.pollInterval = const Duration(minutes: 2),
  }) {
    if (watchLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
  }
  SyncAccount? get account => _auth?.account;
  bool get canSignIn => _auth != null && !authenticating && !signingOut;
  bool get backgroundSyncEnabled =>
      backgroundSync?.enabled(account?.id) ?? false;
  bool get canEnableBackgroundSync =>
      !signingOut &&
      !authenticating &&
      !changingBackgroundSync &&
      (backgroundSync?.canEnable(account?.id) ?? false);
  int get pending => store?.pending ?? 0;
  int get conflicts => store?.conflicts ?? 0;
  int get savedCopies => store?.savedCopies ?? 0;
  DateTime? get lastSync =>
      DateTime.tryParse(store?.meta('last_sync') ?? '')?.toLocal();
  String get status => syncing
      ? 'Syncing…'
      : account == null
      ? 'Local only'
      : error != null
      ? 'Offline / sync pending'
      : pending > 0
      ? 'Connected · pending changes'
      : 'Connected';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void unavailable() {
    error =
        'Secure sign-in could not initialize. Local data is available. Restart to retry.';
    _notify();
  }

  Future<void> reconcileBackgroundSync() async {
    if (backgroundSync == null) return;
    try {
      await backgroundSync!.reconcile(account?.id);
      if (backgroundSyncError != null) {
        backgroundSyncError = null;
        _notify();
      }
    } catch (_) {
      backgroundSyncError = 'Could not update Android background sync.';
      _notify();
    }
  }

  Future<void> setBackgroundSync(bool enabled) async {
    if (!canEnableBackgroundSync) return;
    changingBackgroundSync = true;
    backgroundSyncError = null;
    _notify();
    try {
      await backgroundSync!.setEnabled(enabled, account?.id);
    } catch (_) {
      backgroundSyncError = 'Could not update Android background sync.';
    } finally {
      changingBackgroundSync = false;
      _notify();
    }
  }

  void connect(SyncAuth auth, SyncGateway gateway) {
    if (_disposed) return;
    _auth = auth;
    _engine = SyncEngine(store!, gateway, backup: backup!);
    _archive = gateway is ConflictArchiveGateway
        ? gateway as ConflictArchiveGateway
        : null;
    _localSubscription = store!.database.handle.updates.listen((event) {
      if (syncTables.contains(event.tableName)) localChanged();
    });
    _startPolling();
    _subscription = auth.changes.listen(
      (_) => _authChanged(),
      onError: (Object _) {
        error =
            'Connection unavailable. Local changes are safe and will retry.';
        _notify();
      },
    );
    _authChanged(reconcile: true);
  }

  void _authChanged({bool reconcile = false}) {
    if (_accountId != account?.id) {
      _generation++;
      _accountId = account?.id;
      reconcile = true;
    }
    if (reconcile && !signingOut) unawaited(reconcileBackgroundSync());
    _notify();
    if (account != null) unawaited(sync(manual: true));
  }

  Future<void> signIn(String email, String password) async {
    if (!canSignIn) return;
    authenticating = true;
    error = null;
    _notify();
    try {
      await _auth!.signIn(email, password);
      final user = account;
      if (user != null && _auth is! CoordinatedSyncAuth) {
        store!.bind(user.id, project);
      }
      await sync(manual: true);
    } catch (e) {
      if (e is FormatException && account != null) await _auth!.signOut();
      error = e is FormatException
          ? e.message
          : 'Sign-in failed. Check your email, password and connection.';
    } finally {
      authenticating = false;
      _notify();
    }
  }

  Future<void> signOut() async {
    if (signingOut) return;
    signingOut = true;
    _generation++;
    _debounce?.cancel();
    _backoff?.cancel();
    _notify();
    final stoppingWork = backgroundSync
        ?.setEnabled(false, account?.id)
        .then(
          (_) {
            backgroundSyncError = null;
          },
          onError: (Object _) {
            backgroundSyncError = 'Could not cancel Android background sync.';
          },
        );
    try {
      await _auth?.signOut();
      error = null;
    } catch (_) {
      error = 'Could not clear the saved session. Please retry sign out.';
    } finally {
      await stoppingWork;
      signingOut = false;
      _notify();
    }
  }

  void localChanged() {
    if (_disposed || account == null || pending == 0) return;
    if (!syncing && !(_backoff?.isActive ?? false)) {
      _debounce?.cancel();
      _debounce = Timer(debounceDelay, () => sync());
    }
    _notify();
  }

  Future<int> archiveVerifiedEntryCopies() async {
    final user = account;
    if (user == null ||
        signingOut ||
        syncing ||
        archiving ||
        _archive == null) {
      return 0;
    }
    final generation = _generation;
    bool active() => !_disposed && !signingOut && generation == _generation;
    await sync(manual: true);
    if (error != null || syncing || generation != _generation || _disposed) {
      return 0;
    }
    archiving = true;
    _notify();
    var count = 0;
    try {
      await _withSession(user.id, active, () async {
        for (final copy in store!.activeEntryCopies) {
          if (!active()) break;
          final entry = store!.entryForArchival(copy);
          if (entry == null) continue;
          final verified = await _archive!.archiveEntryCopy(
            entry,
            copy['version'] as int,
            copy['writer'] as String,
          );
          if (!active()) break;
          if (verified && store!.archiveEntryCopy(copy, entry)) count++;
        }
      });
    } on SyncCancelled {
      // Keep any evidence that has not been verified
    } catch (_) {
      error =
          'Could not verify conflict copies. Evidence is retained; retry when connected.';
    } finally {
      archiving = false;
      _notify();
      localChanged();
    }
    return count;
  }

  Future<void> _withSession(
    String accountId,
    bool Function() active,
    Future<void> Function() action,
  ) {
    final auth = _auth;
    return auth is CoordinatedSyncAuth
        ? auth.withSession(accountId, active, action)
        : action();
  }

  Future<void> sync({bool manual = false}) async {
    final user = account;
    if (_disposed ||
        user == null ||
        _engine == null ||
        signingOut ||
        syncing ||
        archiving) {
      return;
    }
    if (!manual && (_backoff?.isActive ?? false)) return;
    _backoff?.cancel();
    _debounce?.cancel();
    final generation = _generation;
    bool active() =>
        !_disposed &&
        !signingOut &&
        generation == _generation &&
        account?.id == user.id;
    syncing = true;
    error = null;
    _notify();
    var busy = false;
    try {
      await _withSession(
        user.id,
        active,
        () => _engine!.synchronize(user.id, project, active),
      );
    } on SyncBusy {
      busy = true;
    } on SyncCancelled {
      // Sign-out invalidates pending responses, while local dirty flags remain.
    } on FormatException catch (e) {
      error = e.message;
    } on PostgrestException catch (e) {
      error = ['42P01', '42703', 'PGRST202', 'PGRST205'].contains(e.code)
          ? 'Cloud schema is not ready. Apply the TrackStudy SQL migrations, then sync again.'
          : 'Last sync failed. Local changes are safe. Check the cloud schema and access policies, then retry.';
    } on SocketException {
      error = 'Offline. Local changes are safe and will retry.';
    } on TimeoutException {
      error = 'Connection timed out. Local changes are safe and will retry.';
    } catch (_) {
      error = 'Last sync failed. Local changes are safe; retry when connected.';
    } finally {
      syncing = false;
      if (!_disposed) {
        onApplied?.call();
        _notify();
        if (account != null && generation == _generation) {
          if (error != null) {
            _backoff = Timer(retryDelay, () => sync());
          } else if (busy || pending > 0) {
            // A local edit may have arrived after this pass read its upload
            // batch. Never leave it waiting for the periodic poll.
            _debounce = Timer(debounceDelay, () => sync());
          }
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _subscription?.cancel();
    _localSubscription?.cancel();
    _debounce?.cancel();
    _retry?.cancel();
    _backoff?.cancel();
    if (watchLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
