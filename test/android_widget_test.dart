import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/platform/json_files.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:uuid/uuid.dart';

// Today's live time line keeps animating; wait for UI transitions, not for
// the entire schedule to become idle. This also works when tests run on Monday.
Future<void> pumpSchedule(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late LocalStudyRepository repository;
  setUp(() {
    repository = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  });
  tearDown(() {
    repository.close();
  });
  Future<void> launch(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: const TrackStudyApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets(
      'Android $width planning navigation, overlap, month and keyboard',
      (tester) async {
        for (var i = 0; i < 3; i++) {
          repository.saveSchedule(
            ScheduleBlock(
              id: const Uuid().v4(),
              title: 'Overlapping block $i',
              weekday: 1,
              startMinute: 510 + i * 10,
              endMinute: 660,
            ),
          );
        }
        final today = DateTime.now();
        repository.saveAcademicEvent(
          AcademicEvent(
            id: const Uuid().v4(),
            title: 'Phone exam',
            date: LocalDate.key(today),
            type: AcademicType.exam,
          ),
        );
        await launch(tester, width);
        await tester.ensureVisible(find.byKey(const ValueKey('tab-schedule')));
        await tester.tap(find.byKey(const ValueKey('tab-schedule')));
        await pumpSchedule(tester);
        await tester.tap(find.byKey(const ValueKey('weekday-1')));
        await pumpSchedule(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Add block'));
        await pumpSchedule(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await pumpSchedule(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Title'),
          'Phone block',
        );
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await pumpSchedule(tester);
        expect(repository.schedule(1).length, 4);
        tester.view.resetViewInsets();
        await tester.ensureVisible(find.byKey(const ValueKey('tab-month')));
        await tester.tap(find.byKey(const ValueKey('tab-month')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(ValueKey('date-${LocalDate.key(today)}')),
        );
        await tester.tap(find.byKey(ValueKey('date-${LocalDate.key(today)}')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Phone exam'));
        await tester.tap(find.text('Phone exam'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        expect(find.text('Edit academic event'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
    testWidgets(
      'Android $width phone: add with keyboard, journal/review/settings layout',
      (tester) async {
        await launch(tester, width);
        final input = find.byKey(const ValueKey('input-Research'));
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(tester.widget<TextField>(input).decoration!.hintText, isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.enterText(input, '1.5');
        await tester.tap(find.byKey(const ValueKey('add-Research')));
        await tester.pumpAndSettle();
        final week = Week.containing(DateTime.now());
        expect(repository.loadWeek(week, current: week).first.total, 150);
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.tap(find.text('Journal'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New entry'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Learned'),
          'Phone journal',
        );
        await tester.ensureVisible(find.text('Save').last);
        await tester.tap(find.text('Save').last);
        await tester.pumpAndSettle();
        expect(repository.journal('').single.learned, 'Phone journal');
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.ensureVisible(find.text('Review'));
        await tester.tap(find.text('Review'));
        await tester.pumpAndSettle();
        expect(find.text('Score'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.widgetWithText(TextField, 'What went wrong?'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'What went wrong?'),
          'Mobile draft',
        );
        expect(repository.review(week).wentWrong, 'Mobile draft');
        expect(tester.takeException(), isNull);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Research').last);
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        expect(find.text('Edit category'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  testWidgets(
    'Android export uses document creation channel and handles cancellation/failure',
    (tester) async {
      const channel = MethodChannel('dev.trackstudy/files');
      final calls = <MethodCall>[];
      var result = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return result;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      expect(await saveJsonFile('{"backup":true}', 'backup.json'), isTrue);
      expect(calls.single.method, 'saveJson');
      expect(calls.single.arguments, {
        'name': 'backup.json',
        'data': '{"backup":true}',
      });
      result = false;
      expect(await saveJsonFile('{}', 'cancel.json'), isFalse);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        throw PlatformException(code: 'write_failed');
      });
      await expectLater(
        saveJsonFile('{}', 'failure.json'),
        throwsA(isA<PlatformException>()),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
