import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/schedule.dart';
import 'package:trackstudy/presentation/planning_colours.dart';
import 'support/schedule_colours.dart';

void main() {
  for (final brightness in Brightness.values) {
    test('all ${brightness.name} palette text exceeds 4.5:1 contrast', () {
      for (final colour in ScheduleColour.values) {
        final bg = colour.background(brightness).computeLuminance();
        final fg = colour.foreground(brightness).computeLuminance();
        final ratio = bg > fg
            ? (bg + .05) / (fg + .05)
            : (fg + .05) / (bg + .05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: colour.name);
      }
    });
    testWidgets(
      'Add/Edit swatches, independent backgrounds, preserve and cancel in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await exerciseScheduleColours(tester, brightness: brightness);
      },
    );
  }
  testWidgets(
    'small Android editor scrolls to all colours with keyboard and large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
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
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ScheduleEditor(
                      weekday: 1,
                      block: repo.schedule(1).firstOrNull,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Small screen',
      );
      await tester.ensureVisible(swatch(ScheduleColour.red));
      await tester.tap(swatch(ScheduleColour.red));
      await tester.pumpAndSettle();
      expectSelected(tester, ScheduleColour.red);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.schedule(1).single.colour, ScheduleColour.red);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expectSelected(tester, ScheduleColour.red);
      await tester.ensureVisible(swatch(ScheduleColour.green));
      await tester.tap(swatch(ScheduleColour.green));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.schedule(1).single.colour, ScheduleColour.green);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
