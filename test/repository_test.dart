import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:uuid/uuid.dart';

void main() {
  final monday = Week.parse('2026-09-21');
  late LocalStudyRepository repo;
  setUp(
    () => repo = LocalStudyRepository(
      StudyDatabase(sqlite3.openInMemory()),
      clock: () => DateTime.utc(2026, 9, 23, 12),
    ),
  );
  tearDown(() => repo.close());
  WeeklyProgress research(Week week) => repo
      .loadWeek(week, current: week)
      .firstWhere((p) => p.config.name == 'Research');
  test('fresh defaults, seeded once, UUID identities and snapshots', () {
    expect(repo.categories().map((c) => c.config.name), [
      'Research',
      'CSPH',
      'NLP',
      'IAES',
      'Gym',
      'Sleep',
      'Wake-up',
    ]);
    final p = research(monday);
    expect(p.total, 0);
    expect(p.config.floor, 600);
    expect(p.config.target, 800);
    expect(Uuid.isValidUUID(fromString: p.goalId), isTrue);
    expect(repo.loadWeek(monday, current: monday).length, 7);
  });
  test(
    'main acceptance workflow with undo ties, disabled/no-op undo, overflow',
    () {
      final goal = research(monday).goalId;
      repo.commit(goal, 150, monday);
      expect(research(monday).total, 150);
      expect(research(monday).fraction, .1875);
      repo.commit(goal, 250, monday);
      expect(research(monday).total, 400);
      expect(research(monday).fraction, .5);
      repo.undo(goal, monday);
      expect(research(monday).total, 150);
      repo.undo(goal, monday);
      repo.undo(goal, monday);
      expect(research(monday).total, 0);
      expect(repo.entries(goal).length, 2);
      expect(repo.entries(goal).every((e) => e.undoneAt != null), isTrue);
      repo.commit(goal, 1000, monday);
      expect(research(monday).total, 1000);
      expect(research(monday).fraction, 1);
      final next = monday.shift(1);
      expect(research(next).total, 0);
      expect(repo.loadWeek(monday, current: next).first.total, 1000);
    },
  );
  test('target 8 to 10 applies current; past configuration remains 8', () {
    final old = research(monday);
    repo.commit(old.goalId, 700, monday);
    final next = monday.shift(1);
    research(next);
    const config = GoalConfig(
      name: 'Research',
      measurement: Measurement.continuous,
      unit: 'h',
      floor: 600,
      target: 1000,
      increment: 100,
      step: 25,
    );
    repo.saveCategory(old.categoryId, config, next);
    expect(research(next).config.target, 1000);
    final historical = repo.loadWeek(monday, current: next).first;
    expect(historical.config.target, 800);
    expect(historical.total, 700);
  });
  test('commit validation and safe reinstatement', () {
    final p = research(monday);
    final gym = repo
        .loadWeek(monday, current: monday)
        .firstWhere((p) => p.config.name == 'Gym');
    for (final amount in [-100, 0, Amount.max + 1]) {
      expect(
        () => repo.commit(p.goalId, amount, monday),
        throwsFormatException,
      );
    }
    expect(() => repo.commit(gym.goalId, 150, monday), throwsFormatException);
    repo.commit(gym.goalId, 100, monday);
    expect(
      repo
          .loadWeek(monday, current: monday)
          .firstWhere((p) => p.goalId == gym.goalId)
          .total,
      100,
    );
    repo.commit(p.goalId, 125, monday);
    final e = repo.entries(p.goalId).first;
    repo.setUndone(e.id, true, monday);
    repo.setUndone(e.id, true, monday);
    expect(research(monday).total, 0);
    repo.setUndone(e.id, false, monday);
    repo.setUndone(e.id, false, monday);
    expect(research(monday).total, 125);
    expect(
      () => repo.commit(p.goalId, 100, monday.shift(1)),
      throwsFormatException,
    );
  });
  test(
    'settings add, reorder, archive, reactivate, validate and protect units',
    () {
      const config = GoalConfig(
        name: 'Open Source',
        measurement: Measurement.continuous,
        unit: 'h',
        floor: 200,
        target: 400,
        increment: 100,
        step: 25,
      );
      repo.saveCategory(null, config, monday);
      final category = repo.categories().last;
      expect(
        repo.loadWeek(monday, current: monday).last.config.name,
        'Open Source',
      );
      repo.reorder(repo.categories().reversed.map((c) => c.id).toList());
      expect(repo.categories().first.id, category.id);
      final p = repo.loadWeek(monday, current: monday).first;
      repo.commit(p.goalId, 100, monday);
      repo.setCategoryStatus(
        category.id,
        current: monday,
        active: false,
        archived: true,
      );
      expect(repo.loadWeek(monday, current: monday).length, 7);
      expect(
        repo
            .loadWeek(monday, current: monday.shift(1))
            .any((p) => p.categoryId == category.id),
        isFalse,
      );
      expect(repo.entries(p.goalId).single.amount, 100);
      repo.setCategoryStatus(
        category.id,
        current: monday,
        active: true,
        archived: false,
      );
      expect(repo.loadWeek(monday, current: monday).first.total, 100);
      expect(
        () => repo.saveCategory(
          category.id,
          const GoalConfig(
            name: 'Bad',
            measurement: Measurement.continuous,
            unit: 'h',
            floor: 500,
            target: 400,
            increment: 100,
            step: 25,
          ),
          monday,
        ),
        throwsFormatException,
      );
      expect(
        () => repo.saveCategory(
          category.id,
          const GoalConfig(
            name: 'Bad',
            measurement: Measurement.discrete,
            unit: 'count',
            floor: 200,
            target: 400,
            increment: 100,
            step: 100,
          ),
          monday,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'open app crosses Sunday midnight and resume catches a missed boundary',
    () {
      var clock = DateTime(2026, 9, 27, 23, 59);
      final controller = StudyController(
        repo,
        clock: () => clock,
        watchClock: false,
      );
      controller.add(controller.progress.first, '7');
      expect(controller.progress.first.total, 700);
      clock = DateTime(2026, 9, 28);
      controller.checkClock();
      expect(controller.progress.first.total, 0);
      expect(controller.current.key, '2026-09-28');
      controller.navigate(monday);
      expect(controller.progress.first.total, 700);
      controller.dispose();
      clock = DateTime(2026, 10, 5, 15);
      final reopened = StudyController(
        repo,
        clock: () => clock,
        watchClock: false,
      );
      expect(reopened.current.key, '2026-10-05');
      expect(reopened.progress.first.total, 0);
      reopened.dispose();
    },
  );
  test('journal search, latest Next, edit and weekly review persist', () {
    final id = const Uuid().v4();
    repo.saveJournal(
      JournalEntry(
        id: id,
        createdAt: DateTime.utc(2026, 9, 23).toIso8601String(),
        learned: 'Frozen LLM',
        question: 'Loss function?',
        next: 'Read section 3',
        experiment: const {'Hypothesis': 'Better embeddings'},
      ),
    );
    expect(repo.journal('LOSS').single.next, 'Read section 3');
    expect(repo.journal('embeddings').length, 1);
    repo.saveReview(
      WeeklyReview(
        week: monday.key,
        wentWrong: 'Late start',
        change: 'Monday research',
        wins: const ['One', 'Two', 'Three'],
      ),
    );
    expect(repo.review(monday).wins, ['One', 'Two', 'Three']);
    expect(repo.review(monday).change, 'Monday research');
  });
  test('complete JSON restore and rejection leaves live data unchanged', () {
    final p = research(monday);
    repo.commit(p.goalId, 150, monday);
    repo.undo(p.goalId, monday);
    repo.saveReview(WeeklyReview(week: monday.key));
    final backup = repo.exportJson();
    repo.commit(p.goalId, 900, monday);
    repo.restoreJson(backup);
    expect(research(monday).total, 0);
    expect(repo.entries(p.goalId).length, 1);
    final before = repo.exportJson();
    for (final bad in [
      'not json',
      '{}',
      backup.replaceFirst('"target": 800', '"target": 0'),
      backup.replaceFirst('"position": 0', '"position": 0.5'),
    ]) {
      expect(() => repo.restoreJson(bad), throwsFormatException);
      expect(repo.exportJson(), before);
    }
    final decoded = jsonDecode(backup) as Map<String, dynamic>;
    ((decoded['tables'] as Map)['entries'] as List).first['goal_id'] =
        const Uuid().v4();
    expect(() => repo.restoreJson(jsonEncode(decoded)), throwsFormatException);
    expect(repo.exportJson(), before);
    for (final field in ['wins', 'done']) {
      final malformed = jsonDecode(backup) as Map<String, dynamic>;
      final row = ((malformed['tables'] as Map)['reviews'] as List).first;
      final content = jsonDecode(row['content'] as String) as Map;
      (content[field] as List)[0] = 123;
      row['content'] = jsonEncode(content);
      // Soft-deleted data must be validated too, before any live replacement.
      row['deleted_at'] = '2026-09-23T12:00:00Z';
      expect(
        () => repo.restoreJson(jsonEncode(malformed)),
        throwsFormatException,
      );
      expect(repo.exportJson(), before);
    }
  });
  test(
    'file-backed commits and undo survive close and reopen; no reseeding',
    () {
      final directory = Directory.systemTemp.createTempSync('trackstudy-test-');
      final path = '${directory.path}/test.sqlite';
      try {
        var disk = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        final goal = disk.loadWeek(monday, current: monday).first;
        disk.commit(goal.goalId, 1000, monday);
        disk.close();
        disk = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        expect(disk.loadWeek(monday, current: monday).first.total, 1000);
        expect(disk.categories().length, 7);
        disk.undo(goal.goalId, monday);
        disk.close();
        disk = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        expect(disk.loadWeek(monday, current: monday).first.total, 0);
        expect(disk.entries(goal.goalId).single.undoneAt, isNotNull);
        disk.close();
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
  test('migration v1 through v3 preserves records; future schema rejected', () {
    final raw = sqlite3.openInMemory();
    final original = StudyDatabase(raw);
    final oldRepository = LocalStudyRepository(original);
    final goal = oldRepository.loadWeek(monday, current: monday).first;
    oldRepository.commit(goal.goalId, 150, monday);
    for (final trigger in raw.select(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'",
    )) {
      raw.execute('DROP TRIGGER ${trigger['name']}');
    }
    raw.execute(
      'DROP TABLE sync_records; DROP TABLE sync_meta; DROP TABLE sync_conflicts;',
    );
    raw.execute(
      'DROP TABLE category_states; DROP TABLE todo_tasks; DROP TABLE todo_topics; DROP TABLE schedule_blocks; DROP TABLE academic_events; ALTER TABLE journal DROP COLUMN answer; ALTER TABLE journal DROP COLUMN answered_at; DROP INDEX entries_goal_active; DROP INDEX goals_week; DROP INDEX journal_date; PRAGMA user_version=1',
    );
    final migrated = StudyDatabase(raw);
    expect(
      LocalStudyRepository(
        migrated,
      ).loadWeek(monday, current: monday).first.total,
      150,
    );
    expect(
      raw.select('PRAGMA user_version').first.values.first,
      StudyDatabase.version,
    );
    expect(
      raw
          .select('SELECT count(*) n FROM sync_records WHERE dirty=1')
          .first['n'],
      22,
    );
    expect(
      raw
          .select(
            "SELECT name FROM sqlite_master WHERE name='entries_goal_active'",
          )
          .length,
      1,
    );
    raw.execute('PRAGMA user_version=999');
    expect(() => StudyDatabase(raw), throwsStateError);
    expect(identical(original.handle, migrated.handle), isTrue);
    original.close();
  });
}
