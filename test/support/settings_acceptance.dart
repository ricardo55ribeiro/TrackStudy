import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/domain/planning.dart';
import 'navigation.dart';

Future<void> exerciseCategorySettings(
  WidgetTester tester, {
  required bool touch,
}) async {
  final c = ProviderScope.containerOf(
    tester.element(find.byType(StudyShell)),
  ).read(studyProvider);
  final original = c.repository.categories().map((bar) => bar.id).toList();
  final bar = c.repository.categories()[1];
  FocusManager.instance.primaryFocus?.unfocus();
  await selectTab(tester, StudyTab.week);
  await tester.pumpAndSettle();
  Finder name(String id) => find.byKey(ValueKey('bar-name-$id'));
  expect(find.byIcon(Icons.drag_handle), findsNothing);
  expect(find.byKey(const ValueKey('add-bar')), findsOneWidget);
  final scroll = tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('progress-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
  scroll.jumpTo(0);
  await tester.pumpAndSettle();
  final start = tester.getCenter(name(bar.id));
  final target = tester.getTopLeft(name(original.first)) + const Offset(30, 4);
  final gesture = await tester.startGesture(
    start,
    kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (touch) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  }
  for (var step = 1; step <= 10; step++) {
    await gesture.moveTo(Offset.lerp(start, target, step / 10)!);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(const Duration(milliseconds: 500));
  await gesture.up();
  await tester.pumpAndSettle();
  expect(c.progress.first.categoryId, bar.id);
  expect(find.byType(PopupMenuItem<String>), findsNothing);
  await tester.tap(name(bar.id));
  await tester.pumpAndSettle();
  expect(find.text('Edit'), findsOneWidget);
  expect(find.text('Archive'), findsOneWidget);
  expect(find.text('Delete'), findsNothing);
  await tester.tap(find.text('Archive'));
  await tester.pumpAndSettle();
  expect(
    find.textContaining("this entire week's Progress Bars"),
    findsOneWidget,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
  await tester.pumpAndSettle();
  expect(c.progress.any((p) => p.categoryId == bar.id), isFalse);
  final archived = find.byKey(const ValueKey('archived-bars'));
  await tester.scrollUntilVisible(
    archived,
    180,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('progress-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(archived);
  await tester.pumpAndSettle();
  expect(find.byKey(ValueKey('restore-bar-${bar.id}')), findsNothing);
  await tester.tap(archived);
  await tester.pumpAndSettle();
  final restore = find.byKey(ValueKey('restore-bar-${bar.id}'));
  await tester.ensureVisible(restore);
  await tester.pumpAndSettle();
  expect(find.text(bar.config.name), findsOneWidget);
  expect(
    tester.widget<Text>(find.text(bar.config.name)).style!.decoration,
    isNull,
  );
  await tester.tap(restore);
  await tester.pumpAndSettle();
  expect(archived, findsNothing);
  expect(c.progress.first.categoryId, bar.id);
  expect(c.repository.categories().length, original.length);
  c.perform(() => c.repository.reorder(original));
  await tester.pumpAndSettle();
  scroll.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  expect(find.text('Categories'), findsNothing);
  expect(find.text('Add category'), findsNothing);
  await tester.pageBack();
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}
