import 'dart:io';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'application/study_controller.dart';
import 'application/sync_controller.dart';
import 'sync/android_sync_session.dart';
import 'sync/auth_service.dart';
import 'sync/supabase_gateway.dart';
import 'sync/sync_gateway.dart';
import 'sync/sync_gate.dart';
import 'sync/sync_store.dart';
import 'data/database.dart';
import 'data/installation_data.dart';
import 'data/local_repository.dart';
import 'presentation/app.dart';
import 'platform/windows_background.dart';
import 'platform/android_background_sync.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final override = arguments
        .where((arg) => arg.startsWith('--data-dir='))
        .firstOrNull;
    final location = override == null
        ? await installationDatabasePath()
        : p.join(override.substring('--data-dir='.length), 'trackstudy.sqlite');
    await File(location).parent.create(recursive: true);
    final repository = LocalStudyRepository(
      StudyDatabase(sqlite3.open(location)),
      location: location,
    );
    const config = SupabaseConfiguration();
    // Explicit test/demo directories must never reuse a real installation's
    // secure session or send their fixture records to that account's cloud.
    final cloudEnabled = override == null && config.configured;
    final store = SyncStore(repository.database);
    final sync = SyncController(
      store: store,
      project: config.url,
      configured: cloudEnabled,
      watchLifecycle: true,
      backgroundSync: Platform.isAndroid && override == null
          ? AndroidBackgroundSync(store, config)
          : null,
      backup: () => backupBeforeFirstSync(repository),
    );
    final background = WindowsBackground();
    if (Platform.isWindows) await background.initialize(repository, sync);
    runApp(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repository),
          backgroundProvider.overrideWith((ref) => background),
          syncProvider.overrideWith((ref) {
            sync.onApplied = () => ref.read(studyProvider).refresh();
            return sync;
          }),
        ],
        child: const TrackStudyApp(),
      ),
    );
    if (cloudEnabled) {
      unawaited(_initializeSync(sync, config, location));
    } else if (sync.backgroundSync != null) {
      unawaited(sync.reconcileBackgroundSync());
    }
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 520,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Your data could not be opened',
                      style: TextStyle(fontSize: 24),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'TrackStudy has not reset or replaced your database. Check available disk space and folder permissions, then retry.',
                    ),
                    const SizedBox(height: 16),
                    SelectableText('$error'),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => main(arguments),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _initializeSync(
  SyncController sync,
  SupabaseConfiguration config,
  String location,
) async {
  try {
    final storage = SecureSessionStorage.forProject(config.url);
    if (Platform.isAndroid) {
      final session = AndroidSyncSession(
        store: sync.store!,
        gate: SyncGate('$location.sync-lock'),
        configuration: config,
        storage: storage,
      );
      try {
        await session.restore();
        sync.connect(session, session.gateway);
      } catch (_) {
        await session.dispose();
        rethrow;
      }
      return;
    }
    await Supabase.initialize(
      url: config.url,
      publishableKey: config.publishableKey,
      debug: false,
      authOptions: FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: storage,
      ),
    );
    final client = Supabase.instance.client;
    sync.connect(SupabaseSyncAuth(client), SupabaseSyncGateway(client));
  } catch (_) {
    sync.unavailable();
  }
}
