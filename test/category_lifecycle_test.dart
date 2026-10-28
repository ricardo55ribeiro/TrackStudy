import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'support/sync_fakes.dart';

void main() {
  final w1 = Week.parse('2026-10-05'),
      w2 = Week.parse('2026-10-12'),
      w3 = Week.parse('2026-10-19'),
      w4 = Week.parse('2026-10-26');
  late DateTime now;
  late LocalStudyRepository repo;
  LocalStudyRepository fresh() => LocalStudyRepository(
    StudyDatabase(sqlite3.openInMemory()),
    clock: () => now,
  );
  setUp(() {
    now = DateTime(2026, 10, 7, 12);
    repo = fresh();
  });
  tearDown(() => repo.close());
  List<Map<String, Object?>> rows(String table) => repo.db
      .select('SELECT * FROM $table')
      .map((r) => Map<String, Object?>.from(r))
      .toList();
  WeeklyProgress research(LocalStudyRepository r, Week week) => r
      .loadWeek(week, current: week)
      .firstWhere((p) => p.config.name == 'Research');
  void archive(LocalStudyRepository r, String id, Week week, bool value) =>
      r.setCategoryStatus(id, current: week, active: !value, archived: value);

  test(
    'four weeks retain original snapshots and entries while exclusion covers whole weeks',
    () {
      final first = research(repo, w1);
      repo.commit(first.goalId, 100, w1);
      final goalsBefore = rows('weekly_goals');
      final second = research(repo, w2);
      repo.commit(second.goalId, 300, w2);
      repo.undo(second.goalId, w2);
      repo.commit(second.goalId, 200, w2);
      repo.saveReview(
        WeeklyReview(
          week: w2.key,
          wins: const ['Research notes', '', ''],
          danger: 'Research delay',
        ),
      );
      final entriesBefore = rows('entries'), reviewsBefore = rows('reviews');
      now = DateTime(2026, 10, 14, 12);
      archive(repo, first.categoryId, w2, true);
      expect(
        repo
            .loadWeek(w2, current: w2)
            .any((p) => p.categoryId == first.categoryId),
        isFalse,
      );
      expect(repo.loadWeek(w1, current: w2).first.total, 100);
      expect(rows('entries'), entriesBefore);
      expect(rows('reviews'), reviewsBefore);
      repo.loadWeek(w3, current: w3);
      expect(
        repo.db.select(
          'SELECT id FROM weekly_goals WHERE category_id=? AND week_start=?',
          [first.categoryId, w3.key],
        ),
        isEmpty,
      );
      now = DateTime(2026, 10, 29, 12);
      archive(repo, first.categoryId, w4, false);
      final fourth = research(repo, w4);
      repo.commit(fourth.goalId, 400, w4);
      expect(repo.loadWeek(w1, current: w4).first.total, 100);
      for (final week in [w2, w3]) {
        final progress = repo.loadWeek(week, current: w4);
        expect(progress.any((p) => p.categoryId == first.categoryId), isFalse);
        expect(progress.length, 6);
      }
      expect(research(repo, w4).total, 400);
      expect(
        rows('weekly_goals').where((r) => r['week_start'] == w1.key),
        goalsBefore,
      );
      expect(repo.entries(second.goalId).length, 2);
      expect(
        repo.entries(second.goalId).where((e) => e.undoneAt != null).length,
        1,
      );
      expect(rows('reviews'), reviewsBefore);
    },
  );

  test(
    'same-week final decision controls inclusion without changing any ledger record',
    () {
      final p = research(repo, w1);
      repo.commit(p.goalId, 200, w1);
      final entries = rows('entries');
      archive(repo, p.categoryId, w1, true);
      expect(() => repo.commit(p.goalId, 100, w1), throwsFormatException);
      expect(() => repo.undo(p.goalId, w1), throwsFormatException);
      archive(repo, p.categoryId, w1, false);
      expect(research(repo, w1).goalId, p.goalId);
      expect(research(repo, w1).total, 200);
      archive(repo, p.categoryId, w1, true);
      expect(
        repo
            .loadWeek(w1, current: w2)
            .any((bar) => bar.categoryId == p.categoryId),
        isFalse,
      );
      expect(rows('entries'), entries);
    },
  );

  test(
    'schema 7 upgrade preserves legacy history and normalizes disabled categories only from upgrade week',
    () {
      final p = research(repo, w1);
      repo.commit(p.goalId, 150, w1);
      final entries = rows('entries'), goals = rows('weekly_goals');
      repo.db.execute(
        'DROP TABLE category_states; DELETE FROM sync_records WHERE table_name=\'category_states\'; PRAGMA user_version=7',
      );
      repo.db.execute(
        'UPDATE categories SET active=0,archived_at=NULL WHERE id=?',
        [p.categoryId],
      );
      final gym = repo.categories().firstWhere((c) => c.config.name == 'Gym');
      repo.db.execute(
        'UPDATE categories SET active=0,archived_at=? WHERE id=?',
        ['2026-10-10T12:00:00.000Z', gym.id],
      );
      StudyDatabase(repo.db);
      now = DateTime(2026, 10, 28);
      repo.loadWeek(w4, current: w4);
      expect(
        repo.categories().where((c) => c.archived).map((c) => c.id).toSet(),
        {p.categoryId, gym.id},
      );
      expect(
        repo.categories().where((c) => c.archived).every((c) => !c.active),
        isTrue,
      );
      expect(repo.loadWeek(w1, current: w4).first.total, 150);
      expect(rows('entries'), entries);
      expect(
        rows('weekly_goals').where((r) => r['week_start'] == w1.key),
        goals,
      );
      expect(SyncStore(repo.database).pendingRows('category_states').length, 7);
      archive(repo, p.categoryId, w4, false);
      expect(repo.loadWeek(w2, current: w4), isEmpty);
      expect(repo.loadWeek(w3, current: w4), isEmpty);
    },
  );

  test(
    'current ordering changes preserve historical ordering and archived positions',
    () {
      final first = repo.loadWeek(w1, current: w1);
      repo.loadWeek(w2, current: w2);
      archive(repo, first[2].categoryId, w2, true);
      final order = repo.categories().map((c) => c.id).toList();
      final reordered = [...order]..removeAt(0);
      reordered.add(order.first);
      repo.reorder(reordered);
      expect(
        repo.loadWeek(w1, current: w2).map((p) => p.categoryId),
        first.map((p) => p.categoryId),
      );
      archive(repo, first[2].categoryId, w2, false);
      expect(
        repo.loadWeek(w2, current: w2).map((p) => p.categoryId),
        reordered,
      );
    },
  );

  test(
    'file restart keeps exclusion even when the app misses archived weeks',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'trackstudy-week-state-',
      );
      final path = '${folder.path}/state.sqlite';
      var disk = LocalStudyRepository(
        StudyDatabase(sqlite3.open(path)),
        clock: () => now,
      );
      try {
        final p = research(disk, w1);
        final second = research(disk, w2);
        disk.commit(second.goalId, 300, w2);
        archive(disk, p.categoryId, w2, true);
        disk.close();
        now = DateTime(2026, 10, 29);
        disk = LocalStudyRepository(
          StudyDatabase(sqlite3.open(path)),
          clock: () => now,
        );
        archive(disk, p.categoryId, w4, false);
        expect(
          disk
              .loadWeek(w2, current: w4)
              .any((bar) => bar.categoryId == p.categoryId),
          isFalse,
        );
        expect(disk.loadWeek(w3, current: w4), isEmpty);
        expect(disk.entries(second.goalId).single.amount, 300);
        expect(research(disk, w4).categoryId, p.categoryId);
      } finally {
        disk.close();
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'format 6 backup preserves states and old backups cannot erase existing decisions',
    () {
      final p = research(repo, w1);
      repo.commit(p.goalId, 200, w1);
      archive(repo, p.categoryId, w2, true);
      final snapshot = repo.exportJson();
      final restored = fresh();
      addTearDown(restored.close);
      restored.restoreJson(snapshot);
      expect(restored.loadWeek(w1, current: w4).first.total, 200);
      expect(
        restored
            .loadWeek(w2, current: w4)
            .any((bar) => bar.categoryId == p.categoryId),
        isFalse,
      );
      final legacy = jsonDecode(snapshot) as Map<String, dynamic>;
      legacy['version'] = 5;
      (legacy['tables'] as Map).remove('category_states');
      ((legacy['tables'] as Map)['categories'] as List).first['active'] = 1;
      ((legacy['tables'] as Map)['categories'] as List).first['archived_at'] =
          null;
      repo.restoreJson(jsonEncode(legacy));
      expect(repo.categories().first.archived, isTrue);
      expect(
        repo
            .loadWeek(w2, current: w4)
            .any((bar) => bar.categoryId == p.categoryId),
        isFalse,
      );
      expect(repo.entries(p.goalId).single.amount, 200);
    },
  );

  test('malformed backup state rolls back without changing local tracking', () {
    final p = research(repo, w1);
    repo.commit(p.goalId, 100, w1);
    final before = repo.exportJson();
    final bad = jsonDecode(before) as Map;
    (bad['tables']['category_states'] as List).first['included'] = 2;
    expect(() => repo.restoreJson(jsonEncode(bad)), throwsFormatException);
    expect(repo.exportJson(), before);
  });

  group('synchronized lifecycle', () {
    late LocalStudyRepository phone;
    late FakeCloud cloud;
    Future<void> sync(LocalStudyRepository r) => SyncEngine(
      SyncStore(r.database),
      cloud,
      backup: () async {},
    ).synchronize(account, project, () => true);
    setUp(() {
      phone = fresh();
      cloud = FakeCloud();
    });
    tearDown(() => phone.close());

    test(
      'late offline goals and entries cannot resurrect archived weeks after restoration',
      () async {
        final first = research(repo, w1);
        await sync(repo);
        await sync(phone);
        final second = research(phone, w2);
        phone.commit(second.goalId, 300, w2);
        final third = research(phone, w3);
        phone.commit(third.goalId, 200, w3);
        archive(repo, first.categoryId, w2, true);
        await sync(repo);
        archive(repo, first.categoryId, w4, false);
        await sync(repo);
        cloud.offline = true;
        await expectLater(sync(phone), throwsA(isA<SocketException>()));
        expect(SyncStore(phone.database).pending, greaterThan(0));
        cloud.offline = false;
        await sync(phone);
        await sync(repo);
        for (final r in [repo, phone]) {
          for (final week in [w2, w3]) {
            expect(
              r
                  .loadWeek(week, current: w4)
                  .any((p) => p.categoryId == first.categoryId),
              isFalse,
            );
          }
          expect(research(r, w4).categoryId, first.categoryId);
          expect(r.db.select('SELECT COUNT(*) n FROM entries').single['n'], 2);
        }
        await sync(phone);
        await sync(repo);
        expect(
          SyncStore(repo.database).pending + SyncStore(phone.database).pending,
          0,
        );
      },
    );

    test(
      'stale automatic upgrade baseline cannot revive an explicit archive',
      () async {
        final first = research(repo, w1);
        await sync(repo);
        await sync(phone);
        phone.db.execute('DELETE FROM category_states');
        phone.loadWeek(w3, current: w3);
        archive(repo, first.categoryId, w2, true);
        await sync(repo);
        await sync(phone);
        await sync(repo);
        for (final r in [repo, phone]) {
          expect(r.categories().first.archived, isTrue);
          expect(
            r
                .loadWeek(w3, current: w3)
                .any((p) => p.categoryId == first.categoryId),
            isFalse,
          );
        }
      },
    );

    for (final reverse in [false, true]) {
      test(
        'concurrent archive and restore converge in either upload order: $reverse',
        () async {
          final p = research(repo, w1);
          await sync(repo);
          await sync(phone);
          SyncStore(repo.database).setMeta('device', 'aaaa');
          SyncStore(phone.database).setMeta('device', 'zzzz');
          SyncStore(repo.database).setMeta('clock', '1000');
          SyncStore(phone.database).setMeta('clock', '1000');
          archive(repo, p.categoryId, w1, true);
          archive(phone, p.categoryId, w1, false);
          for (final r
              in reverse
                  ? [phone, repo, phone, repo]
                  : [repo, phone, repo, phone]) {
            await sync(r);
          }
          for (final r in [repo, phone]) {
            expect(r.categories().first.archived, isFalse);
            expect(research(r, w1).categoryId, p.categoryId);
            expect(SyncStore(r.database).pending, 0);
          }
        },
      );
    }

    test(
      'newer-week restore wins global status even if earlier-week archive arrives later',
      () async {
        final p = research(repo, w1);
        await sync(repo);
        await sync(phone);
        archive(repo, p.categoryId, w4, false);
        archive(phone, p.categoryId, w2, true);
        await sync(repo);
        await sync(phone);
        await sync(repo);
        expect(repo.categories().first.active, isTrue);
        expect(
          repo
              .loadWeek(w2, current: w4)
              .any((bar) => bar.categoryId == p.categoryId),
          isFalse,
        );
        expect(research(repo, w4).categoryId, p.categoryId);
      },
    );
  });
}
