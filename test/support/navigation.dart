import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/domain/planning.dart';

Future<void> openNavigation(WidgetTester tester) async {
  final menu = find.byTooltip('Open navigation menu');
  if (menu.evaluate().isNotEmpty) {
    await tester.tap(menu);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> selectTab(WidgetTester tester, StudyTab tab) async {
  await openNavigation(tester);
  final item = find.byKey(ValueKey('tab-${tab.name}'));
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
