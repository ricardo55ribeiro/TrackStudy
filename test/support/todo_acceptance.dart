import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'navigation.dart';

Future<void> exerciseTodo(WidgetTester tester, {required bool touch}) async {
  final c = ProviderScope.containerOf(
    tester.element(find.byType(StudyShell)),
  ).read(studyProvider);
  Finder key(String value) => find.byKey(ValueKey(value));
  await selectTab(tester, StudyTab.todo);
  await tester.tap(key('add-topic'));
  await tester.pumpAndSettle();
  await tester.enterText(key('todo-name'), 'Native Research');
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  final topic = c.repository
      .todoTopics()
      .firstWhere((t) => t.title == 'Native Research')
      .id;
  for (final text in ['Native A', 'Native B', 'Native C']) {
    await tester.ensureVisible(key('add-task-$topic'));
    await tester.tap(key('add-task-$topic'));
    await tester.pumpAndSettle();
    await tester.enterText(key('todo-name'), text);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }
  final ids = c.repository.todoTasks(topic).map((t) => t.id).toList();
  expect(find.byIcon(Icons.more_horiz), findsNothing);
  await tester.tap(find.text('Native Research'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Rename topic'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
  final click = await tester.startGesture(
    tester.getCenter(find.text('Native A')),
    kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  await click.up();
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit task'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
  final drag = await tester.startGesture(
    tester.getCenter(key('task-body-${ids.last}')),
    kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (touch) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
  }
  final start = tester.getCenter(key('task-body-${ids.last}'));
  final target =
      tester.getTopLeft(key('task-body-${ids.first}')) + const Offset(30, 8);
  for (var step = 1; step <= 10; step++) {
    await drag.moveTo(Offset.lerp(start, target, step / 10)!);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(const Duration(milliseconds: 500));
  await drag.up();
  await tester.pumpAndSettle();
  expect(find.byType(PopupMenuItem<String>), findsNothing);
  expect(c.repository.todoTasks(topic).map((t) => t.id), [
    ids[2],
    ids[0],
    ids[1],
  ]);
  await tester.tap(key('task-check-${ids[2]}'));
  await tester.pump();
  expect(tester.widget<Checkbox>(key('task-check-${ids[2]}')).value, isTrue);
  await tester.tap(key('task-check-${ids[2]}'));
  await tester.pump();
  expect(c.repository.todoTasks(topic).first.completed, isFalse);
  await tester.tap(key('task-check-${ids[2]}'));
  await tester.pump();
  expect(key('task-${ids[2]}'), findsOneWidget);
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
  expect(key('task-${ids[2]}'), findsNothing);
  await tester.tap(key('finished-$topic'));
  await tester.pumpAndSettle();
  expect(key('task-${ids[2]}'), findsOneWidget);
  await tester.tap(key('task-check-${ids[2]}'));
  await tester.pump();
  expect(c.repository.todoTasks(topic).last.id, ids[2]);
  expect(c.repository.todoTasks(topic).last.completedAt, isNull);
  await tester.tap(key('task-check-${ids[0]}'));
  await tester.pump();
  expect(c.repository.todoTasks(topic).first.completed, isTrue);
  expect(tester.takeException(), isNull);
}
