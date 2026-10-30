import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/presentation/app.dart';
import 'support/topic_reordering.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    final touch = platform == TargetPlatform.android;
    late LocalStudyRepository repo;
    late StudyController c;
    Finder key(String value) => find.byKey(ValueKey(value));
    Future<void> launch(WidgetTester tester) async {
      tester.view.physicalSize = Size(touch ? 360 : 1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
      repo.setPreference(
        'tab.order',
        '["todo","week","journal","review","schedule","month"]',
      );
      c = StudyController(repo, watchClock: false);
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

    testWidgets(
      'whole topics and their tasks drag independently on $platform',
      (tester) async {
        await launch(tester);
        expect(
          find.text('No topics yet. Add a topic to get started.'),
          findsOneWidget,
        );
        await exerciseTopicReordering(tester, touch: touch);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'large topic can auto-scroll past off-screen groups on $platform',
      (tester) async {
        await launch(tester);
        final ids = List.generate(18, (i) => repo.addTodoTopic('Topic $i'));
        for (var i = 0; i < 40; i++) {
          repo.addTodoTask(ids.first, 'Large group task $i');
        }
        for (final id in ids.skip(1)) {
          repo.addTodoTask(id, 'Task in $id');
        }
        c.refresh();
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(key('topic-menu-${ids.first}')),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 80),
          );
        }
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump();
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: key('todo-scroll'),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        final viewport = tester.getRect(key('todo-scroll'));
        await gesture.moveTo(Offset(viewport.left + 60, viewport.bottom - 2));
        for (var i = 0; i < 800; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (scroll.pixels >= scroll.maxScrollExtent - 1) break;
        }
        expect(scroll.pixels, greaterThan(2000));
        expect(scroll.pixels, closeTo(scroll.maxScrollExtent, 1));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(repo.todoTopics().map((t) => t.id), [...ids.skip(1), ids.first]);
        expect(repo.todoTasks(ids.first).length, 40);
        final sourceY = tester.getTopLeft(key('topic-menu-${ids.first}')).dy;
        scroll.jumpTo(
          (scroll.pixels + sourceY - viewport.top - 24).clamp(
            0,
            scroll.maxScrollExtent,
          ),
        );
        await tester.pumpAndSettle();
        final reverse = await tester.startGesture(
          tester.getTopLeft(key('topic-menu-${ids.first}')) +
              const Offset(20, 12),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 80),
          );
        }
        await reverse.moveBy(const Offset(0, -25));
        await tester.pump();
        await reverse.moveTo(Offset(viewport.left + 60, viewport.top + 2));
        for (var i = 0; i < 800; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (scroll.pixels <= 1) break;
        }
        expect(scroll.pixels, closeTo(0, 1));
        await reverse.up();
        await tester.pumpAndSettle();
        expect(repo.todoTopics().map((t) => t.id), ids);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'task drag scrolls through a long group independently on $platform',
      (tester) async {
        await launch(tester);
        final a = repo.addTodoTopic('Before');
        final b = repo.addTodoTopic('Long task list');
        final d = repo.addTodoTopic('After');
        final ids = List.generate(30, (i) => repo.addTodoTask(b, 'Task $i'));
        c.refresh();
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(key('task-body-${ids.first}')),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 80),
          );
        }
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump();
        final viewport = tester.getRect(key('todo-scroll'));
        await gesture.moveTo(Offset(viewport.left + 90, viewport.bottom - 2));
        for (var i = 0; i < 160; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(repo.todoTasks(b).map((t) => t.id), [...ids.skip(1), ids.first]);
        expect(repo.todoTopics().map((t) => t.id), [a, b, d]);
        expect(repo.todoTasks(a), isEmpty);
        expect(repo.todoTasks(d), isEmpty);
        expect(key('topic-drag-preview'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'whole groups animate at boundaries without markers on $platform',
      (tester) async {
        await launch(tester);
        final a = repo.addTodoTopic('Empty source');
        final b = repo.addTodoTopic('Expanded destination');
        final d = repo.addTodoTopic('Empty last');
        final active = repo.addTodoTask(b, 'Destination active');
        final done = repo.addTodoTask(b, 'Destination finished');
        repo.completeTodoTask(done);
        c.refresh();
        await tester.pumpAndSettle();
        await tester.tap(key('finished-$b'));
        await tester.pumpAndSettle();
        final members = [
          'topic-menu-$b',
          'add-task-$b',
          'task-$active',
          'finished-$b',
          'task-$done',
        ];
        final before = {
          for (final id in members) id: tester.getTopLeft(key(id)).dy,
        };
        final height = tester.getSize(key('topic-group-$a')).height;
        final taskRows = repo.db.select('SELECT * FROM todo_tasks');
        final gesture = await tester.startGesture(
          tester.getCenter(key('topic-menu-$a')),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 80),
          );
        }
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump();
        final insideFinished = tester.getCenter(key('task-$done'));
        await gesture.moveTo(insideFinished);
        await tester.pump();
        expect(repo.todoTopics().map((t) => t.id), [a, b, d]);
        for (final id in members) {
          expect(tester.getTopLeft(key(id)).dy, closeTo(before[id]!, 1));
        }
        await tester.pump(const Duration(milliseconds: 100));
        final movement =
            before[members.first]! - tester.getTopLeft(key(members.first)).dy;
        expect(movement, greaterThan(0));
        expect(movement, lessThan(height));
        for (final id in members) {
          expect(
            before[id]! - tester.getTopLeft(key(id)).dy,
            closeTo(movement, 1),
          );
        }
        expect(tester.getSize(key('topic-drag-preview')).height, lessThan(100));
        final preview = tester.getRect(key('topic-drag-preview'));
        final viewport = tester.getRect(key('todo-scroll'));
        expect(preview.left, greaterThanOrEqualTo(viewport.left));
        expect(preview.right, lessThanOrEqualTo(viewport.right));
        if (touch) {
          expect(preview.width, 328);
        } else {
          final divider = tester.getRect(
            find.descendant(
              of: key('topic-group-$a'),
              matching: find.byType(Divider),
            ),
          );
          expect(preview.left, closeTo(divider.left, .01));
          expect(preview.right, closeTo(divider.right, .01));
        }
        expect(
          find.byWidgetPredicate((widget) {
            if (widget is! DecoratedBox ||
                widget.decoration is! BoxDecoration) {
              return false;
            }
            final border = (widget.decoration as BoxDecoration).border;
            return border is Border &&
                (border.top.width == 2 || border.bottom.width == 2);
          }),
          findsNothing,
        );
        expect(
          find.descendant(
            of: key('topic-group-$b'),
            matching: find.byWidgetPredicate((widget) => widget is DragTarget),
          ),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(repo.todoTopics().map((t) => t.id), [b, a, d]);
        expect(
          tester.getBottomLeft(key('task-$done')).dy,
          lessThan(tester.getTopLeft(key('topic-menu-$a')).dy),
        );
        expect(repo.db.select('SELECT * FROM todo_tasks'), taskRows);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets('canceled topic drag restores complete groups on $platform', (
      tester,
    ) async {
      await launch(tester);
      final a = repo.addTodoTopic('First');
      final b = repo.addTodoTopic('Second');
      repo.addTodoTask(b, 'Stays with second');
      c.refresh();
      await tester.pumpAndSettle();
      final before = repo.db.select('SELECT * FROM todo_topics');
      final start = tester.getCenter(key('topic-menu-$b'));
      final end = tester.getCenter(key('topic-menu-$a'));
      final gesture = await tester.startGesture(
        start,
        kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
      );
      if (touch) {
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
      }
      await gesture.moveBy(const Offset(0, -25));
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(key('topic-menu-$a')).dy, greaterThan(start.dy));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(repo.db.select('SELECT * FROM todo_topics'), before);
      expect(
        tester.getTopLeft(key('topic-menu-$a')).dy,
        lessThan(tester.getTopLeft(key('topic-menu-$b')).dy),
      );
      expect(key('topic-drag-preview'), findsNothing);
      await tester.tap(key('topic-menu-$a'));
      await tester.pumpAndSettle();
      expect(find.text('Rename topic'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(platform));

    if (!touch) {
      testWidgets('Windows preview matches dividers after window resizing', (
        tester,
      ) async {
        await launch(tester);
        final id = repo.addTodoTopic('Research');
        for (final width in [1600.0, 900.0, 2000.0]) {
          tester.view.physicalSize = Size(width, 850);
          for (final title in [
            'Research',
            'Mongol Raids',
            'Long topic title ' * 8,
          ]) {
            repo.renameTodoTopic(id, title);
            c.refresh();
            await tester.pumpAndSettle();
            final divider = tester.getRect(
              find.descendant(
                of: key('topic-group-$id'),
                matching: find.byType(Divider),
              ),
            );
            final gesture = await tester.startGesture(
              tester.getTopLeft(key('topic-menu-$id')) + const Offset(20, 12),
              kind: PointerDeviceKind.mouse,
            );
            await gesture.moveBy(const Offset(0, 30));
            await tester.pump();
            final preview = tester.getRect(key('topic-drag-preview'));
            expect(preview.left, closeTo(divider.left, .01));
            expect(preview.right, closeTo(divider.right, .01));
            expect(preview.width, closeTo(divider.width, .01));
            await gesture.cancel();
            await tester.pumpAndSettle();
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, variant: TargetPlatformVariant.only(platform));
    }

    testWidgets('single topic and stale topic drags are safe on $platform', (
      tester,
    ) async {
      await launch(tester);
      final a = repo.addTodoTopic('Long topic title ' * 8);
      c.refresh();
      await tester.pumpAndSettle();
      Future<TestGesture> start() async {
        final gesture = await tester.startGesture(
          tester.getTopLeft(key('topic-menu-$a')) + const Offset(20, 12),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 80),
          );
        }
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        return gesture;
      }

      var gesture = await start();
      expect(
        tester.getSize(key('topic-drag-preview')).width,
        touch
            ? 328
            : tester
                  .getSize(
                    find.descendant(
                      of: key('topic-group-$a'),
                      matching: find.byType(Divider),
                    ),
                  )
                  .width,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(repo.todoTopics().single.id, a);
      repo.renameTodoTopic(a, 'First');
      final b = repo.addTodoTopic('Second');
      c.refresh();
      await tester.pumpAndSettle();
      gesture = await start();
      final added = repo.addTodoTopic('Arrived remotely');
      c.refresh();
      await tester.pump();
      await gesture.moveTo(
        tester.getBottomLeft(key('topic-menu-$b')) + const Offset(20, -4),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(repo.todoTopics().map((t) => t.id), [a, b, added]);
      expect(c.error, contains('Topics changed'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(platform));
  }
}
