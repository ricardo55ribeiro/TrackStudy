import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'package:trackstudy/presentation/planning_colours.dart';
import 'support/monthly_colours.dart';

void main() {
  testWidgets(
    'each desktop badge uses its saved colour independently of event type',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
      final now = DateTime.now();
      for (final colour in ScheduleColour.values) {
        repo.saveAcademicEvent(
          AcademicEvent(
            id: const Uuid().v4(),
            title: colour.label,
            date: LocalDate.key(
              DateTime(now.year, now.month, colour.index + 1),
            ),
            type: AcademicType.values[colour.index],
            colour: colour,
          ),
        );
      }
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repositoryProvider.overrideWithValue(repo)],
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.windows,
                brightness: brightness,
              ),
              home: const Scaffold(body: MonthlyScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final event in repo.academicEvents(now)) {
          final badge = find.byKey(ValueKey('event-badge-${event.id}'));
          final decoration =
              tester.widget<Container>(badge).decoration as BoxDecoration;
          expect(decoration.color, event.colour.background(brightness));
          expect(decoration.borderRadius, BorderRadius.circular(4));
          expect(
            tester
                .widget<Text>(
                  find.descendant(of: badge, matching: find.byType(Text)),
                )
                .style!
                .color,
            event.colour.foreground(brightness),
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'five distinct shades retain the original palette and Black stays dark in both themes',
    () {
      expect(ScheduleColour.values.map((c) => c.name), [
        'blue',
        'orange',
        'green',
        'red',
        'black',
      ]);
      for (final brightness in Brightness.values) {
        expect(
          ScheduleColour.values.map((c) => c.background(brightness)).toSet(),
          hasLength(5),
        );
        expect(
          ScheduleColour.black.background(brightness).computeLuminance(),
          lessThan(.01),
        );
        expect(
          ScheduleColour.black.foreground(brightness).computeLuminance(),
          greaterThan(.8),
        );
      }
      expect(
        ScheduleColour.values
            .take(4)
            .map((c) => c.background(Brightness.light).toARGB32()),
        [0xFFDCE8F5, 0xFFF4E2CF, 0xFFDDEBDD, 0xFFF2DDDF],
      );
      expect(
        ScheduleColour.values
            .take(4)
            .map((c) => c.background(Brightness.dark).toARGB32()),
        [0xFF293E56, 0xFF513D2B, 0xFF2D4536, 0xFF513237],
      );
    },
  );
  for (final phone in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'monthly five colours, badges, details, indicators and editing phone=$phone ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = Size(phone ? 320 : 1100, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await exerciseMonthlyColours(
            tester,
            phone: phone,
            brightness: brightness,
          );
        },
      );
    }
  }
  testWidgets(
    'small event Add/Edit dialogs fit all five colours with keyboard and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
      final day = DateTime.now();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: const EdgeInsets.only(bottom: 280),
                textScaler: const TextScaler.linear(1.3),
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AcademicEditor(
                      date: day,
                      event: repo.academicEvents(day).firstOrNull,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final colour in [ScheduleColour.black, ScheduleColour.orange]) {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expectEventSelection(
          tester,
          colour == ScheduleColour.black
              ? ScheduleColour.blue
              : ScheduleColour.black,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Title'),
          'Small event',
        );
        await tester.ensureVisible(eventSwatch(colour));
        await tester.tap(eventSwatch(colour));
        await tester.pumpAndSettle();
        expectEventSelection(tester, colour);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.academicEvents(day).single.colour, colour);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
