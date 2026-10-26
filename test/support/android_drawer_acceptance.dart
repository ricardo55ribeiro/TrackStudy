import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/android_navigation.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'navigation.dart';

Future<void> exerciseAndroidDrawer(WidgetTester tester) async {
  final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
  final title = find.byKey(const ValueKey('android-tab-title'));
  expect(scaffold.isDrawerOpen, isFalse);
  expect(find.byKey(const ValueKey('tab-month')), findsNothing);
  expect(tester.widget<Text>(title).data, 'Progress Bars');
  expect(find.byTooltip('Settings'), findsOneWidget);
  await openNavigation(tester);
  expect(scaffold.isDrawerOpen, isTrue);
  expect(
    tester
        .widgetList<AndroidTabItem>(find.byType(AndroidTabItem))
        .map((e) => e.title),
    StudyTab.values.map((e) => e.label),
  );
  expect(
    find.descendant(
      of: find.byType(Drawer),
      matching: find.byTooltip('Settings'),
    ),
    findsNothing,
  );
  await tester.tap(find.byKey(const ValueKey('tab-month')));
  await tester.pumpAndSettle();
  expect(scaffold.isDrawerOpen, isFalse);
  expect(find.byType(MonthlyScreen), findsOneWidget);
  expect(tester.widget<Text>(title).data, 'Monthly View');
  await openNavigation(tester);
  final selected = tester.widget<AndroidTabItem>(
    find.byKey(const ValueKey('tab-month')),
  );
  expect(selected.selected, isTrue);
  expect(
    tester
        .widgetList<AndroidTabItem>(find.byType(AndroidTabItem))
        .where((e) => e.selected)
        .length,
    1,
  );
  await tester.tap(find.byKey(const ValueKey('tab-month')));
  await tester.pumpAndSettle();
  expect(scaffold.isDrawerOpen, isFalse);
  expect(find.byType(MonthlyScreen), findsOneWidget);
  await openNavigation(tester);
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(scaffold.isDrawerOpen, isFalse);
  expect(find.byType(MonthlyScreen), findsOneWidget);
  await openNavigation(tester);
  final size = tester.getSize(find.byType(Scaffold).first);
  await tester.tapAt(Offset(size.width - 4, size.height / 2));
  await tester.pumpAndSettle();
  expect(scaffold.isDrawerOpen, isFalse);
  await selectTab(tester, StudyTab.week);
  await tester.pumpAndSettle();
  expect(tester.widget<Text>(title).data, 'Progress Bars');
  expect(tester.takeException(), isNull);
}
