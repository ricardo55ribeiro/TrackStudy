import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/application/sync_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/sync/auth_service.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_gateway.dart';
import 'package:trackstudy/sync/sync_store.dart';

import 'support/sync_fakes.dart';

void main() {
  final week = Week.parse('2026-09-21');
  late LocalStudyRepository a, b;
  late SyncStore sa, sb;
  late FakeCloud cloud;
  var backups = 0;
  LocalStudyRepository fresh() =>
      LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  setUp(() {
    a = fresh();
    b = fresh();
    sa = SyncStore(a.database);
    sb = SyncStore(b.database);
    cloud = FakeCloud();
    backups = 0;
  });
  tearDown(() {
    a.close();
    b.close();
  });
  Future<void> sync(SyncStore store) => SyncEngine(
    store,
    cloud,
    backup: () async {
      backups++;
    },
  ).synchronize(account, project, () => true);
  WeeklyProgress research(LocalStudyRepository repo, [Week? selected]) => repo
      .loadWeek(selected ?? week, current: selected ?? week)
      .firstWhere((p) => p.config.name == 'Research');

  test('missing or secret configuration remains local only', () async {
    expect(const SupabaseConfiguration().configured, isFalse);
    expect(
      const SupabaseConfiguration(
        url: project,
        publishableKey: 'sb_secret_do_not_use',
      ).configured,
      isFalse,
    );
    expect(
      const SupabaseConfiguration(
        url: project,
        publishableKey: 'sb_publishable_test',
      ).configured,
      isTrue,
    );
    final controller = SyncController();
    await controller.sync(manual: true);
    expect(controller.status, 'Local only');
    expect(controller.canSignIn, isFalse);
    a.commit(research(a).goalId, 150, week);
    expect(research(a).total, 150);
    controller.dispose();
  });
  test('explicit archival requires a successful server verification', () async {
    final archiveCloud = ArchiveCloud();
    cloud = archiveCloud;
    a.commit(research(a).goalId, 150, week);
    await sync(sa);
    final entry = clone(cloud.tables['entries']!.values.single);
    a.database.handle.execute(
      'INSERT INTO sync_conflicts (table_name,record_id,version,writer,payload,saved_at) VALUES (?,?,?,?,?,?)',
      [
        'entries',
        entry['id'],
        entry['sync_version'],
        entry['sync_writer'],
        jsonEncode(entry),
        '2026-09-26T00:00:00Z',
      ],
    );
    final auth = FakeAuth()..user = const SyncAccount(account, 'a@example.com');
    final controller = SyncController(
      store: sa,
      project: project,
      configured: true,
      backup: () async {},
    );
    controller.connect(auth, archiveCloud);
    try {
      while (controller.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(await controller.archiveVerifiedEntryCopies(), 0);
      expect(sa.conflicts, 1);
      archiveCloud.verified = true;
      expect(await controller.archiveVerifiedEntryCopies(), 1);
      expect(sa.conflicts, 0);
      expect(sa.savedCopies, 1);
      expect(archiveCloud.archiveRequests, 2);
      expect(research(a).total, 150);
      expect(cloud.tables['entries']!.length, 1);
    } finally {
      controller.dispose();
      await auth.events.close();
    }
  });
  test(
    'archival retains evidence and rejects dirty, changed or other-writer entries',
    () async {
      final goal = research(a);
      a.commit(goal.goalId, 150, week);
      await sync(sa);
      final original = clone(cloud.tables['entries']!.values.single);
      a.undo(goal.goalId, week);
      await sync(sa);
      final db = a.database.handle;
      db.execute(
        'INSERT INTO sync_conflicts (table_name,record_id,version,writer,payload,saved_at) VALUES (?,?,?,?,?,?)',
        [
          'entries',
          original['id'],
          original['sync_version'],
          original['sync_writer'],
          jsonEncode(original),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      final copy = sa.activeEntryCopies.single;
      final verified = sa.entryForArchival(copy)!;
      expect(
        sa.entryForArchival({...copy, 'writer': 'another-installation'}),
        isNull,
      );
      a.setUndone(original['id'] as String, false, week);
      expect(sa.entryForArchival(copy), isNull);
      expect(sa.archiveEntryCopy(copy, verified), isFalse);
      await sync(sa);
      expect(
        sa.archiveEntryCopy(copy, verified),
        isFalse,
        reason: 'A changed entry cannot use stale verification',
      );
      final current = sa.entryForArchival(copy)!;
      final ledgerBefore = jsonEncode(
        db
            .select('SELECT * FROM entries')
            .map((r) => Map<String, dynamic>.from(r))
            .toList(),
      );
      expect(sa.archiveEntryCopy(copy, current), isTrue);
      expect(sa.conflicts, 0);
      final evidence = (jsonDecode(sa.exportConflicts()) as List).single as Map;
      expect(evidence['archived_at'], isNotNull);
      expect(evidence['payload'], jsonEncode(original));
      expect(
        jsonEncode(
          db
              .select('SELECT * FROM entries')
              .map((r) => Map<String, dynamic>.from(r))
              .toList(),
        ),
        ledgerBefore,
      );
    },
  );

  test(
    'v3 migration preserves dirty stamps, domain data and existing conflict evidence',
    () async {
      final goal = research(a);
      a.commit(goal.goalId, 150, week);
      await sync(sa);
      a.undo(goal.goalId, week);
      final raw = a.database.handle;
      final record = sa.pendingRows('entries').single;
      raw.execute(
        'INSERT INTO sync_conflicts (table_name,record_id,version,writer,payload,saved_at) VALUES (?,?,?,?,?,?)',
        [
          'entries',
          record['id'],
          record['sync_version'],
          record['sync_writer'],
          jsonEncode(record),
          '2026-09-26T00:00:00Z',
        ],
      );
      final before = jsonDecode(a.exportJson())['tables'];
      before['category_states'] = [];
      final pending = sa.pending;
      for (final table in syncTables) {
        for (final event in ['insert', 'update']) {
          raw.execute('DROP TRIGGER sync_${table}_$event');
          raw.execute(
            'CREATE TRIGGER sync_${table}_$event AFTER $event ON $table BEGIN SELECT 1; END',
          );
        }
      }
      raw.execute(
        'DROP TABLE category_states; DROP TABLE todo_tasks; DROP TABLE todo_topics; DROP TABLE schedule_blocks; DROP TABLE academic_events; ALTER TABLE journal DROP COLUMN answer; ALTER TABLE journal DROP COLUMN answered_at; ALTER TABLE sync_records DROP COLUMN history; ALTER TABLE sync_conflicts DROP COLUMN archived_at; PRAGMA user_version=3',
      );
      StudyDatabase(raw);
      expect(
        raw.select('PRAGMA user_version').first.values.first,
        StudyDatabase.version,
      );
      expect(jsonDecode(a.exportJson())['tables'], before);
      expect(sa.pending, pending);
      expect(sa.conflicts, 1);
      expect(sa.activeEntryCopies.single['payload'], jsonEncode(record));
      expect(
        sa.pendingRows('entries').single['sync_version'],
        record['sync_version'],
      );
      await sync(sa);
      expect(sa.pending, 0);
      expect(
        sa.conflicts,
        1,
        reason:
            'Migration does not erase historical evidence or create new conflicts',
      );
      expect(cloud.conflicts, isEmpty);
    },
  );
  test(
    'single device +1.5 upload pull undo and repeat never produce conflicts',
    () async {
      final goal = research(a);
      await sync(sa);
      a.commit(goal.goalId, 150, week);
      await sync(sa);
      await sync(sa);
      expect(cloud.tables['entries']!.length, 1);
      expect(sa.pending, 0);
      expect(sa.conflicts, 0);
      expect(cloud.conflicts, isEmpty);
      expect(research(a).total, 150);
      a.undo(goal.goalId, week);
      await sync(sa);
      expect(research(a).total, 0);
      expect(cloud.tables['entries']!.values.single['undone_at'], isNotNull);
      expect(
        sa.conflicts,
        0,
        reason: 'An older acknowledged version is an ancestor, not a conflict',
      );
      expect(cloud.conflicts, isEmpty);
      await sync(sa);
      expect(sa.conflicts, 0);
      expect(cloud.tables['entries']!.length, 1);
    },
  );
  test(
    'first upload preserves existing UUIDs, all five tables and historical targets',
    () async {
      final goal = research(a);
      a.commit(goal.goalId, 150, week);
      a.saveJournal(
        JournalEntry(
          id: const Uuid().v4(),
          createdAt: DateTime.now().toUtc().toIso8601String(),
          learned: 'Learned',
          question: 'Question',
          next: 'Next',
          experiment: const {'Hypothesis': 'Test'},
        ),
      );
      a.saveReview(WeeklyReview(week: week.key, wentWrong: 'Start earlier'));
      final original = jsonDecode(a.exportJson())['tables'] as Map;
      await sync(sa);
      expect(backups, 1);
      expect(sa.pending, 0);
      for (final table in syncTables) {
        expect(
          cloud.tables[table]!.keys.toSet(),
          (original[table] as List).map((r) => r['id']).toSet(),
        );
      }
      expect(research(a).total, 150);
      expect(research(a).config.target, 800);
      await sync(sa);
      expect(backups, 1);
      expect(cloud.tables['entries']!.length, 1);
    },
  );
  test(
    'own writes and sequential device edits stay conflict-free across all tables',
    () async {
      final goal = research(a);
      a.commit(goal.goalId, 150, week);
      final journalId = const Uuid().v4();
      a.saveJournal(
        JournalEntry(
          id: journalId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          learned: 'First',
          question: '',
          next: '',
        ),
      );
      a.saveReview(WeeklyReview(week: week.key, wentWrong: 'First'));
      await sync(sa);
      for (final table in syncTables) {
        if (cloud.tables[table]!.isEmpty) continue;
        final row = cloud.tables[table]!.values.first;
        // Model server-maintained timestamps/revisions and a normalized own row.
        row['updated_at'] = '2026-09-26T12:00:00+00:00';
        row['revision'] = 47;
      }
      await sync(sa);
      a.saveCategory(
        goal.categoryId,
        const GoalConfig(
          name: 'Research',
          measurement: Measurement.continuous,
          unit: 'h',
          floor: 600,
          target: 1000,
          increment: 100,
          step: 25,
        ),
        week,
      );
      a.undo(goal.goalId, week);
      a.saveJournal(
        JournalEntry(
          id: journalId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          learned: 'Second',
          question: '',
          next: '',
        ),
      );
      a.saveReview(WeeklyReview(week: week.key, wentWrong: 'Second'));
      await sync(sa);
      await sync(sa);
      expect(sa.pending, 0);
      expect(sa.conflicts, 0);
      expect(cloud.conflicts, isEmpty);
      // Different writer is not sufficient: B first observes A, then edits.
      await sync(sb);
      b.saveReview(WeeklyReview(week: week.key, wentWrong: 'Third'));
      await sync(sb);
      await sync(sa);
      expect(a.review(week).wentWrong, 'Third');
      expect(sa.conflicts + sb.conflicts, 0);
      expect(cloud.conflicts, isEmpty);
      expect(cloud.tables['entries']!.length, 1);
    },
  );

  test(
    'same content from independent histories merges without conflict',
    () async {
      research(a);
      a.saveReview(WeeklyReview(week: week.key));
      await sync(sa);
      await sync(sb);
      a.saveReview(WeeklyReview(week: week.key, wentWrong: 'Same text'));
      b.saveReview(WeeklyReview(week: week.key, wentWrong: 'Same text'));
      await sync(sa);
      await sync(sb);
      await sync(sa);
      expect(sa.conflicts + sb.conflicts, 0);
      expect(cloud.conflicts, isEmpty);
      expect(sa.pending + sb.pending, 0);
    },
  );

  testWidgets(
    'automatic sync: startup debounce, changes during upload, offline retry and restart',
    (tester) async {
      final auth = FakeAuth()
        ..user = const SyncAccount(account, 'a@example.com');
      SyncController createController() {
        final result = SyncController(
          store: sa,
          project: project,
          configured: true,
          backup: () async {},
        );
        result.connect(auth, cloud);
        return result;
      }

      var controller = createController();
      try {
        await tester.pump(); // restored session starts a pass automatically
        expect(controller.lastSync, isNotNull);
        final goal = research(a);
        a.commit(goal.goalId, 150, week);
        expect(research(a).total, 150); // no network wait
        await tester.pump();
        expect(cloud.tables['entries'], isEmpty);
        await tester.pump(const Duration(seconds: 1));
        expect(cloud.tables['entries'], isEmpty);
        await tester.pump(const Duration(seconds: 1));
        expect(controller.error, isNull, reason: 'Automatic upload error');
        await tester.pump();
        expect(cloud.tables['entries']!.length, 1);
        expect(sa.pending, 0);
        expect(sa.conflicts, 0);
        controller.dispose();
        controller = createController();
        await tester.pump();
        expect(research(a).total, 150);
        a.undo(goal.goalId, week);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(cloud.tables['entries']!.values.single['undone_at'], isNotNull);
        expect(sa.conflicts, 0);
        cloud.offline = true;
        a.commit(goal.goalId, 200, week);
        expect(research(a).total, 200);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(controller.error, isNotNull);
        expect(sa.pending, greaterThan(0));
        final attempts = cloud.calls;
        // More offline writes coalesce into the scheduled retry, not a storm.
        a.commit(goal.goalId, 100, week);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(cloud.calls, attempts);
        cloud.offline = false;
        await tester.pump(const Duration(seconds: 30));
        expect(sa.pending, 0);
        expect(controller.error, isNull);
        expect(cloud.tables['entries']!.length, 3);
        // A new entry created after the entry batch was read needs another pass.
        var addedDuringUpload = false;
        cloud.duringUpload = (table, row) {
          if (table == 'entries' && !addedDuringUpload) {
            addedDuringUpload = true;
            a.commit(goal.goalId, 50, week);
          }
        };
        a.commit(goal.goalId, 100, week);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(sa.pending, 1);
        await tester.pump(const Duration(seconds: 2));
        expect(sa.pending, 0);
        expect(cloud.tables['entries']!.length, 5);
        expect(sa.conflicts, 0);
        expect(cloud.conflicts, isEmpty);
        final count = cloud.calls;
        await tester.pump(const Duration(seconds: 10));
        expect(
          cloud.calls,
          count,
          reason: 'Remote acknowledgments must not cause a sync loop',
        );
        await controller.sync(manual: true);
        await controller.sync(manual: true);
        expect(cloud.tables['entries']!.length, 5);
        expect(sa.conflicts, 0);
      } finally {
        controller.dispose();
        await auth.events.close();
      }
    },
  );

  testWidgets(
    'rapid changes coalesce and overlapping requests never start concurrent passes',
    (tester) async {
      final auth = FakeAuth()
        ..user = const SyncAccount(account, 'a@example.com');
      final controller = SyncController(
        store: sa,
        project: project,
        configured: true,
        backup: () async {},
      );
      controller.connect(auth, cloud);
      try {
        await tester.pump();
        final goal = research(a);
        a.commit(goal.goalId, 100, week);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        a.commit(goal.goalId, 50, week);
        await tester.pump();
        final gate = Completer<void>();
        cloud.duringPull = () => gate.future;
        final before = cloud.calls;
        await tester.pump(const Duration(seconds: 1));
        expect(cloud.calls, before);
        await tester.pump(const Duration(seconds: 1));
        expect(controller.syncing, isTrue);
        expect(cloud.calls, before + 1);
        await controller.sync(manual: true);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(cloud.calls, before + 1);
        gate.complete();
        await tester.pump();
        await tester.pump();
        expect(controller.error, isNull);
        expect(sa.pending, 0);
        expect(cloud.tables['entries']!.length, 2);
        expect(cloud.conflicts, isEmpty);
        expect(sa.conflicts, 0);
      } finally {
        controller.dispose();
        await auth.events.close();
      }
    },
  );
  test(
    'fresh device adopts cloud dataset without duplicating automatic categories',
    () async {
      a.commit(research(a).goalId, 1000, week);
      await sync(sa);
      research(b);
      await sync(sb);
      await sync(sb);
      expect(
        b.categories().map((c) => c.id).toSet(),
        a.categories().map((c) => c.id).toSet(),
      );
      expect(b.categories().length, 7);
      expect(cloud.tables['categories']!.length, 7);
      expect(research(b).total, 1000);
      expect(sb.pending, 0);
    },
  );
  test(
    'non-pristine existing local dataset merges rather than replacing data',
    () async {
      a.commit(research(a).goalId, 150, week);
      await sync(sa);
      final localGoal = research(b);
      b.commit(localGoal.goalId, 250, week);
      await sync(sb);
      expect(b.categories().length, 14);
      expect(b.entries(localGoal.goalId).single.amount, 250);
      expect(cloud.tables['entries']!.length, 2);
      expect(b.categories().any((c) => c.id == localGoal.categoryId), isTrue);
    },
  );
  test('offline changes remain durable and retry succeeds', () async {
    a.commit(research(a).goalId, 150, week);
    cloud.offline = true;
    await expectLater(sync(sa), throwsA(isA<SocketException>()));
    expect(research(a).total, 150);
    expect(sa.pending, greaterThan(0));
    cloud.offline = false;
    await sync(sa);
    expect(sa.pending, 0);
    expect(cloud.tables['entries']!.length, 1);
  });
  test(
    'interrupted upload after server commit retries without duplicate ledger events',
    () async {
      a.commit(research(a).goalId, 150, week);
      cloud.loseResponseFor = 'entries';
      await expectLater(sync(sa), throwsA(isA<SocketException>()));
      expect(cloud.tables['entries']!.length, 1);
      expect(sa.pending, 1);
      await sync(sa);
      expect(sa.pending, 0);
      expect(cloud.tables['entries']!.length, 1);
    },
  );
  test(
    'undo and reinstatement replicate, including a local edit during upload',
    () async {
      final goal = research(a);
      a.commit(goal.goalId, 150, week);
      cloud.duringUpload = (table, row) {
        if (table == 'entries') {
          cloud.duringUpload = null;
          a.undo(goal.goalId, week);
        }
      };
      await sync(sa);
      expect(sa.pending, 1);
      expect(research(a).total, 0);
      await sync(sa);
      await sync(sb);
      expect(research(b).total, 0);
      b.setUndone(b.entries(research(b).goalId).single.id, false, week);
      await sync(sb);
      await sync(sa);
      expect(research(a).total, 150);
      expect(cloud.tables['entries']!.length, 1);
    },
  );
  test(
    'concurrent weekly goal creation reconciles IDs and preserves both ledger events',
    () async {
      research(a);
      await sync(sa);
      await sync(sb);
      final next = week.shift(1);
      final ga = research(a, next), gb = research(b, next);
      expect(ga.goalId, isNot(gb.goalId));
      a.commit(ga.goalId, 150, next);
      b.commit(gb.goalId, 250, next);
      await sync(sa);
      await sync(sb);
      await sync(sa);
      expect(research(a, next).total, 400);
      expect(research(b, next).total, 400);
      expect(research(a, next).goalId, research(b, next).goalId);
      expect(cloud.tables['entries']!.length, 2);
    },
  );
  test(
    'archive, reorder, journal, review and historical snapshots synchronize',
    () async {
      final first = research(a);
      a.commit(first.goalId, 700, week);
      final next = week.shift(1);
      research(a, next);
      a.saveCategory(
        first.categoryId,
        const GoalConfig(
          name: 'Research',
          measurement: Measurement.continuous,
          unit: 'h',
          floor: 600,
          target: 1000,
          increment: 100,
          step: 25,
        ),
        next,
      );
      final journalId = const Uuid().v4();
      a.saveJournal(
        JournalEntry(
          id: journalId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          learned: 'A',
          question: 'B',
          next: 'C',
        ),
      );
      a.saveReview(WeeklyReview(week: week.key, wins: const ['A', 'B', 'C']));
      a.reorder(a.categories().reversed.map((c) => c.id).toList());
      final gym = a.categories().firstWhere((c) => c.config.name == 'Gym');
      a.setCategoryStatus(gym.id, current: next, active: false, archived: true);
      await sync(sa);
      await sync(sb);
      expect(b.categories().first.id, a.categories().first.id);
      expect(b.categories().firstWhere((c) => c.id == gym.id).archived, isTrue);
      expect(
        b
            .loadWeek(week, current: next)
            .firstWhere((p) => p.categoryId == first.categoryId)
            .config
            .target,
        800,
      );
      expect(research(b, next).config.target, 1000);
      expect(b.journal('').single.next, 'C');
      expect(b.review(week).wins, ['A', 'B', 'C']);
    },
  );
  test(
    'concurrent mutable conflicts converge deterministically and save losing text',
    () async {
      research(a);
      a.saveReview(WeeklyReview(week: week.key));
      await sync(sa);
      await sync(sb);
      sa.setMeta('device', 'aaaa');
      sb.setMeta('device', 'zzzz');
      sa.setMeta('clock', '100');
      sb.setMeta('clock', '100');
      a.saveReview(WeeklyReview(week: week.key, wentWrong: 'Version A'));
      b.saveReview(WeeklyReview(week: week.key, wentWrong: 'Version B'));
      await sync(sa);
      await sync(sb);
      await sync(sa);
      expect(a.review(week).wentWrong, 'Version B');
      expect(b.review(week).wentWrong, 'Version B');
      expect(sa.conflicts + sb.conflicts, greaterThan(0));
      expect(cloud.tables['reviews']!.length, 1);
    },
  );
  test(
    'account/project isolation and cancelled responses never mix datasets',
    () async {
      research(a);
      await sync(sa);
      expect(() => sa.bind(other, project), throwsFormatException);
      expect(
        () => sa.bind(account, 'https://another.supabase.co'),
        throwsFormatException,
      );
      final before = b.exportJson();
      var active = true;
      cloud.duringPull = () async {
        active = false;
      };
      await expectLater(
        SyncEngine(
          sb,
          cloud,
          backup: () async {},
        ).synchronize(account, project, () => active),
        throwsA(isA<SyncCancelled>()),
      );
      // Bookkeeping changes, but user data does not.
      expect(
        jsonDecode(b.exportJson())['tables'],
        jsonDecode(before)['tables'],
      );
    },
  );
  test(
    'failed backup blocks first upload and preserves local records',
    () async {
      a.commit(research(a).goalId, 150, week);
      await expectLater(
        SyncEngine(
          sa,
          cloud,
          backup: () async {
            throw FileSystemException('disk full');
          },
        ).synchronize(account, project, () => true),
        throwsA(isA<FileSystemException>()),
      );
      expect(cloud.calls, 0);
      expect(research(a).total, 150);
      expect(sa.meta('first_backup'), isEmpty);
    },
  );
  test('pending ledger and account binding survive a disk restart', () async {
    final directory = await Directory.systemTemp.createTemp('trackstudy-sync-');
    final path = '${directory.path}/pending.sqlite';
    var disk = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
    try {
      await sync(SyncStore(disk.database));
      final goal = research(disk);
      disk.commit(goal.goalId, 150, week);
      final pending = SyncStore(disk.database).pending;
      expect(pending, greaterThan(0));
      disk.close();
      disk = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      final store = SyncStore(disk.database);
      expect(store.pending, pending);
      expect(store.meta('account'), account);
      expect(research(disk).total, 150);
      await sync(store);
      expect(store.pending, 0);
      expect(cloud.tables['entries']!.length, 1);
      await sync(store);
      expect(cloud.tables['entries']!.length, 1);
    } finally {
      disk.close();
      await directory.delete(recursive: true);
    }
  });
  test('cloud unit conflicts cannot reinterpret pending local work', () async {
    final goal = research(a);
    await sync(sa);
    a.commit(goal.goalId, 150, week);
    final remote = await cloud.pull(account);
    final changed = remote['weekly_goals']!.firstWhere(
      (r) => r['id'] == goal.goalId,
    );
    changed['unit'] = 'km';
    changed['sync_version'] = 10000;
    expect(() => sa.apply(remote, account), throwsFormatException);
    expect(research(a).total, 150);
    expect(research(a).config.unit, 'h');
    expect(sa.pending, greaterThan(0));
  });
  test('malformed pull rolls back the complete local merge', () async {
    a.commit(research(a).goalId, 150, week);
    await sync(sa);
    final data = await cloud.pull(account);
    data['categories']!.last['user_id'] = other;
    final before = b.exportJson();
    expect(() => sb.apply(data, account, bootstrap: true), throwsStateError);
    expect(jsonDecode(b.exportJson())['tables'], jsonDecode(before)['tables']);
    expect(sb.meta('applying'), '0');
  });
  test(
    'authentication errors, restored session, sign-out and offline status',
    () async {
      final auth = FakeAuth();
      final controller = SyncController(
        store: sa,
        project: project,
        configured: true,
        backup: () async {},
      );
      controller.connect(auth, cloud);
      expect(controller.status, 'Local only');
      expect(controller.canSignIn, isTrue);
      auth.reject = true;
      await controller.signIn('a@example.com', 'wrong');
      expect(controller.account, isNull);
      expect(controller.error, contains('Sign-in failed'));
      auth.reject = false;
      cloud.offline = true;
      await controller.signIn('a@example.com', 'test');
      while (controller.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(controller.account!.id, account);
      expect(controller.error, isNotNull);
      cloud.offline = false;
      await controller.sync(manual: true);
      expect(controller.error, isNull);
      await controller.signOut();
      expect(controller.account, isNull);
      await controller.signIn('other@example.com', 'test');
      expect(controller.account, isNull);
      expect(controller.error, contains('another account'));
      controller.dispose();
      auth.user = const SyncAccount(account, 'a@example.com');
      final restored = SyncController(
        store: sa,
        project: project,
        configured: true,
        backup: () async {},
      );
      restored.connect(auth, cloud);
      while (restored.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(restored.account!.id, account);
      expect(restored.lastSync, isNotNull);
      restored.dispose();
      await auth.events.close();
    },
  );
}
