import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'package:trackstudy/presentation/planning_colours.dart';

Finder eventSwatch(ScheduleColour colour) =>
    find.byKey(ValueKey('event-colour-${colour.name}'));
void expectEventSelection(WidgetTester tester, ScheduleColour colour) {
  final editor = find.byType(AcademicEditor);
  for (final option in ScheduleColour.values) {
    expect(eventSwatch(option), findsOneWidget);
    final semantics = tester.widget<Semantics>(
      find.descendant(
        of: editor,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == option.label,
        ),
      ),
    );
    expect(semantics.properties.selected, option == colour);
  }
}

Future<void> exerciseMonthlyColours(
  WidgetTester tester, {
  required bool phone,
  Brightness brightness = Brightness.light,
}) async {
  final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  final today = DateTime.now(), date = LocalDate.key(DateTime.now());
  try {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            platform: phone ? TargetPlatform.android : TargetPlatform.windows,
          ),
          home: const Scaffold(body: MonthlyScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final colour in ScheduleColour.values) {
      await tester.tap(find.text('Add event').first);
      await tester.pumpAndSettle();
      expectEventSelection(tester, ScheduleColour.blue);
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        colour.label,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Note (optional)'),
        'Notes ${colour.name}',
      );
      await tester.ensureVisible(eventSwatch(colour));
      await tester.tap(eventSwatch(colour));
      await tester.pumpAndSettle();
      expectEventSelection(tester, colour);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        repo
            .academicEvents(today)
            .firstWhere((e) => e.title == colour.label)
            .colour,
        colour,
      );
    }
    final events = repo.academicEvents(today);
    for (final event in events) {
      final marker = find.byKey(ValueKey('event-marker-${event.id}'));
      expect(tester.widget<PlanningColourMarker>(marker).colour, event.colour);
      if (phone) {
        expect(
          tester
              .getSize(
                find.byKey(
                  ValueKey('event-indicator-$date-${event.colour.name}'),
                ),
              )
              .height,
          6,
        );
        final segment = tester.widget<Container>(
          find.byKey(ValueKey('event-indicator-$date-${event.colour.name}')),
        );
        expect(
          (segment.decoration as BoxDecoration).color,
          event.colour.background(brightness),
        );
      }
    }
    if (phone) {
      expect(
        tester.widget<Text>(find.byKey(ValueKey('event-count-$date'))).data,
        '5',
      );
    } else {
      expect(find.text('+3 more'), findsOneWidget);
      for (final event in events.take(2)) {
        final badge = find.byKey(ValueKey('event-badge-${event.id}'));
        expect(
          (tester.widget<Container>(badge).decoration as BoxDecoration).color,
          event.colour.background(brightness),
        );
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
      final badge = find.byKey(ValueKey('event-badge-${events.first.id}'));
      await tester.ensureVisible(badge);
      await tester.tap(badge);
      await tester.pumpAndSettle();
      expectEventSelection(tester, events.first.colour);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
    for (final event in events) {
      final tile = find.byKey(ValueKey('event-details-${event.id}'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expectEventSelection(tester, event.colour);
      await tester.ensureVisible(eventSwatch(ScheduleColour.black));
      await tester.tap(eventSwatch(ScheduleColour.black));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        repo.academicEvents(today).firstWhere((e) => e.id == event.id).colour,
        event.colour,
      );
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expectEventSelection(tester, event.colour);
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        '${event.title} edited',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        repo.academicEvents(today).firstWhere((e) => e.id == event.id).colour,
        event.colour,
      );
    }
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('event-details-${events.first.id}')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('month-today')));
    await tester.pumpAndSettle();
    final tile = find.byKey(ValueKey('event-details-${events.first.id}'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(repo.academicEvents(today), hasLength(4));
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    repo.close();
  }
}
