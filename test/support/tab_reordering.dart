import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'navigation.dart';

/// Exercises actual handles/switches, shared by widget and native acceptance
Future<void> exerciseTabReordering(
  WidgetTester tester, {
  required bool touch,
}) async {
  final c = ProviderScope.containerOf(
    tester.element(find.byType(StudyShell)),
  ).read(studyProvider);
  final month = find.byKey(const ValueKey('tab-month'));
  await selectTab(tester, StudyTab.month);
  await tester.pumpAndSettle();
  expect(find.byType(MonthlyScreen), findsOneWidget);
  Future<void> openSettings() async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('tab-drag-${c.tabOrder.last.name}')),
      220,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 30,
    );
    await tester.ensureVisible(
      find.byKey(ValueKey('tab-drag-${c.tabOrder.first.name}')),
    );
    await tester.pumpAndSettle();
  }

  await openSettings();
  final handle = find.byKey(const ValueKey('tab-drag-month'));
  // A handle click does not toggle the adjacent visibility switch
  await tester.tap(handle);
  await tester.pumpAndSettle();
  expect(c.tabVisible(StudyTab.month), isTrue);
  final gesture = await tester.startGesture(
    tester.getCenter(handle),
    kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (touch) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  }
  await gesture.moveTo(
    tester.getCenter(find.byKey(const ValueKey('tab-drag-week'))) -
        const Offset(0, 60),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await gesture.up();
  await tester.pumpAndSettle();
  expect(c.tabOrder, [
    StudyTab.month,
    StudyTab.week,
    StudyTab.todo,
    StudyTab.journal,
    StudyTab.review,
    StudyTab.schedule,
  ]);
  expect(c.tabOrder.every(c.tabVisible), isTrue);
  final progressDrag = await tester.startGesture(
    tester.getCenter(find.byKey(const ValueKey('tab-drag-week'))),
    kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (touch) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  }
  await progressDrag.moveTo(
    tester.getCenter(find.byKey(const ValueKey('tab-drag-schedule'))) +
        const Offset(0, 60),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await progressDrag.up();
  await tester.pumpAndSettle();
  expect(c.tabOrder.last, StudyTab.week);
  c.reorderTab(5, 1);
  await tester.pumpAndSettle();
  await tester.pageBack();
  await tester.pumpAndSettle();
  expect(
    find.byType(MonthlyScreen),
    findsOneWidget,
    reason: 'Reordering keeps the selected tab by ID',
  );
  if (touch) {
    await openNavigation(tester);
    expect(
      tester.getTopLeft(month).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('tab-week'))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('tab-week'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('tab-journal'))).dy),
    );
    await tester.tap(month);
    await tester.pumpAndSettle();
  } else {
    expect(
      tester.getTopLeft(month).dx,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('tab-journal'))).dx),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('tab-week'))).dx,
      greaterThan(tester.getTopLeft(month).dx),
    );
  }
  await openSettings();
  await tester.tap(find.widgetWithText(SwitchListTile, 'Monthly View'));
  await tester.pumpAndSettle();
  await tester.pageBack();
  await tester.pumpAndSettle();
  expect(month, findsNothing);
  expect(find.byKey(const ValueKey('input-Research')), findsOneWidget);
  expect(c.tabOrder.first, StudyTab.month);
  await openSettings();
  await tester.tap(find.widgetWithText(SwitchListTile, 'Monthly View'));
  await tester.pumpAndSettle();
  await tester.pageBack();
  await tester.pumpAndSettle();
  expect(c.tabOrder.first, StudyTab.month);
  await openNavigation(tester);
  expect(month, findsOneWidget);
  if (touch) {
    await tester.tap(find.byKey(const ValueKey('tab-week')));
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
}
