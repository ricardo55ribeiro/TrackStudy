import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:trackstudy/application/sync_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/platform/android_background_sync.dart';
import 'package:trackstudy/sync/android_sync_session.dart';
import 'package:trackstudy/sync/auth_service.dart';
import 'package:trackstudy/sync/sync_gate.dart';
import 'package:trackstudy/sync/sync_gateway.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'package:workmanager/workmanager.dart';
import 'support/sync_fakes.dart';

const config = SupabaseConfiguration(
  url: project,
  publishableKey: 'sb_publishable_fixture',
);
const setting = AndroidBackgroundSync.preferenceKey;

void main() {
  late Directory directory;
  late LocalStudyRepository repository;
  late SyncStore store;
  late MemorySession storage;
  late RecordingWorkmanager work;
  late String path;
  var closedClients = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('trackstudy-worker-');
    path = '${directory.path}/trackstudy.sqlite';
    repository = LocalStudyRepository(
      StudyDatabase(sqlite3.open(path)),
      location: path,
    );
    store = SyncStore(repository.database)..bind(account, project);
    storage = MemorySession(jsonEncode(sessionFixture()));
    work = RecordingWorkmanager();
    closedClients = 0;
  });
  tearDown(() async {
    repository.close();
    await directory.delete(recursive: true);
  });

  Future<bool> run(
    MockClientHandler serve, {
    bool Function()? active,
    SupabaseConfiguration configuration = config,
    String? location,
  }) => runAndroidBackgroundSync(
    location ?? path,
    configuration,
    storage,
    active: active ?? () => true,
    createHttpClient: () => ClosingClient(serve, () => closedClients++),
  );

  test('startup and toggles reconcile one connected hourly request', () async {
    final scheduler = AndroidBackgroundSync(store, config, work: work);
    expect(scheduler.enabled(account), isFalse);
    await scheduler.reconcile(account);
    expect(work.jobs, isEmpty);
    await scheduler.setEnabled(true, account);
    await AndroidBackgroundSync(store, config, work: work).reconcile(account);
    expect(work.jobs, {AndroidBackgroundSync.taskName});
    expect(work.frequency, const Duration(hours: 1));
    expect(work.network, NetworkType.connected);
    expect(work.policy, ExistingPeriodicWorkPolicy.keep);
    expect(scheduler.enabled(account), isTrue);
    await scheduler.setEnabled(false, account);
    expect(work.jobs, isEmpty);
    await scheduler.reconcile(account);
    expect(work.jobs, isEmpty);
  });

  test('missing config, sign-out and account changes disable work', () async {
    final scheduler = AndroidBackgroundSync(store, config, work: work);
    final localOnly = AndroidBackgroundSync(
      store,
      const SupabaseConfiguration(),
      work: work,
    );
    await localOnly.setEnabled(true, account);
    await scheduler.setEnabled(true, null);
    await scheduler.setEnabled(true, other);
    expect(work.jobs, isEmpty);

    await scheduler.setEnabled(true, account);
    await scheduler.reconcile(other);
    await scheduler.reconcile(account);
    expect(work.jobs, isEmpty);

    final auth = FakeAuth()..user = const SyncAccount(account, 'a@example.com');
    final sync = SyncController(
      store: store,
      project: project,
      configured: true,
      backgroundSync: scheduler,
      backup: () async {},
    )..connect(auth, FakeCloud());
    try {
      await sync.setBackgroundSync(true);
      expect(work.jobs, isNotEmpty);
      await sync.signOut();
      expect(work.jobs, isEmpty);
      expect(store.meta(setting), '');
      expect(sync.account, isNull);
    } finally {
      sync.dispose();
      await auth.events.close();
    }
  });

  test(
    'unavailable database, wrong binding and missing session skip cloud',
    () async {
      store.setMeta(setting, '$account:fixture');
      var requests = 0;
      Future<Response> unexpected(Request request) async {
        requests++;
        throw StateError('Unexpected request');
      }

      final missing = '${directory.path}/missing.sqlite';
      await expectLater(
        run(unexpected, location: missing),
        throwsA(isA<SqliteException>()),
      );
      expect(File(missing).existsSync(), isFalse);
      final empty = '${directory.path}/empty.sqlite';
      sqlite3.open(empty).close();
      await expectLater(run(unexpected, location: empty), throwsStateError);
      final unopened = sqlite3.open(empty, mode: OpenMode.readOnly);
      try {
        expect(unopened.select('SELECT name FROM sqlite_master'), isEmpty);
      } finally {
        unopened.close();
      }
      await run(unexpected, configuration: const SupabaseConfiguration());
      await run(
        unexpected,
        configuration: const SupabaseConfiguration(
          url: 'https://other.example.com',
          publishableKey: 'sb_publishable_fixture',
        ),
      );
      storage.saved = jsonEncode(sessionFixture(user: other));
      await run(unexpected);
      storage.saved = jsonEncode(
        sessionFixture()
          ..['access_token'] = sessionFixture(user: other)['access_token'],
      );
      await run(unexpected);
      storage.saved = null;
      await run(unexpected);
      expect(requests, 0);
      expect(store.meta('last_sync'), '');
      expect(store.pending, greaterThan(0));
    },
  );

  test(
    'headless pass refreshes, pulls, uploads and closes its resources',
    () async {
      store.setMeta(setting, '$account:fixture');
      final localId = repository.addTodoTopic('Local pending topic');
      final remote = LocalStudyRepository(
        StudyDatabase(sqlite3.openInMemory()),
      );
      addTearDown(remote.close);
      final remoteId = remote.addTodoTopic('Remote topic');
      final remoteRow = SyncStore(
        remote.database,
      ).pendingRows('todo_topics').single..['user_id'] = account;
      storage.saved = jsonEncode(sessionFixture(expired: true));
      final refreshed = sessionFixture(refresh: 'rotated-fixture-token');
      final uploaded = <Object?>[];
      var refreshes = 0;
      expect(
        await run((request) async {
          if (request.url.path == '/auth/v1/token') {
            refreshes++;
            expect(request.url.queryParameters['grant_type'], 'refresh_token');
            return jsonResponse(refreshed);
          }
          expect(
            request.headers['authorization'],
            'Bearer ${refreshed['access_token']}',
          );
          if (request.method == 'GET') {
            expect(request.url.queryParameters['user_id'], 'eq.$account');
            return jsonResponse(
              request.url.path.endsWith('/todo_topics') ? [remoteRow] : [],
            );
          }
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          final row = data['p_row'] as SyncRow;
          uploaded.add(row['id']);
          return jsonResponse(row..['user_id'] = account);
        }),
        isTrue,
      );
      expect(refreshes, 1);
      expect(
        jsonDecode(storage.saved!)['refresh_token'],
        'rotated-fixture-token',
      );
      expect(uploaded, contains(localId));
      expect(
        repository.db.select('SELECT title FROM todo_topics WHERE id = ?', [
          remoteId,
        ]).single['title'],
        'Remote topic',
      );
      expect(store.pending, 0);
      expect(store.meta('last_sync'), isNotEmpty);
      expect(store.meta('first_backup'), isNotEmpty);
      expect(
        directory.listSync().where(
          (file) => file.path.contains('.before-first-sync-'),
        ),
        hasLength(1),
      );
      expect(closedClients, 1);
      await SyncGate(
        '$path.sync-lock',
      ).run(() async {}, wait: Duration.zero, active: () => true);
    },
  );

  test(
    'network failure keeps pending data and limits immediate retries',
    () async {
      store.setMeta(setting, '$account:fixture');
      final pending = store.pending;
      Future<Response> offline(Request _) async =>
          throw const SocketException('offline');
      expect(await run(offline), isFalse);
      expect(await run(offline), isTrue);
      expect(store.pending, pending);
      expect(store.meta('last_sync'), '');
      expect(closedClients, 2);
    },
  );

  test('revoked refresh token never reaches PostgREST', () async {
    store.setMeta(setting, '$account:fixture');
    storage.saved = jsonEncode(sessionFixture(expired: true));
    final before = store.pending;
    var requests = 0;
    expect(
      await run((request) async {
        requests++;
        expect(request.url.path, '/auth/v1/token');
        return jsonResponse({
          'code': 'refresh_token_not_found',
          'msg': 'Revoked',
        }, 400);
      }),
      isTrue,
    );
    expect(requests, 1);
    expect(store.pending, before);
    expect(store.meta('last_sync'), '');
  });

  test('sign-out invalidates a worker response and drains the gate', () async {
    store.setMeta(setting, '$account:fixture');
    final waiting = Completer<void>();
    final response = Completer<Response>();
    var requests = 0;
    final worker = run((_) {
      requests++;
      waiting.complete();
      return response.future;
    });
    await waiting.future;
    final gate = SyncGate('$path.sync-lock');
    await expectLater(
      gate.run(() async {}, wait: Duration.zero, active: () => true),
      throwsA(isA<SyncBusy>()),
    );
    final topic = repository.addTodoTopic('Edit while worker is active');
    final pending = store.pending;
    final foreground = AndroidSyncSession(
      store: store,
      gate: gate,
      configuration: config,
      storage: storage,
      createHttpClient: () => MockClient((_) async => Response('', 204)),
    );
    addTearDown(foreground.dispose);
    final signingOut = foreground.signOut();
    expect(store.meta(AndroidSyncSession.signingOutKey), '1');
    expect(storage.saved, isNotNull);
    response.complete(jsonResponse([]));
    await worker;
    await signingOut;
    expect(storage.saved, isNull);
    expect(requests, 1);
    expect(store.pending, pending);
    expect(store.pendingRows('todo_topics').single['id'], topic);
    expect(store.meta('initial_sync'), '');
    expect(store.meta('last_sync'), '');
    await gate.run(() async {}, wait: Duration.zero, active: () => true);
  });

  test('a killed isolate releases the SQLite gate', () async {
    final entered = ReceivePort();
    final ended = ReceivePort();
    final gate = SyncGate('$path.sync-lock');
    final worker = await Isolate.spawn(holdGate, (
      gate.path,
      entered.sendPort,
    ), onExit: ended.sendPort);
    try {
      await entered.first;
      await expectLater(
        gate.run(() async {}, wait: Duration.zero, active: () => true),
        throwsA(isA<SyncBusy>()),
      );
      worker.kill(priority: Isolate.immediate);
      await ended.first;
      await gate.run(
        () async {},
        wait: const Duration(seconds: 2),
        active: () => true,
      );
    } finally {
      worker.kill(priority: Isolate.immediate);
      entered.close();
      ended.close();
    }
  });
}

Future<void> holdGate((String, SendPort) args) => SyncGate(args.$1).run(
  () async {
    final hold = ReceivePort();
    args.$2.send(null);
    await hold.first;
  },
  wait: Duration.zero,
  active: () => true,
);

Map<String, dynamic> sessionFixture({
  String user = account,
  bool expired = false,
  String refresh = 'fixture-refresh-token',
}) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).split('=').first;
  final expiry = DateTime.now().add(Duration(hours: expired ? -1 : 1));
  final payload = segment({
    'exp': expiry.millisecondsSinceEpoch ~/ 1000,
    'sub': user,
  });
  return {
    'access_token': '${segment({'alg': 'HS256'})}.$payload.fixture',
    'refresh_token': refresh,
    'token_type': 'bearer',
    'user': {
      'id': user,
      'email': 'a@example.com',
      'app_metadata': {},
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
    },
  };
}

Response jsonResponse(Object body, [int status = 200]) => Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class MemorySession extends LocalStorage {
  String? saved;
  MemorySession(this.saved);
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> accessToken() async => saved;
  @override
  Future<bool> hasAccessToken() async => saved != null;
  @override
  Future<void> persistSession(String persistSessionString) async =>
      saved = persistSessionString;
  @override
  Future<void> removePersistedSession() async => saved = null;
}

class ClosingClient extends MockClient {
  final void Function() onClose;
  ClosingClient(super.fn, this.onClose);
  @override
  void close() {
    onClose();
    super.close();
  }
}

class RecordingWorkmanager implements Workmanager {
  final jobs = <String>{};
  Duration? frequency;
  NetworkType? network;
  ExistingPeriodicWorkPolicy? policy;
  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    bool isInDebugMode = false,
  }) async {}
  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {
    this.frequency = frequency;
    network = constraints?.networkType;
    policy = existingWorkPolicy;
    jobs.add(uniqueName);
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async =>
      jobs.remove(uniqueName);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
