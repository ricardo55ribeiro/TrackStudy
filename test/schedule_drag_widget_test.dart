import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/schedule.dart';
import 'package:trackstudy/presentation/schedule_layout.dart';

final preview = find.byKey(const ValueKey('schedule-selection-preview'));
final editor = find.byType(ScheduleEditor, skipOffstage: false);

Finder field(String label) => find.widgetWithText(TextField, label);

Finder viewport(Axis axis) => find.byWidgetPredicate(
  (widget) => widget is SingleChildScrollView && widget.scrollDirection == axis,
);

ScrollController scroll(WidgetTester tester, Axis axis) =>
    tester.widget<SingleChildScrollView>(viewport(axis)).controller!;

Offset atMinute(WidgetTester tester, double minute, {int first = 360}) {
  final top = tester.getTopLeft(find.text(WallTime.label(first))).dy;
  final left = tester.getTopLeft(viewport(Axis.vertical)).dx;
  return Offset(left + 180, top + (minute - first) * scheduleMinuteHeight);
}

Future<void> pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void expectEditor(WidgetTester tester, int day, String start, String end) {
  expect(editor, findsOneWidget);
  final weekday = find.descendant(
    of: editor,
    matching: find.byType(DropdownButtonFormField<int>),
  );
  expect(tester.state<FormFieldState<int>>(weekday).value, day);
  expect(
    tester.widget<TextField>(field('Start · HH:MM')).controller!.text,
    start,
  );
  expect(tester.widget<TextField>(field('End · HH:MM')).controller!.text, end);
}

class ScheduleFixture {
  ScheduleFixture(this.tester) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    tester.view.devicePixelRatio = android ? 2 : 1;
    tester.view.physicalSize = android
        ? const Size(1000, 1600)
        : const Size(800, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      repo.close();
    });
  }

  final WidgetTester tester;
  final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  DateTime now = DateTime(2026, 11, 23, 9);

  PointerDeviceKind get kind => defaultTargetPlatform == TargetPlatform.android
      ? PointerDeviceKind.touch
      : PointerDeviceKind.mouse;

  Future<void> launch({
    bool active = true,
    Brightness brightness = Brightness.light,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: ScheduleScreen(active: active, clock: () => now),
        ),
      ),
    ),
  );

  Future<TestGesture> press(Offset point, {int buttons = kPrimaryButton}) =>
      tester.startGesture(point, kind: kind, buttons: buttons);

  Future<TestGesture> hold(Offset point, {int buttons = kPrimaryButton}) async {
    final pointer = await press(point, buttons: buttons);
    await tester.pump(kLongPressTimeout);
    return pointer;
  }
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets('hold and drag previews the range and saves once', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    final brightness = fixture.kind == PointerDeviceKind.touch
        ? Brightness.light
        : Brightness.dark;
    await fixture.launch(brightness: brightness);
    await tester.pump();

    final pointer = await fixture.press(atMinute(tester, 552));
    await tester.pump(kLongPressTimeout - const Duration(milliseconds: 1));
    expect(preview, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(preview, findsOneWidget);
    expect(tester.getSize(preview).height, closeTo(42, 1e-6));

    await pointer.moveTo(atMinute(tester, 643));
    fixture.now = fixture.now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final rectangle = tester.getRect(preview);
    final view = tester.getRect(viewport(Axis.vertical));
    expect(rectangle.top, closeTo(atMinute(tester, 540).dy, 1e-6));
    expect(rectangle.bottom, closeTo(atMinute(tester, 660).dy, 1e-6));
    expect(rectangle.left, closeTo(view.left + 58, 1e-6));
    expect(rectangle.right, closeTo(view.right, 1e-6));
    final scheme = Theme.of(tester.element(preview)).colorScheme;
    expect(scheme.brightness, brightness);
    final decoration = tester.widget<DecoratedBox>(preview).decoration;
    expect(
      (decoration as BoxDecoration).color,
      scheme.primary.withValues(alpha: .22),
    );
    expect(editor, findsNothing);
    expect(fixture.repo.schedule(1), isEmpty);

    await pointer.up();
    await pumpDialog(tester);
    expect(preview, findsNothing);
    expectEditor(tester, 1, '09:00', '11:00');
    expect(find.text('Delete'), findsNothing);
    expect(fixture.repo.schedule(1), isEmpty);
    await tester.enterText(field('Title'), 'Study');
    await tester.tap(find.text('Save'));
    await pumpDialog(tester);
    expect(editor, findsNothing);
    final block = fixture.repo.schedule(1).single;
    expect(
      (block.title, block.startMinute, block.endMinute),
      ('Study', 540, 660),
    );
    block.validate();
  }, variant: platforms);

  testWidgets('short press does nothing and upward drag can be cancelled', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.tap(find.byKey(const ValueKey('weekday-2')));
    await tester.pump();
    await tester.pump();
    final point = atMinute(tester, 681);
    final click = await fixture.press(point);
    await click.up();
    await tester.pump(kLongPressTimeout);
    expect(preview, findsNothing);
    expect(editor, findsNothing);

    final pointer = await fixture.hold(point);
    await pointer.moveTo(atMinute(tester, 575));
    await tester.pump();
    expect(preview, findsOneWidget);
    await pointer.up();
    await pumpDialog(tester);
    expect(preview, findsNothing);
    expectEditor(tester, 2, '09:30', '11:30');
    await tester.tap(find.text('Cancel'));
    await pumpDialog(tester);
    expect(editor, findsNothing);
    expect(fixture.repo.schedule(2), isEmpty);
  }, variant: platforms);

  testWidgets('normal scrolling works and changes the picked time', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.pump();
    final controller = scroll(tester, Axis.vertical);
    final before = controller.offset;
    final point = atMinute(tester, 720);
    if (fixture.kind == PointerDeviceKind.touch) {
      final swipe = await fixture.press(point);
      await swipe.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 100));
      await swipe.moveBy(const Offset(0, -140));
      await tester.pump(kLongPressTimeout);
      expect(preview, findsNothing);
      await swipe.up();
    } else {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: point,
          scrollDelta: const Offset(0, 250),
        ),
      );
    }
    await tester.pump();
    expect(editor, findsNothing);
    expect(controller.offset, greaterThan(before));

    final scrolled = controller.offset;
    final pointer = await fixture.hold(atMinute(tester, 720));
    await pointer.moveTo(atMinute(tester, 750));
    await tester.pump();
    expect(controller.offset, scrolled);
    await pointer.up();
    await pumpDialog(tester);
    expectEditor(tester, 1, '12:00', '12:30');
  }, variant: platforms);

  testWidgets('pointer cancellation removes the preview and blocks creation', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.pump();
    final pointer = await fixture.hold(atMinute(tester, 570));
    await pointer.moveTo(atMinute(tester, 643));
    await tester.pump();
    expect(preview, findsOneWidget);
    await pointer.cancel();
    await pumpDialog(tester);
    expect(preview, findsNothing);
    expect(editor, findsNothing);
    expect(fixture.repo.schedule(1), isEmpty);
  }, variant: platforms);

  testWidgets('only the first touch can select a range', (tester) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.pump();
    final first = await fixture.press(atMinute(tester, 570));
    await first.moveBy(const Offset(0, -2));
    await tester.pump(kLongPressTimeout);
    expect(
      tester.getRect(preview).top,
      closeTo(atMinute(tester, 540).dy, 1e-6),
    );
    final second = await fixture.hold(atMinute(tester, 690));
    await second.moveTo(atMinute(tester, 750));
    await second.up();
    await tester.pump();
    expect(preview, findsOneWidget);
    expect(editor, findsNothing);
    await first.up();
    await pumpDialog(tester);
    expectEditor(tester, 1, '09:00', '09:30');
  }, variant: android);

  testWidgets('ignores hover, other buttons, the gutter and bottom padding', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.pump();
    final point = atMinute(tester, 570);
    final mouse = TestPointer(10, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(point));
    await tester.pump(kLongPressTimeout);
    expect(preview, findsNothing);
    for (final button in [kSecondaryButton, kTertiaryButton]) {
      final pointer = await fixture.hold(point, buttons: button);
      expect(preview, findsNothing);
      await pointer.up();
    }
    final gutterX = tester.getTopLeft(viewport(Axis.vertical)).dx + 20;
    final gutter = await fixture.hold(Offset(gutterX, point.dy));
    expect(preview, findsNothing);
    await gutter.up();
    final vertical = scroll(tester, Axis.vertical);
    vertical.jumpTo(vertical.position.maxScrollExtent);
    await tester.pump();
    final padding = await fixture.hold(atMinute(tester, 1448));
    expect(preview, findsNothing);
    await padding.up();
    expect(editor, findsNothing);
    final last = await fixture.hold(atMinute(tester, 1439));
    await last.moveTo(atMinute(tester, 1448));
    await last.up();
    await pumpDialog(tester);
    expectEditor(tester, 1, '23:30', '24:00');
  }, variant: windows);

  testWidgets(
    'horizontal overlap layout preserves empty and block hit targets',
    (tester) async {
      final fixture = ScheduleFixture(tester);
      for (var i = 0; i < 8; i++) {
        fixture.repo.saveSchedule(
          ScheduleBlock(
            id: '00000000-0000-4000-8000-00000000000$i',
            title: 'Class $i',
            weekday: 1,
            startMinute: i == 0 ? 315 : 540,
            endMinute: i == 0 ? 345 : 600,
          ),
        );
      }
      await fixture.launch();
      final horizontal = scroll(tester, Axis.horizontal);
      expect(horizontal.position.maxScrollExtent, greaterThan(150));
      horizontal.jumpTo(150);
      await tester.pump();

      final block = find.byKey(
        const ValueKey('block-00000000-0000-4000-8000-000000000003'),
      );
      final point = tester.getCenter(block);
      final occupied = await fixture.hold(point);
      expect(preview, findsNothing);
      await occupied.up();
      await tester.pump();
      expect(find.text('Add schedule block'), findsNothing);
      final click = await fixture.press(point);
      await click.up();
      await pumpDialog(tester);
      expect(find.text('Edit schedule block'), findsOneWidget);
      expectEditor(tester, 1, '09:00', '10:00');
      await tester.tap(find.text('Cancel'));
      await pumpDialog(tester);

      final pointer = await fixture.hold(atMinute(tester, 515, first: 300));
      await pointer.moveTo(atMinute(tester, 595, first: 300));
      await pointer.up();
      await pumpDialog(tester);
      expectEditor(tester, 1, '08:30', '10:00');
      expect(fixture.repo.schedule(1), hasLength(8));
      await tester.enterText(field('Title'), 'Overlapping study');
      await tester.tap(find.text('Save'));
      await pumpDialog(tester);
      final blocks = fixture.repo.schedule(1);
      expect(blocks, hasLength(9));
      expect(
        layoutSchedule(blocks).map((placement) => placement.lanes),
        contains(8),
      );
    },
    variant: windows,
  );

  testWidgets('weekday and tab changes cancel an active selection', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.pump();
    final monday = await fixture.hold(atMinute(tester, 570));
    expect(preview, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weekday-2')));
    await tester.pump();
    expect(preview, findsNothing);
    await monday.up();
    await pumpDialog(tester);
    expect(editor, findsNothing);
    final tuesday = await fixture.hold(atMinute(tester, 570));
    expect(preview, findsOneWidget);
    await fixture.launch(active: false);
    expect(preview, findsNothing);
    await tuesday.up();
    await pumpDialog(tester);
    expect(editor, findsNothing);
  }, variant: android);

  testWidgets('window focus, foreground and timeline origin changes cancel', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.pump();
    void focus(ViewFocusState state) => tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: state,
        direction: ViewFocusDirection.undefined,
      ),
    );

    final unfocused = await fixture.hold(atMinute(tester, 570));
    expect(preview, findsOneWidget);
    focus(ViewFocusState.unfocused);
    await tester.pump();
    expect(preview, findsNothing);
    focus(ViewFocusState.focused);
    await unfocused.up();
    await tester.pump();
    expect(editor, findsNothing);

    final backgrounded = await fixture.hold(atMinute(tester, 570));
    expect(preview, findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(preview, findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await backgrounded.up();
    await tester.pump();
    expect(editor, findsNothing);

    final shifted = await fixture.hold(atMinute(tester, 570));
    expect(preview, findsOneWidget);
    fixture.repo.saveSchedule(
      const ScheduleBlock(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Early block',
        weekday: 1,
        startMinute: 315,
        endMinute: 360,
      ),
    );
    ProviderScope.containerOf(
      tester.element(find.byType(ScheduleScreen)),
    ).read(studyProvider).refresh();
    await tester.pump();
    expect(preview, findsNothing);
    await shifted.up();
    await tester.pump();
    expect(editor, findsNothing);
  }, variant: windows);

  testWidgets('Add block keeps its defaults and supports manual minutes', (
    tester,
  ) async {
    final fixture = ScheduleFixture(tester);
    await fixture.launch();
    await tester.tap(find.text('Add block'));
    await pumpDialog(tester);
    expectEditor(tester, 1, '09:00', '10:00');
    await tester.enterText(field('Title'), 'Manual block');
    await tester.enterText(field('Start · HH:MM'), '12:45');
    await tester.enterText(field('End · HH:MM'), '13:23');
    await tester.tap(find.text('Save'));
    await pumpDialog(tester);
    final block = fixture.repo.schedule(1).single;
    expect((block.startMinute, block.endMinute), (765, 803));
  }, variant: windows);
}
