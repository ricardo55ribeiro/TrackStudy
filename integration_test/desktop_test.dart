import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'package:trackstudy/sync/auth_service.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:uuid/uuid.dart';
import '../test/support/tab_reordering.dart';
import '../test/support/settings_acceptance.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native maximized startup/restore, tray and startup settings', (
    tester,
  ) async {
    const channel = MethodChannel('dev.trackstudy/background');
    var syncCalls = 0;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sync') syncCalls++;
    });
    try {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      var state = await channel.invokeMapMethod<String, dynamic>('testState');
      // Native ShowWindow may pump channel messages during its initial resize.
      // Wait for that operation to finish before simulating a manual restore.
      for (var i = 0; state!['ready'] != true && i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        state = await channel.invokeMapMethod<String, dynamic>('testState');
      }
      expect(state['ready'], true);
      expect(state['visible'], true);
      expect(state['maximized'], true);
      await channel.invokeMethod('testRestore');
      await tester.pumpAndSettle();
      state = await channel.invokeMapMethod<String, dynamic>('testState');
      expect(state!['maximized'], false);
      await channel.invokeMethod('configure', {
        'background': true,
        'startup': true,
      });
      state = await channel.invokeMapMethod<String, dynamic>('testState');
      expect(state!['tray'], true);
      expect(state['startup'], true);
      await channel.invokeMethod('testClose');
      await tester.pump(const Duration(milliseconds: 200));
      state = await channel.invokeMapMethod<String, dynamic>('testState');
      expect(state!['visible'], false);
      await channel.invokeMethod('testSync');
      await tester.pump();
      expect(syncCalls, 1);
      await channel.invokeMethod('testOpen');
      await tester.pump();
      state = await channel.invokeMapMethod<String, dynamic>('testState');
      expect(state!['visible'], true);
      expect(state['maximized'], true);
      await channel.invokeMethod('testMinimize');
      state = await channel.invokeMapMethod<String, dynamic>('testState');
      expect(state!['minimized'], true);
      await channel.invokeMethod('testOpen');
      state = await channel.invokeMapMethod<String, dynamic>('testState');
      expect(state!['minimized'], false);
      expect(state['maximized'], true);
    } finally {
      await channel.invokeMethod('configure', {
        'background': false,
        'startup': false,
      });
      channel.setMethodCallHandler(null);
    }
    final state = await channel.invokeMapMethod<String, dynamic>('testState');
    expect(state!['tray'], false);
    expect(state['startup'], false);
  });
  testWidgets('native encrypted session storage round-trip', (tester) async {
    final storage = SecureSessionStorage(
      'trackstudy.test.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await storage.initialize();
      expect(await storage.hasAccessToken(), isFalse);
      await storage.persistSession('{"test_session":"not-a-real-token"}');
      expect(await storage.hasAccessToken(), isTrue);
      expect(
        await storage.accessToken(),
        '{"test_session":"not-a-real-token"}',
      );
    } finally {
      await storage.removePersistedSession();
    }
    expect(await storage.hasAccessToken(), isFalse);
  });
  testWidgets('native Windows acceptance with file-backed restart', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'trackstudy-native-',
    );
    final path = '${directory.path}/acceptance.sqlite';
    var repository = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
    Future<void> launch() async {
      await tester.pumpWidget(
        ProviderScope(
          key: ObjectKey(repository),
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const TrackStudyApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    try {
      await launch();
      final input = find.byKey(const ValueKey('input-Research')),
          add = find.byKey(const ValueKey('add-Research')),
          undo = find.byKey(const ValueKey('undo-Research'));
      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, '1.5');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '1.5');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('1.5 / 8 h'), findsOneWidget);
      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, '2.5');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '2.5');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('4 / 8 h'), findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(find.text('1.5 / 8 h'), findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(undo).onPressed, isNull);
      // Let the native text-input connection finish attaching after undo took
      // focus, just as a user clicks the field before typing a new amount.
      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, '10');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '10');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(
        find.text('10 / 8 h'),
        findsOneWidget,
        reason: 'The +10 commit must be visible before closing',
      );
      final current = Week.containing(DateTime.now());
      expect(repository.loadWeek(current, current: current).first.total, 1000);
      repository.saveSchedule(
        ScheduleBlock(
          id: const Uuid().v4(),
          title: 'Native Gym',
          description: 'V0.04',
          weekday: 1,
          startMinute: 510,
          endMinute: 600,
        ),
      );
      final journalId = const Uuid().v4();
      repository.saveJournal(
        JournalEntry(
          id: journalId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          learned: 'Native journal',
          question: 'Why?',
          next: 'Investigate',
        ),
      );
      repository.answerJournal(journalId, 'Native answer', question: 'Why?');
      repository.saveAcademicEvent(
        AcademicEvent(
          id: const Uuid().v4(),
          title: 'Native Exam',
          date: '2026-10-29',
          type: AcademicType.exam,
        ),
      );
      await exerciseCategorySettings(tester, touch: false);
      await exerciseTabReordering(tester, touch: false);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      repository.close();
      repository = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      expect(repository.schedule(1).single.title, 'Native Gym');
      expect(repository.schedule(1).single.description, 'V0.04');
      expect(repository.journal('').single.answer, 'Native answer');
      expect(
        repository.preference('tab.order', ''),
        '["month","week","journal","review","schedule"]',
      );
      expect(
        repository.academicEvents(DateTime(2026, 10)).single.date,
        '2026-10-29',
      );
      expect(
        repository.loadWeek(current, current: current).first.total,
        1000,
        reason: 'The reopened SQLite ledger must retain +10',
      );
      await launch();
      expect(find.byType(MonthlyScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-week')));
      await tester.pumpAndSettle();
      expect(find.text('10 / 8 h'), findsOneWidget);
      expect(
        repository
            .loadWeek(current.shift(1), current: current.shift(1))
            .first
            .total,
        0,
      );
      expect(
        repository.loadWeek(current, current: current.shift(1)).first.total,
        1000,
      );
      await tester.pumpWidget(const SizedBox());
    } finally {
      repository.close();
      await directory.delete(recursive: true);
    }
  });
}
