import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/presentation/app.dart';

Future<void> exerciseCategorySettings(
  WidgetTester tester, {
  required bool touch,
}) async {
  final c = ProviderScope.containerOf(
    tester.element(find.byType(StudyShell)),
  ).read(studyProvider);
  final original = c.repository
      .categories()
      .map((category) => category.id)
      .toList();
  final gym = c.repository.categories().firstWhere(
    (category) => category.config.name == 'Gym',
  );
  final research = original.first;
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  Future<void> reveal(Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      120,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 40,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  expect(
    tester.getTopLeft(find.text('Appearance')).dy,
    lessThan(tester.getTopLeft(find.text('Tabs on this device')).dy),
  );
  await reveal(find.byKey(ValueKey('category-drag-${gym.id}')));
  final handle = find.byKey(ValueKey('category-drag-${gym.id}'));
  final toggle = find.byKey(ValueKey('category-toggle-${gym.id}'));
  final archive = find.byKey(ValueKey('category-archive-${gym.id}'));
  expect(tester.getCenter(archive).dx, lessThan(tester.getCenter(toggle).dx));
  expect(tester.getCenter(toggle).dx, lessThan(tester.getCenter(handle).dx));
  final target = find.byKey(ValueKey('category-drag-$research'));
  await tester.scrollUntilVisible(
    target,
    -120,
    scrollable: find.byType(Scrollable).last,
    maxScrolls: 30,
  );
  await tester.pumpAndSettle();
  final position = tester
      .state<ScrollableState>(find.byType(Scrollable).last)
      .position;
  position.jumpTo((position.pixels - 120).clamp(0, position.maxScrollExtent));
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    tester.getCenter(handle),
    kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (touch) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  }
  await gesture.moveTo(tester.getCenter(target) - Offset(0, touch ? 120 : 60));
  await tester.pump(const Duration(milliseconds: 500));
  await gesture.up();
  await tester.pumpAndSettle();
  expect(
    c.repository.categories().first.id,
    gym.id,
    reason: c.repository
        .categories()
        .map((category) => category.config.name)
        .join(', '),
  );
  expect(c.progress.first.categoryId, gym.id);
  await reveal(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  expect(c.repository.categories().first.active, isFalse);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  expect(c.repository.categories().first.active, isTrue);
  await tester.tap(archive);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
  await tester.pumpAndSettle();
  expect(c.progress.any((p) => p.categoryId == gym.id), isFalse);
  await reveal(find.text('Archived Categories'));
  expect(find.text('Gym'), findsNothing);
  await tester.tap(find.text('Archived Categories'));
  await tester.pumpAndSettle();
  await reveal(find.byTooltip('Restore category'));
  expect(find.text('Gym'), findsOneWidget);
  expect(handle, findsNothing);
  await reveal(find.text('Archived Categories'));
  await tester.tap(find.text('Archived Categories'));
  await tester.pumpAndSettle();
  expect(find.text('Gym'), findsNothing);
  await tester.tap(find.text('Archived Categories'));
  await tester.pumpAndSettle();
  await reveal(find.byTooltip('Restore category'));
  await tester.tap(find.byTooltip('Restore category'));
  await tester.pumpAndSettle();
  expect(c.repository.categories().first.id, gym.id);
  expect(c.progress.first.categoryId, gym.id);
  expect(find.text('Archived Categories'), findsNothing);
  expect(c.repository.categories().length, original.length);
  await tester.pageBack();
  await tester.pumpAndSettle();
  expect(
    tester.getTopLeft(find.text('Gym')).dy,
    lessThan(tester.getTopLeft(find.text('Research')).dy),
  );
  c.perform(() => c.repository.reorder(original));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}
