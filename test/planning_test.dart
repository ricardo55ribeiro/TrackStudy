import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'package:trackstudy/application/sync_controller.dart';
import 'package:trackstudy/sync/auth_service.dart';
import 'package:trackstudy/platform/windows_background.dart';
import 'support/sync_fakes.dart';

void main() {
  LocalStudyRepository create() =>
      LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  ScheduleBlock block({
    String? id,
    int day = 1,
    int start = 510,
    int end = 600,
    String title = 'Gym',
  }) => ScheduleBlock(
    id: id ?? const Uuid().v4(),
    title: title,
    weekday: day,
    startMinute: start,
    endMinute: end,
  );
  AcademicEvent event({
    String? id,
    String date = '2026-10-07',
    String title = 'NLP Test',
  }) => AcademicEvent(
    id: id ?? const Uuid().v4(),
    title: title,
    date: date,
    type: AcademicType.test,
  );
  test(
    'recurring CRUD, validation and soft deletion keep durable sync history',
    () {
      final repo = create();
      addTearDown(repo.close);
      final b = block();
      repo.saveSchedule(b);
      expect(repo.schedule(1).single.startMinute, 510);
      expect(repo.schedule(2), isEmpty);
      repo.saveSchedule(block(id: b.id, start: 540, end: 660, title: 'Edited'));
      expect(repo.schedule(1).single.title, 'Edited');
      for (final invalid in [
        block(end: 510),
        block(end: 500),
        block(start: -1),
        block(end: 1441),
        block(day: 8),
        block(title: ' '),
      ]) {
        expect(() => repo.saveSchedule(invalid), throwsFormatException);
      }
      repo.deleteSchedule(b.id);
      expect(repo.schedule(1), isEmpty);
      expect(
        SyncStore(
          repo.database,
        ).pendingRows('schedule_blocks').single['deleted_at'],
        isNotNull,
      );
    },
  );
  test(
    'date-only event CRUD, multiple per day, leap/year boundaries and validation',
    () {
      final repo = create();
      addTearDown(repo.close);
      final e = event();
      repo.saveAcademicEvent(e);
      repo.saveAcademicEvent(event(title: 'Presentation'));
      expect(repo.academicEvents(DateTime(2026, 10)).length, 2);
      repo.saveAcademicEvent(
        event(id: e.id, date: '2028-02-29', title: 'Leap exam'),
      );
      expect(repo.academicEvents(DateTime(2028, 2)).single.date, '2028-02-29');
      repo.deleteAcademicEvent(e.id);
      expect(repo.academicEvents(DateTime(2028, 2)), isEmpty);
      for (final date in [
        '2026-02-29',
        '2026-04-31',
        '2026-10-07T00:00:00Z',
        '2026-1-01',
      ]) {
        expect(
          () => repo.saveAcademicEvent(event(date: date)),
          throwsFormatException,
        );
      }
      expect(LocalDate.month(DateTime(2026, 12), 1), DateTime(2027, 1));
      expect(LocalDate.month(DateTime(2027, 1), -1), DateTime(2026, 12));
      for (final month in [
        DateTime(2028, 2),
        DateTime(2026, 2),
        DateTime(2026, 10),
        DateTime(2027, 1),
      ]) {
        final cells = LocalDate.monthCells(month);
        expect(cells.first.weekday, 1);
        expect(cells.last.weekday, 7);
        expect(
          cells.where((d) => d.month == month.month).length,
          DateTime(month.year, month.month + 1, 0).day,
        );
      }
    },
  );
  test(
    'overlap lanes and wall-clock geometry including seconds and midnight',
    () {
      final a = block(),
          b = block(start: 540, end: 720),
          c = block(start: 600, end: 630),
          d = block(start: 800, end: 900);
      final lanes = layoutSchedule([d, c, b, a]);
      expect(lanes.map((p) => p.lanes), [2, 2, 2, 1]);
      expect(lanes[0].lane, lanes[2].lane);
      expect(lanes[0].lane, isNot(lanes[1].lane));
      expect(WallTime.minutes(DateTime(2026, 10, 25, 11, 23, 30)), 683.5);
      expect(WallTime.minutes(DateTime(2026, 3, 29, 10)), 600);
      expect(WallTime.minutes(DateTime(2026, 10, 25, 10)), 600);
      expect(WallTime.minutes(DateTime(2026, 9, 28)), 0);
      expect(DateTime(2026, 9, 28).weekday, 1);
      expect(WallTime.parse('24:00'), 1440);
      expect(() => WallTime.parse('24:01'), throwsFormatException);
    },
  );
  test(
    'v4 to v5 migration preserves original rows, dirty queue, identity and settings',
    () {
      final repo = create();
      addTearDown(repo.close);
      final week = Week.containing(DateTime(2026, 9, 27));
      repo.commit(repo.loadWeek(week, current: week).first.goalId, 150, week);
      repo.setPreference('theme', 'dark');
      final store = SyncStore(repo.database), raw = repo.database.handle;
      final identity = store.meta('device'), pending = store.pending;
      raw.execute(
        'DROP TABLE category_states; DROP TABLE todo_tasks; DROP TABLE todo_topics; DROP TABLE schedule_blocks; DROP TABLE academic_events; ALTER TABLE journal DROP COLUMN answer; ALTER TABLE journal DROP COLUMN answered_at; PRAGMA user_version=4',
      );
      StudyDatabase(raw);
      expect(
        raw.select('PRAGMA user_version').first.values.first,
        StudyDatabase.version,
      );
      expect(store.meta('device'), identity);
      expect(store.pending, pending);
      expect(repo.loadWeek(week, current: week).first.total, 150);
      expect(repo.preference('theme', ''), 'dark');
      expect(repo.categories().length, 7);
      expect(repo.schedule(1), isEmpty);
      expect(repo.academicEvents(DateTime(2026, 10)), isEmpty);
      repo.saveSchedule(block());
      expect(store.pending, pending + 1);
    },
  );
  test(
    'backup v3 roundtrip, rejected bad dates, legacy v2 retention and local startup safety',
    () {
      final repo = create();
      addTearDown(repo.close);
      final b = block(), e = event();
      repo.saveSchedule(b);
      repo.saveAcademicEvent(e);
      repo.setPreference('tab.journal', 'false');
      repo.setPreference('windows.startup', 'true');
      final backup = repo.exportJson();
      expect(backup, isNot(contains('windows.startup')));
      repo.deleteSchedule(b.id);
      repo.restoreJson(backup);
      expect(repo.schedule(1).single.id, b.id);
      expect(repo.preference('windows.startup', ''), 'true');
      final bad = jsonDecode(backup);
      bad['tables']['academic_events'][0]['event_date'] = '2026-02-30';
      expect(() => repo.restoreJson(jsonEncode(bad)), throwsFormatException);
      expect(repo.academicEvents(DateTime(2026, 10)).single.id, e.id);
      final legacy = jsonDecode(backup)..['version'] = 2;
      legacy['tables'].remove('schedule_blocks');
      legacy['tables'].remove('academic_events');
      repo.restoreJson(jsonEncode(legacy));
      expect(repo.schedule(1).single.id, b.id);
      expect(repo.preference('tab.journal', ''), 'false');
      final empty = create();
      addTearDown(empty.close);
      repo.restoreJson(empty.exportJson());
      expect(repo.schedule(1), isEmpty);
      expect(
        SyncStore(
          repo.database,
        ).pendingRows('schedule_blocks').single['deleted_at'],
        isNotNull,
      );
    },
  );
  test(
    'planning bootstrap, two-client convergence, offline edits, tombstones and causal races',
    () async {
      final pc = create(), phone = create();
      addTearDown(pc.close);
      addTearDown(phone.close);
      final cloud = FakeCloud(),
          a = SyncStore(pc.database),
          b = SyncStore(phone.database);
      Future<void> sync(SyncStore store) => SyncEngine(
        store,
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      final schedule = block(), exam = event();
      pc.saveSchedule(schedule);
      pc.saveAcademicEvent(exam);
      pc.setPreference('tab.month', 'false');
      await sync(a);
      await sync(b);
      expect(phone.categories().length, 7);
      expect(phone.schedule(1).single.id, schedule.id);
      expect(
        phone.academicEvents(DateTime(2026, 10)).single.date,
        '2026-10-07',
      );
      expect(phone.preference('tab.month', 'true'), 'true');
      cloud.offline = true;
      phone.saveAcademicEvent(event(id: exam.id, title: 'Phone edit'));
      expect(
        phone.academicEvents(DateTime(2026, 10)).single.title,
        'Phone edit',
      );
      cloud.offline = false;
      await sync(b);
      await sync(a);
      expect(pc.academicEvents(DateTime(2026, 10)).single.title, 'Phone edit');
      phone.deleteSchedule(schedule.id);
      await sync(b);
      await sync(a);
      expect(pc.schedule(1), isEmpty);
      for (var i = 0; i < 3; i++) {
        await sync(a);
        await sync(b);
      }
      expect(cloud.tables['schedule_blocks']!.length, 1);
      expect(cloud.tables['academic_events']!.length, 1);
      expect(a.conflicts + b.conflicts, 0);
      expect(cloud.conflicts, isEmpty);
      pc.saveAcademicEvent(event(id: exam.id, title: 'PC race'));
      phone.saveAcademicEvent(event(id: exam.id, title: 'Phone race'));
      await sync(a);
      await sync(b);
      await sync(a);
      expect(
        pc.academicEvents(DateTime(2026, 10)).single.title,
        phone.academicEvents(DateTime(2026, 10)).single.title,
      );
      expect(
        a.conflicts + b.conflicts + cloud.conflicts.length,
        greaterThan(0),
      );
      final copies = a.conflicts + b.conflicts + cloud.conflicts.length;
      await sync(a);
      await sync(b);
      expect(a.conflicts + b.conflicts + cloud.conflicts.length, copies);
    },
  );
  testWidgets(
    'Windows background pulls at 45 seconds without upload loops and disables cleanly',
    (tester) async {
      final repo = create();
      final cloud = FakeCloud(),
          auth = FakeAuth()
            ..user = const SyncAccount(account, 'fixture@example.com');
      final sync = SyncController(
        store: SyncStore(repo.database),
        project: project,
        configured: true,
        backup: () async {},
      );
      sync.setWindowsBackground(true);
      sync.connect(auth, cloud);
      await tester.pump();
      final phone = create();
      final phoneEngine = SyncEngine(
        SyncStore(phone.database),
        cloud,
        backup: () async {},
      );
      await phoneEngine.synchronize(account, project, () => true);
      final incoming = event(title: 'Incoming while Windows is in tray');
      phone.saveAcademicEvent(incoming);
      await phoneEngine.synchronize(account, project, () => true);
      final calls = cloud.calls;
      await tester.pump(const Duration(seconds: 44));
      expect(cloud.calls, calls);
      await tester.pump(const Duration(seconds: 1));
      expect(cloud.calls, calls + 1);
      expect(repo.academicEvents(DateTime(2026, 10)).single.id, incoming.id);
      sync.setWindowsBackground(false);
      final after = cloud.calls;
      await tester.pump(const Duration(seconds: 46));
      expect(cloud.calls, after);
      sync.dispose();
      await auth.events.close();
      phone.close();
      repo.close();
    },
  );
  testWidgets(
    'Windows choices persist locally and native failure retains them',
    (tester) async {
      final repo = create(), sync = SyncController();
      var nativeFails = false;
      final calls = <Map<dynamic, dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        WindowsBackground.channel,
        (call) async {
          calls.add(call.arguments as Map<dynamic, dynamic>);
          if (nativeFails) throw PlatformException(code: 'startup');
          return null;
        },
      );
      var settings = WindowsBackground();
      await settings.initialize(repo, sync);
      expect(settings.background, false);
      await settings.configure(sync, run: true, start: true);
      settings.dispose();
      settings = WindowsBackground();
      await settings.initialize(repo, sync);
      expect(settings.background, true);
      expect(settings.startup, true);
      expect(calls.last, {'background': true, 'startup': true});
      nativeFails = true;
      await settings.configure(sync, run: false, start: false);
      expect(settings.error, isNotNull);
      expect(settings.background, true);
      expect(repo.preference('windows.startup', ''), 'true');
      final exported = jsonDecode(repo.exportJson()) as Map<String, dynamic>;
      expect(
        (exported['tables']['preferences'] as List).where(
          (dynamic p) => (p['key'] as String).startsWith('windows.'),
        ),
        isEmpty,
      );
      settings.dispose();
      sync.dispose();
      repo.close();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        WindowsBackground.channel,
        null,
      );
    },
  );
}
