import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/todo.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    final touch = platform == TargetPlatform.android;
    late LocalStudyRepository repo;
    late StudyController controller;
    Future<void> launch(WidgetTester tester, {bool seed = true}) async {
      tester.view.physicalSize = Size(touch ? 360 : 1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
      repo.setPreference(
        'tab.order',
        '["todo","week","journal","review","schedule","month"]',
      );
      if (seed) {
        final a = repo.addTodoTopic('Research');
        for (final text in ['Task A', 'Task B', 'Task C']) {
          repo.addTodoTask(a, text);
        }
        final b = repo.addTodoTopic('CSPH');
        repo.addTodoTask(b, 'Other topic');
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: const TrackStudyApp(),
        ),
      );
      await tester.pumpAndSettle();
      controller = ProviderScope.containerOf(
        tester.element(find.byType(TodoScreen)),
      ).read(studyProvider);
    }

    Finder key(String value) => find.byKey(ValueKey(value));
    Future<void> finish(WidgetTester tester) async =>
        tester.pumpWidget(const SizedBox());

    testWidgets(
      'To-do create, validate, edit, cancel and confirm deletion on $platform',
      (tester) async {
        await launch(tester, seed: false);
        expect(
          find.text('No topics yet. Add a topic to get started.'),
          findsOneWidget,
        );
        await tester.tap(key('add-topic'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.todoTopics(), isEmpty);
        expect(find.text('Enter a name before saving.'), findsOneWidget);
        if (touch) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pumpAndSettle();
        }
        await tester.enterText(key('todo-name'), '  Investigação  ');
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        final topic = repo.todoTopics().single.id;
        await tester.tap(key('add-task-$topic'));
        await tester.pumpAndSettle();
        await tester.enterText(key('todo-name'), 'Ler Capítulo 5');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final task = repo.todoTasks(topic).single.id;
        await tester.tap(find.text('Ler Capítulo 5'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit task'));
        await tester.pumpAndSettle();
        await tester.enterText(key('todo-name'), 'Cancelled edit');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).single.text, 'Ler Capítulo 5');
        expect(repo.todoTasks(topic).single.id, task);
        await tester.tap(find.text('Investigação'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename topic'));
        await tester.pumpAndSettle();
        await tester.enterText(key('todo-name'), 'Research');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.todoTopics().single.title, 'Research');
        await tester.tap(find.text('Research'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete topic'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('all of its active and finished tasks'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).length, 1);
        await tester.tap(find.text('Research'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete topic'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete topic'));
        await tester.pumpAndSettle();
        expect(repo.todoTopics(), isEmpty);
        expect(repo.todoTasks(topic), isEmpty);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'text menus, completed task actions and independent header Add Task on $platform',
      (tester) async {
        await launch(tester);
        final topic = repo.todoTopics().first.id;
        final task = repo.todoTasks(topic).first.id;
        expect(find.byIcon(Icons.more_horiz), findsNothing);
        expect(find.byIcon(Icons.more_vert), findsNothing);
        expect(key('add-task-$topic'), findsOneWidget);
        expect(
          tester.getCenter(key('add-task-$topic')).dy,
          closeTo(tester.getCenter(key('topic-$topic')).dy, 1),
        );
        await tester.tap(key('add-task-$topic'));
        await tester.pumpAndSettle();
        expect(key('todo-name'), findsOneWidget);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        final click = await tester.startGesture(
          tester.getCenter(find.text('Task A')),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await click.up();
        await tester.pumpAndSettle();
        expect(find.text('Edit task'), findsOneWidget);
        expect(repo.todoTasks(topic).first.completed, isFalse);
        await tester.tap(find.text('Edit task'));
        await tester.pumpAndSettle();
        await tester.enterText(key('todo-name'), 'Edited active task');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).first.text, 'Edited active task');
        await tester.tap(key('task-check-$task'));
        await tester.pump();
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.tap(key('finished-$topic'));
        await tester.pumpAndSettle();
        await tester.tap(key('task-body-$task'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit task'));
        await tester.pumpAndSettle();
        await tester.enterText(key('todo-name'), 'Edited finished task');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).first.completed, isTrue);
        expect(repo.todoTasks(topic).first.text, 'Edited finished task');
        await tester.tap(find.text('Edited finished task'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete task'));
        await tester.pumpAndSettle();
        expect(find.text('Delete task?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).length, 3);
        await tester.tap(key('task-body-$task'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete task'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete task'));
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).length, 2);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'independent five-second grace, undo, finished styling and immediate restore on $platform',
      (tester) async {
        await launch(tester);
        final topic = repo.todoTopics().first.id;
        final tasks = repo.todoTasks(topic), a = tasks[0].id, b = tasks[1].id;
        final original = tester.getTopLeft(key('task-$a')).dy;
        await tester.tap(key('task-check-$a'));
        await tester.pump();
        expect(repo.todoTasks(topic).first.completed, isTrue);
        expect(tester.widget<Checkbox>(key('task-check-$a')).value, isTrue);
        expect(tester.getTopLeft(key('task-$a')).dy, original);
        await tester.pump(const Duration(seconds: 2));
        await tester.tap(key('task-check-$b'));
        await tester.pump();
        await tester.tap(key('task-check-$a'));
        await tester.pump();
        expect(repo.todoTasks(topic).first.completed, isFalse);
        await tester.pump(const Duration(seconds: 4));
        expect(key('task-$b'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(key('task-$b'), findsNothing);
        expect(key('task-$a'), findsOneWidget);
        expect(key('finished-$topic'), findsOneWidget);
        await tester.tap(key('finished-$topic'));
        await tester.pumpAndSettle();
        expect(key('task-$b'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('Task B')).style!.decoration,
          TextDecoration.lineThrough,
        );
        expect(
          tester.widget<Text>(find.text('Task B')).style!.fontSize,
          lessThan(tester.widget<Text>(find.text('Task A')).style!.fontSize!),
        );
        expect(
          find.ancestor(
            of: key('task-body-$b'),
            matching: find.byType(ReorderableDragStartListener),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: key('task-body-$b'),
            matching: find.byType(ReorderableDelayedDragStartListener),
          ),
          findsNothing,
        );
        await tester.tap(key('task-check-$b'));
        await tester.pump();
        expect(repo.todoTasks(topic).last.id, b);
        expect(repo.todoTasks(topic).last.completedAt, isNull);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(repo.todoTasks(topic).length, 3);
        expect(key('finished-$topic'), findsNothing);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'actual row drag has no handle, stays in topic and cannot toggle checkbox on $platform',
      (tester) async {
        await launch(tester);
        final topic = repo.todoTopics().first.id;
        final before = repo.todoTasks(topic).map((t) => t.id).toList();
        expect(find.byIcon(Icons.drag_handle), findsNothing);
        final gesture = await tester.startGesture(
          tester.getCenter(key('task-body-${before[2]}')),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 50),
          );
        }
        final start = tester.getCenter(key('task-body-${before[2]}'));
        final target =
            tester.getTopLeft(key('task-body-${before[0]}')) +
            const Offset(30, 8);
        for (var step = 1; step <= 10; step++) {
          await gesture.moveTo(Offset.lerp(start, target, step / 10)!);
          await tester.pump(const Duration(milliseconds: 40));
        }
        await tester.pump(const Duration(milliseconds: 500));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(repo.todoTasks(topic).map((t) => t.id), [
          before[2],
          before[0],
          before[1],
        ]);
        expect(repo.todoTasks(topic).every((t) => !t.completed), isTrue);
        final foreign = repo.todoTopics().last.id;
        expect(repo.todoTasks(foreign).single.text, 'Other topic');
        final cross = await tester.startGesture(
          tester.getCenter(key('task-body-${before[2]}')),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 50),
          );
        }
        await cross.moveTo(tester.getCenter(find.text('Other topic')));
        await tester.pump(const Duration(milliseconds: 500));
        await cross.up();
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(repo.todoTasks(topic).length, 3);
        expect(repo.todoTasks(foreign).length, 1);
        final order = repo.todoTasks(topic).map((t) => t.id).toList();
        final checkbox = await tester.startGesture(
          tester.getCenter(key('task-check-${before[0]}')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await checkbox.moveBy(const Offset(0, 70));
        await checkbox.up();
        await tester.pumpAndSettle();
        expect(repo.todoTasks(topic).map((t) => t.id), order);
        expect(repo.todoTasks(topic).every((t) => !t.completed), isTrue);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'remote changes, deletion and disposal cancel grace without stale writes on $platform',
      (tester) async {
        await launch(tester);
        final topic = repo.todoTopics().first.id;
        final a = repo.todoTasks(topic).first.id;
        await tester.tap(key('task-check-$a'));
        await tester.pump();
        repo.restoreTodoTask(a);
        controller.refresh();
        await tester.pump();
        expect(tester.widget<Checkbox>(key('task-check-$a')).value, isFalse);
        await tester.pump(const Duration(seconds: 6));
        expect(
          repo.todoTasks(topic).where((t) => t.id == a).single.completed,
          isFalse,
        );
        await tester.tap(key('task-check-$a'));
        await tester.pump();
        repo.deleteTodoTask(a);
        controller.refresh();
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        expect(key('task-$a'), findsNothing);
        final b = repo.todoTasks(topic).first.id;
        await tester.tap(key('task-check-$b'));
        await tester.pump();
        repo.deleteTodoTopic(topic);
        controller.refresh();
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        expect(key('topic-$topic'), findsNothing);
        final other = repo.todoTopics().single.id,
            last = repo.todoTasks(repo.todoTopics().single.id).single.id;
        await tester.tap(key('task-check-$last'));
        await tester.pump();
        await finish(tester);
        await tester.pump(const Duration(seconds: 6));
        expect(repo.todoTasks(other).single.completed, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'finished sections default closed, expand independently and sort by time with ties on $platform',
      (tester) async {
        await launch(tester);
        final topics = repo.todoTopics(),
            a = topics.first.id,
            b = topics.last.id;
        final tasks = repo.todoTasks(a);
        repo.db.execute('UPDATE todo_tasks SET completed_at=? WHERE id=?', [
          '2026-10-26T10:00:00Z',
          tasks[0].id,
        ]);
        repo.db.execute('UPDATE todo_tasks SET completed_at=? WHERE id=?', [
          '2026-10-26T11:00:00Z',
          tasks[1].id,
        ]);
        repo.completeTodoTask(repo.todoTasks(b).single.id);
        controller.refresh();
        await tester.pump();
        expect(find.text('Task A'), findsNothing);
        expect(find.text('Task B'), findsNothing);
        await tester.tap(key('finished-$a'));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.text('Task B')).dy,
          lessThan(tester.getTopLeft(find.text('Task A')).dy),
        );
        repo.db.execute('UPDATE todo_tasks SET completed_at=? WHERE id=?', [
          '2026-10-26T11:00:00Z',
          tasks[0].id,
        ]);
        controller.refresh();
        await tester.pumpAndSettle();
        final tied = [tasks[0], tasks[1]]..sort((a, b) => a.id.compareTo(b.id));
        expect(
          tester.getTopLeft(key('task-${tied.first.id}')).dy,
          lessThan(tester.getTopLeft(key('task-${tied.last.id}')).dy),
        );
        expect(find.text('Other topic'), findsNothing);
        await tester.ensureVisible(key('finished-$b'));
        await tester.tap(key('finished-$b'));
        await tester.pumpAndSettle();
        expect(find.text('Other topic'), findsOneWidget);
        expect(find.text('Task B'), findsOneWidget);
        await tester.tap(key('finished-$a'));
        await tester.pumpAndSettle();
        expect(find.text('Task A'), findsNothing);
        expect(find.text('Other topic'), findsOneWidget);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'remote recompletion cancels grace and reopening shows durable completion on $platform',
      (tester) async {
        await launch(tester);
        final topic = repo.todoTopics().first.id;
        final id = repo.todoTasks(topic).first.id;
        await tester.tap(key('task-check-$id'));
        await tester.pump();
        repo.db.execute('UPDATE todo_tasks SET completed_at=? WHERE id=?', [
          '2026-10-27T12:00:00Z',
          id,
        ]);
        controller.refresh();
        await tester.pump();
        expect(key('task-$id'), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        expect(repo.todoTasks(topic).first.completedAt, '2026-10-27T12:00:00Z');
        await tester.tap(key('finished-$topic'));
        await tester.pumpAndSettle();
        expect(key('task-$id'), findsOneWidget);
        await finish(tester);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repositoryProvider.overrideWithValue(repo)],
            child: const TrackStudyApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(key('task-$id'), findsNothing);
        expect(key('finished-$topic'), findsOneWidget);
        await tester.tap(key('finished-$topic'));
        await tester.pumpAndSettle();
        expect(key('task-$id'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'long names, keyboard and many topics keep Add Topic accessible on $platform',
      (tester) async {
        await launch(tester, seed: false);
        if (touch) tester.view.physicalSize = const Size(320, 640);
        final topic = repo.addTodoTopic(
          List.filled(25, 'Investigação').join(' '),
        );
        repo.addTodoTask(topic, List.filled(40, 'Ler Capítulo 5').join(' '));
        for (var i = 0; i < 30; i++) {
          repo.addTodoTopic('Topic $i');
        }
        controller.refresh();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(key('add-task-$topic').hitTestable(), findsOneWidget);
        await tester.tap(key('add-task-$topic'));
        await tester.pumpAndSettle();
        expect(key('todo-name'), findsOneWidget);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(key('add-topic').hitTestable(), findsOneWidget);
        await tester.tap(key('add-topic'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        await tester.enterText(key('todo-name'), 'Keyboard safe');
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.todoTopics().last.title, 'Keyboard safe');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
