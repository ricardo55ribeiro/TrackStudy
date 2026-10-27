import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/schedule.dart';
import 'package:trackstudy/presentation/monthly.dart';

// Today's live time line keeps animating; wait for UI transitions, not for
// the entire schedule to become idle. This also works when tests run on Monday.
Future<void> pumpSchedule(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'Windows planning editors, overlap, month and local tab visibility',
    (tester) async {
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: const TrackStudyApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-schedule')));
      await pumpSchedule(tester);
      await tester.tap(find.byKey(const ValueKey('weekday-1')));
      await pumpSchedule(tester);
      for (final item in [
        ('Gym', '08:30', '10:00'),
        ('IAES(T)', '10:00', '12:00'),
        ('MeetingAI', '12:45', '14:00'),
      ]) {
        await tester.tap(find.text('Add block'));
        await pumpSchedule(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Title'),
          item.$1,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Start · HH:MM'),
          item.$2,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'End · HH:MM'),
          item.$3,
        );
        await tester.tap(find.text('Save'));
        await pumpSchedule(tester);
      }
      expect(repo.schedule(1).length, 3);
      expect(repo.schedule(1).first.startMinute, 510);
      await tester.tap(find.byKey(const ValueKey('weekday-2')));
      await pumpSchedule(tester);
      expect(find.text('No schedule blocks for Tuesday.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('tab-month')));
      await tester.tap(find.byKey(const ValueKey('tab-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add event').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'NLP Test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Date · YYYY-MM-DD'),
        '2026-10-07',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.academicEvents(DateTime(2026, 10)).single.title, 'NLP Test');
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final monthlySwitch = find.widgetWithText(SwitchListTile, 'Monthly View');
      await tester.scrollUntilVisible(
        monthlySwitch,
        350,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(monthlySwitch);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tab-month')), findsNothing);
      expect(find.byKey(const ValueKey('input-Research')), findsOneWidget);
      expect(repo.academicEvents(DateTime(2026, 10)).length, 1);
      expect(repo.preference('tab.month', ''), 'false');
      final context = tester.element(find.byType(StudyShell));
      final container = ProviderScope.containerOf(context);
      container.read(studyProvider).setTabVisible(StudyTab.week, false);
      expect(container.read(studyProvider).tabVisible(StudyTab.week), isFalse);
      container.read(studyProvider).setTabVisible(StudyTab.month, true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tab-month')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      repo.close();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'today line uses seconds, stops offscreen, follows midnight and hides on other weekdays',
    (tester) async {
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      var now = DateTime(2026, 9, 27, 11, 23, 30);
      Future<void> launch(bool active) => tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Scaffold(
              body: ScheduleScreen(active: active, clock: () => now),
            ),
          ),
        ),
      );
      await launch(true);
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('current-time-line'));
      expect(
        tester.widget<AnimatedPositioned>(line).top,
        closeTo((683.5 - 360) * 1.4, .001),
      );
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<AnimatedPositioned>(line).top,
        closeTo((683.5 + 1 / 60 - 360) * 1.4, .001),
      );
      await tester.tap(find.byKey(const ValueKey('weekday-1')));
      await tester.pumpAndSettle();
      expect(line, findsNothing);
      await tester.tap(find.byKey(const ValueKey('weekday-7')));
      await tester.pumpAndSettle();
      now = DateTime(2026, 9, 28);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<AnimatedPositioned>(line).top, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = DateTime(2026, 9, 29, 9);
      await tester.pump(const Duration(seconds: 2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.widget<AnimatedPositioned>(line).top, (540 - 360) * 1.4);
      await launch(false);
      await tester.pumpAndSettle();
      now = now.add(const Duration(minutes: 10));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.widget<AnimatedPositioned>(line).top, (540 - 360) * 1.4);
      await tester.pumpWidget(const SizedBox());
      repo.close();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'event and schedule validation are visible and do not save invalid input',
    (tester) async {
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      Future<void> dialog(Widget editor) => tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(home: editor),
        ),
      );
      await dialog(const ScheduleEditor(weekday: 1));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Invalid',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'End · HH:MM'),
        '08:00',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('later than'), findsOneWidget);
      expect(repo.schedule(1), isEmpty);
      await dialog(AcademicEditor(date: DateTime(2026, 10, 7)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Invalid',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Date · YYYY-MM-DD'),
        '2026-02-30',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a valid calendar date.'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Date · YYYY-MM-DD'),
        '1800-01-01',
      );
      await tester.tap(find.byTooltip('Choose date'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      repo.close();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
