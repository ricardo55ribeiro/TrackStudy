import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'navigation.dart';

Future<void> exerciseTopicReordering(
  WidgetTester tester, {
  required bool touch,
}) async {
  final c = ProviderScope.containerOf(
    tester.element(find.byType(StudyShell)),
  ).read(studyProvider);
  final repo = c.repository;
  final original = repo.todoTopics().map((t) => t.id).toList();
  final a = repo.addTodoTopic('Topic Alpha'),
      b = repo.addTodoTopic('Topic Beta');
  final a1 = repo.addTodoTask(a, 'Alpha active');
  final a2 = repo.addTodoTask(a, 'Alpha finished');
  repo.completeTodoTask(a2);
  final b1 = repo.addTodoTask(b, 'Beta first');
  final b2 = repo.addTodoTask(b, 'Beta second');
  repo.reorderTodoTopics([a, b, ...original]);
  c.refresh();
  FocusManager.instance.primaryFocus?.unfocus();
  await selectTab(tester, StudyTab.todo);
  await tester.pumpAndSettle();
  Finder key(String value) => find.byKey(ValueKey(value));
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
  scroll.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.tap(key('finished-$a'));
  await tester.pumpAndSettle();
  await tester.tap(key('topic-menu-$b'));
  await tester.pumpAndSettle();
  expect(find.text('Rename topic'), findsOneWidget);
  expect(find.text('Delete topic'), findsOneWidget);
  await tester.tap(find.text('Rename topic'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
  expect(find.byTooltip('Topic actions'), findsNothing);
  expect(find.byIcon(Icons.drag_handle), findsNothing);

  Future<void> drag(Finder from, Finder to) async {
    final start = tester.getCenter(from);
    final end = tester.getTopLeft(to) + const Offset(20, 6);
    final gesture = await tester.startGesture(
      start,
      kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
    );
    if (touch) {
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    }
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(start, end, i / 10)!);
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Topic actions'), findsNothing);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    if (!touch && key('topic-drag-preview').evaluate().isNotEmpty) {
      final preview = tester.getRect(key('topic-drag-preview'));
      final divider = tester.getRect(
        find.descendant(
          of: key('topic-group-$b'),
          matching: find.byType(Divider),
        ),
      );
      expect(preview.left, closeTo(divider.left, .01));
      expect(preview.right, closeTo(divider.right, .01));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  await drag(key('topic-menu-$b'), key('topic-menu-$a'));
  expect(repo.todoTopics().map((t) => t.id), [b, a, ...original]);
  final orderedWidgets = [
    'topic-menu-$b',
    'task-$b1',
    'task-$b2',
    'topic-menu-$a',
    'task-$a1',
    'finished-$a',
    'task-$a2',
  ];
  for (var i = 1; i < orderedWidgets.length; i++) {
    expect(
      tester.getTopLeft(key(orderedWidgets[i])).dy,
      greaterThan(tester.getTopLeft(key(orderedWidgets[i - 1])).dy),
    );
  }
  expect(repo.todoTasks(a).map((t) => t.id), [a1, a2]);
  expect(repo.todoTasks(b).map((t) => t.id), [b1, b2]);
  expect(repo.todoTasks(a).last.completed, isTrue);
  await drag(key('task-body-$b2'), key('task-body-$b1'));
  expect(repo.todoTasks(b).map((t) => t.id), [b2, b1]);
  expect(repo.todoTasks(a).map((t) => t.id), [a1, a2]);
  expect(repo.todoTopics().map((t) => t.id), [b, a, ...original]);
  await tester.tap(key('task-check-$b1'));
  await tester.pump();
  expect(repo.todoTasks(b).last.completed, isTrue);
  await tester.tap(key('task-check-$b1'));
  await tester.pump();
  expect(repo.todoTasks(b).last.completed, isFalse);
  await drag(key('add-task-$b'), key('topic-menu-$a'));
  expect(repo.todoTopics().map((t) => t.id), [b, a, ...original]);
  await tester.tap(key('add-task-$b'));
  await tester.pumpAndSettle();
  expect(find.widgetWithText(AlertDialog, 'Add Task'), findsOneWidget);
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  c.perform(() {
    repo.deleteTodoTopic(a);
    repo.deleteTodoTopic(b);
    repo.reorderTodoTopics(original);
  });
  await tester.pumpAndSettle();
  if (scroll.hasPixels) scroll.jumpTo(0);
  await tester.pumpAndSettle();
}
