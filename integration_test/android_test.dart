import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/application/sync_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/sync/auth_service.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import '../test/support/sync_fakes.dart';
import '../test/support/tab_reordering.dart';
import '../test/support/settings_acceptance.dart';
import '../test/support/android_drawer_acceptance.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android native encrypted session persists across storage instances',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      final key =
          'trackstudy.android.test.${DateTime.now().microsecondsSinceEpoch}';
      final storage = SecureSessionStorage(key);
      try {
        await storage.initialize();
        await storage.persistSession('{"fixture":"no-real-token"}');
        final restored = SecureSessionStorage(key);
        await restored.initialize();
        expect(await restored.hasAccessToken(), isTrue);
        expect(await restored.accessToken(), '{"fixture":"no-real-token"}');
      } finally {
        await storage.removePersistedSession();
      }
      expect(await storage.hasAccessToken(), isFalse);
    },
  );

  testWidgets(
    'fresh Android login, native SQLite, two-device convergence and offline retry',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      expect(support.path.startsWith('/'), isTrue);
      final directory = await Directory(
        '${support.path}/acceptance-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final path = '${directory.path}/phone.sqlite';
      var phone = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      final windows = LocalStudyRepository(
        StudyDatabase(sqlite3.openInMemory()),
      );
      final cloud = FakeCloud();
      final auth = FakeAuth();
      final week = Week.containing(DateTime.now());
      final pcStore = SyncStore(windows.database);
      Future<void> syncWindows() => SyncEngine(
        pcStore,
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      WeeklyProgress progress(LocalStudyRepository repo, String name) => repo
          .loadWeek(week, current: week)
          .firstWhere((p) => p.config.name == name);
      final past = week.shift(-1);
      final pastResearch = windows.loadWeek(past, current: past).first;
      windows.commit(pastResearch.goalId, 300, past);
      windows.commit(progress(windows, 'Research').goalId, 100, week);
      windows.saveJournal(
        JournalEntry(
          id: const Uuid().v4(),
          createdAt: DateTime.now().toUtc().toIso8601String(),
          learned: 'Windows journal',
          question: 'Question',
          next: 'Next',
        ),
      );
      windows.saveReview(
        WeeklyReview(
          week: week.key,
          wentWrong: 'Windows review',
          wins: const ['One', 'Two', 'Three'],
        ),
      );
      final scheduleId = const Uuid().v4(), eventId = const Uuid().v4();
      final journalId = windows.journal('').single.id;
      windows.answerJournal(journalId, 'Windows answer', question: 'Question');
      windows.saveSchedule(
        ScheduleBlock(
          id: scheduleId,
          title: 'Windows schedule',
          description: 'V0.04',
          weekday: 1,
          startMinute: 510,
          endMinute: 600,
        ),
      );
      windows.saveAcademicEvent(
        AcademicEvent(
          id: eventId,
          title: 'Windows exam',
          date: '2026-10-07',
          type: AcademicType.exam,
        ),
      );
      await syncWindows();
      final sourceIds = windows.categories().map((c) => c.id).toSet();
      final phoneStore = SyncStore(phone.database);
      var backups = 0;
      final sync = SyncController(
        store: phoneStore,
        project: project,
        configured: true,
        backup: () async {
          backups++;
        },
        retryDelay: const Duration(milliseconds: 300),
      );
      sync.connect(auth, cloud);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWithValue(phone),
              syncProvider.overrideWith((ref) {
                sync.onApplied = () => ref.read(studyProvider).refresh();
                return sync;
              }),
            ],
            child: const TrackStudyApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Sign in'),
          350,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 40,
        );
        await tester.tap(find.text('Sign in'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Email'),
          'a@example.com',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'test-fixture',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
        await tester.pumpAndSettle();
        expect(sync.error, isNull);
        expect(phone.categories().map((c) => c.id).toSet(), sourceIds);
        expect(phone.categories().length, 7);
        expect(cloud.tables['categories']!.length, 7);
        expect(backups, 1);
        expect(phone.journal('').single.learned, 'Windows journal');
        expect(phone.journal('').single.answer, 'Windows answer');
        expect(phone.schedule(1).single.description, 'V0.04');
        expect(phone.review(week).wins, ['One', 'Two', 'Three']);
        expect(phone.schedule(1).single.id, scheduleId);
        expect(
          phone.academicEvents(DateTime(2026, 10)).single.date,
          '2026-10-07',
        );
        expect(phone.loadWeek(past, current: week).first.total, 300);
        expect(phone.loadWeek(past, current: week).first.config.target, 800);
        await tester.pageBack();
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('input-Research'));
        await tester.enterText(input, '1.5');
        await tester.tap(find.byKey(const ValueKey('add-Research')));
        expect(progress(phone, 'Research').total, 250);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(phoneStore.pending, 0);
        await syncWindows();
        expect(progress(windows, 'Research').total, 250);
        windows.commit(progress(windows, 'CSPH').goalId, 200, week);
        await syncWindows();
        sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(progress(phone, 'CSPH').total, 200);
        await tester.tap(find.byKey(const ValueKey('undo-Research')));
        expect(progress(phone, 'Research').total, 100);
        await tester.pump(const Duration(seconds: 3));
        await syncWindows();
        expect(progress(windows, 'Research').total, 100);
        cloud.offline = true;
        phone.commit(progress(phone, 'Research').goalId, 100, week);
        expect(progress(phone, 'Research').total, 200);
        await tester.pump(const Duration(seconds: 3));
        expect(phoneStore.pending, greaterThan(0));
        cloud.offline = false;
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(phoneStore.pending, 0);
        await syncWindows();
        expect(progress(windows, 'Research').total, 200);
        phone.saveAcademicEvent(
          AcademicEvent(
            id: eventId,
            title: 'Phone exam edit',
            date: '2026-10-07',
            type: AcademicType.exam,
          ),
        );
        phone.answerJournal(journalId, 'Phone answer', question: 'Question');
        phone.saveSchedule(
          ScheduleBlock(
            id: scheduleId,
            title: 'Windows schedule',
            weekday: 1,
            startMinute: 510,
            endMinute: 600,
            description: 'Room B',
          ),
        );
        await tester.pump(const Duration(seconds: 3));
        await syncWindows();
        expect(windows.journal('').single.answer, 'Phone answer');
        expect(windows.schedule(1).single.description, 'Room B');
        expect(
          windows.academicEvents(DateTime(2026, 10)).single.title,
          'Phone exam edit',
        );
        windows.deleteSchedule(scheduleId);
        await syncWindows();
        await sync.sync(manual: true);
        expect(phone.schedule(1), isEmpty);
        final entryCount = cloud.tables['entries']!.length;
        for (var i = 0; i < 3; i++) {
          await sync.sync(manual: true);
          await syncWindows();
        }
        expect(cloud.tables['entries']!.length, entryCount);
        expect(cloud.tables['categories']!.length, 7);
        expect(phoneStore.conflicts + pcStore.conflicts, 0);
        expect(cloud.conflicts, isEmpty);
        await exerciseAndroidDrawer(tester);
        await exerciseCategorySettings(tester, touch: true);
        await tester.pump(const Duration(seconds: 3));
        await sync.sync(manual: true);
        await exerciseTabReordering(tester, touch: true);
        expect(phoneStore.pending, 0);
        expect(windows.preference('tab.order', ''), '');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        phone.close();
        phone = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        expect(progress(phone, 'Research').total, 200);
        expect(SyncStore(phone.database).pending, 0);
        expect(SyncStore(phone.database).meta('account'), account);
        expect(phone.journal('').single.answer, 'Phone answer');
        expect(
          phone.preference('tab.order', ''),
          '["month","week","journal","review","schedule"]',
        );
        expect(
          phone.academicEvents(DateTime(2026, 10)).single.title,
          'Phone exam edit',
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repositoryProvider.overrideWithValue(phone)],
            child: const TrackStudyApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('android-tab-title')))
              .data,
          'Monthly View',
        );
        expect(
          tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
          isFalse,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await auth.events.close();
        phone.close();
        windows.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
