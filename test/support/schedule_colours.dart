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

Finder swatch(ScheduleColour colour) =>
    find.byKey(ValueKey('schedule-colour-${colour.name}'));

void expectSelected(WidgetTester tester, ScheduleColour colour) {
  for (final option in ScheduleColour.values) {
    expect(swatch(option), findsOneWidget);
    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == option.label,
      ),
    );
    expect(semantics.properties.selected, option == colour);
  }
}

Future<void> exerciseScheduleColours(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  try {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: ScheduleScreen(
              active: false,
              clock: () => DateTime(2026, 11, 2, 9),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final colour in ScheduleColour.values) {
      await tester.tap(find.text('Add block'));
      await tester.pumpAndSettle();
      expectSelected(tester, ScheduleColour.blue);
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        colour.label,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Description (optional)'),
        'Room ${colour.name}',
      );
      await tester.ensureVisible(swatch(colour));
      await tester.tap(swatch(colour));
      await tester.pumpAndSettle();
      expectSelected(tester, colour);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        repo.schedule(1).firstWhere((b) => b.title == colour.label).colour,
        colour,
      );
    }
    for (final block in repo.schedule(1)) {
      final tile = find.byKey(ValueKey('block-${block.id}'));
      final material = tester.widget<Material>(
        find.descendant(of: tile, matching: find.byType(Material)),
      );
      expect(material.color, block.colour.background(brightness));
      for (final text in tester.widgetList<Text>(
        find.descendant(of: tile, matching: find.byType(Text)),
      )) {
        expect(text.style!.color, block.colour.foreground(brightness));
      }
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expectSelected(tester, block.colour);
      await tester.ensureVisible(swatch(ScheduleColour.red));
      await tester.tap(swatch(ScheduleColour.red));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        repo.schedule(1).firstWhere((b) => b.id == block.id).colour,
        block.colour,
      );
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expectSelected(tester, block.colour);
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        '${block.title} edited',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        repo.schedule(1).firstWhere((b) => b.id == block.id).colour,
        block.colour,
      );
    }
    final first = repo.schedule(1).first;
    final tile = find.byKey(ValueKey('block-${first.id}'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.ensureVisible(swatch(ScheduleColour.orange));
    await tester.tap(swatch(ScheduleColour.orange));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      repo.schedule(1).firstWhere((b) => b.id == first.id).colour,
      ScheduleColour.orange,
    );
    expect(
      tester
          .widget<Material>(
            find.descendant(of: tile, matching: find.byType(Material)),
          )
          .color,
      ScheduleColour.orange.background(brightness),
    );
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    repo.close();
  }
}
