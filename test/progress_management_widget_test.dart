import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/progress_bar.dart';
import 'support/navigation.dart';

void main() {
  final week = Week.parse('2026-10-26');
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    late LocalStudyRepository repo;
    late StudyController c;
    final android = platform == TargetPlatform.android;
    Future<void> launch(WidgetTester tester) async {
      tester.view.physicalSize = Size(android ? 320 : 1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      repo = LocalStudyRepository(
        StudyDatabase(sqlite3.openInMemory()),
        clock: () => DateTime(2026, 10, 28),
      );
      c = StudyController(
        repo,
        clock: () => DateTime(2026, 10, 28),
        watchClock: false,
      );
      addTearDown(repo.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            studyProvider.overrideWith((ref) => c),
          ],
          child: const TrackStudyApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> finish(WidgetTester tester) async {
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets(
      'only names manage bars while inputs, graph, undo and history stay independent on $platform',
      (tester) async {
        await launch(tester);
        expect(find.byKey(const ValueKey('archived-bars')), findsNothing);
        await tester.tap(find.byType(WeeklyProgressBar).first);
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('input-Research')),
          '1.5',
        );
        await tester.tap(find.byKey(const ValueKey('add-Research')));
        await tester.pumpAndSettle();
        expect(find.text('1.5 / 8 h'), findsOneWidget);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        await tester.tap(find.text('1.5 / 8 h'));
        await tester.pumpAndSettle();
        expect(find.text('Research · entries'), findsOneWidget);
        expect(find.text('Archive'), findsNothing);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('undo-Research')));
        await tester.pumpAndSettle();
        expect(c.progress.first.total, 0);
        expect(
          repo.entries(c.progress.first.goalId).single.undoneAt,
          isNotNull,
        );
        await tester.tap(find.text('Research'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<PopupMenuItem<String>>(
                find.byType(PopupMenuItem<String>),
              )
              .map((item) => item.value),
          ['edit', 'archive'],
        );
        await tester.tap(find.text('Archive'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(c.progress.length, 7);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'empty active list retains Add Bar and compact archived management on $platform',
      (tester) async {
        await launch(tester);
        for (final bar in repo.categories()) {
          c.archiveBar(bar.id, true, week);
        }
        await tester.pumpAndSettle();
        expect(find.byType(WeeklyProgressBar), findsNothing);
        expect(find.text('Archived Bars (7)'), findsOneWidget);
        expect(find.text('Restore'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('archived-bars')));
        await tester.pumpAndSettle();
        expect(find.byType(WeeklyProgressBar), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.byIcon(Icons.drag_handle), findsNothing);
        expect(find.byType(ReorderableDragStartListener), findsNothing);
        expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
        await tester.tap(find.byKey(const ValueKey('add-bar')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          'New bar',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(c.progress.single.config.name, 'New bar');
        expect(find.byType(WeeklyProgressBar), findsOneWidget);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'historical dashboard and review share inclusion while written review stays intact on $platform',
      (tester) async {
        await launch(tester);
        final previous = week.shift(-1);
        final first = repo.loadWeek(previous, current: previous).first;
        repo.commit(first.goalId, 200, previous);
        repo.saveReview(
          WeeklyReview(week: previous.key, danger: 'Research notes stay here'),
        );
        repo.setCategoryStatus(
          first.categoryId,
          current: previous,
          active: false,
          archived: true,
        );
        repo.setCategoryStatus(
          first.categoryId,
          current: week,
          active: true,
          archived: false,
        );
        c.navigate(previous);
        await tester.pumpAndSettle();
        expect(find.text('Research'), findsNothing);
        expect(find.byKey(const ValueKey('add-bar')), findsNothing);
        expect(find.byKey(const ValueKey('archived-bars')), findsNothing);
        expect(find.byType(PopupMenuButton<String>), findsNothing);
        expect(find.byType(ReorderableDragStartListener), findsNothing);
        expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
        await tester.tap(find.text('CSPH'));
        await tester.pumpAndSettle();
        expect(find.text('Archive'), findsNothing);
        final order = repo.categories().map((bar) => bar.id).toList();
        c.reorderCategory(0, 1);
        c.archiveBar(first.categoryId, true, previous);
        expect(repo.categories().map((bar) => bar.id), order);
        expect(repo.categories().first.active, isTrue);
        await selectTab(tester, StudyTab.review);
        await tester.pumpAndSettle();
        expect(find.text('Research'), findsNothing);
        expect(repo.review(previous).danger, 'Research notes stay here');
        expect(repo.entries(first.goalId).single.amount, 200);
        c.navigate(week);
        await tester.pumpAndSettle();
        expect(find.text('Research'), findsOneWidget);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'long names remain within the name area and tracking controls cannot drag on $platform',
      (tester) async {
        await launch(tester);
        final p = c.progress.first;
        repo.saveCategory(
          p.categoryId,
          GoalConfig(
            name: 'L' * 80,
            measurement: Measurement.continuous,
            unit: 'h',
            floor: 600,
            target: 800,
            increment: 100,
            step: 25,
          ),
          week,
        );
        c.refresh();
        await tester.pumpAndSettle();
        final name = find.byKey(ValueKey('bar-name-${p.categoryId}'));
        final input = find.byKey(ValueKey('input-${'L' * 80}'));
        expect(
          tester.getRect(name).right,
          lessThanOrEqualTo(tester.getRect(input).left),
        );
        final before = repo.categories().map((bar) => bar.id).toList();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(WeeklyProgressBar).first),
          kind: android ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (android) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 50),
          );
        }
        await gesture.moveBy(const Offset(0, 90));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(repo.categories().map((bar) => bar.id), before);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
