import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/presentation/app.dart';

void main() {
  void desktopTest(String name, WidgetTesterCallback callback) => testWidgets(
    name,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  setUpAll(() async {
    if (Platform.environment['CAPTURE_SCREENSHOTS'] == '1' &&
        Platform.isWindows) {
      final font = FontLoader('Segoe UI');
      for (final filename in ['segoeui.ttf', 'segoeuib.ttf']) {
        font.addFont(
          File(
            'C:/Windows/Fonts/$filename',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      }
      await font.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  late LocalStudyRepository repository;
  setUp(() {
    repository = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  });
  tearDown(() {
    repository.close();
  });
  Future<void> launch(
    WidgetTester tester, {
    Size size = const Size(1040, 820),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: RepaintBoundary(
          key: const ValueKey('capture'),
          child: const TrackStudyApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (Platform.environment['CAPTURE_SCREENSHOTS'] != '1') {
      return;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('docs/screenshots')
        ..createSync(recursive: true);
      File(
        '${directory.path}/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  desktopTest(
    'main workflow, compact numbers, keyboard, undo, capped progress and resize',
    (tester) async {
      await launch(tester);
      for (final name in [
        'Research',
        'CSPH',
        'NLP',
        'IAES',
        'Gym',
        'Sleep',
        'Wake-up',
      ]) {
        expect(find.text(name), findsOneWidget);
        final field = tester.widget<TextField>(
          find.byKey(ValueKey('input-$name')),
        );
        expect(field.controller!.text, isEmpty);
        expect(field.decoration!.hintText, isNull);
      }
      for (final forbidden in [
        'Current',
        'Floor',
        'Target',
        'Unit',
        'Last Commit',
      ]) {
        expect(find.text(forbidden), findsNothing);
      }
      await capture(tester, 'dashboard-light');
      final input = find.byKey(const ValueKey('input-Research')),
          add = find.byKey(const ValueKey('add-Research')),
          undo = find.byKey(const ValueKey('undo-Research'));
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.textContaining('Use a number'), findsOneWidget);
      expect(find.text('0 / 8 h'), findsNWidgets(2));
      await tester.enterText(input, '-1');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.textContaining('Use a number'), findsOneWidget);
      expect(
        repository.entries(
          repository
              .loadWeek(
                Week.containing(DateTime.now()),
                current: Week.containing(DateTime.now()),
              )
              .first
              .goalId,
        ),
        isEmpty,
      );
      await tester.enterText(input, '1.5');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('1.5 / 8 h'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      await tester.enterText(input, '2.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('4 / 8 h'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await capture(tester, 'dashboard-progress');
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(find.text('1.5 / 8 h'), findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(undo).onPressed, isNull);
      await tester.enterText(input, '10');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('10 / 8 h'), findsOneWidget);
      await tester.enterText(input, '2');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(tester.widget<TextField>(input).controller!.text, '');
      final week = Week.containing(DateTime.now());
      expect(repository.loadWeek(week, current: week).first.total, 1000);
      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
      expect(find.text('Past week · return to today'), findsOneWidget);
      await tester.tap(find.byTooltip('Next week'));
      await tester.pumpAndSettle();
      expect(find.text('10 / 8 h'), findsOneWidget);
      final gymInput = find.byKey(const ValueKey('input-Gym'));
      final gymAdd = find.byKey(const ValueKey('add-Gym'));
      await tester.ensureVisible(gymAdd);
      await tester.tap(gymAdd);
      await tester.pumpAndSettle();
      expect(find.textContaining('Use a number'), findsOneWidget);
      expect(find.text('0 / 5'), findsOneWidget);
      await tester.enterText(gymInput, '1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('1 / 5'), findsOneWidget);
      expect(tester.widget<TextField>(gymInput).controller!.text, isEmpty);
      expect(tester.widget<TextField>(gymInput).focusNode!.hasFocus, isTrue);
      for (final size in [
        const Size(600, 700),
        const Size(400, 800),
        const Size(1400, 900),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(1040, 820);
      repository.setPreference('theme', 'dark');
      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next week'));
      await tester.pumpAndSettle();
      await capture(tester, 'dashboard-dark');
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    },
  );
  desktopTest(
    'settings current goal, category creation, archive and validation',
    (tester) async {
      await launch(tester);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Research'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Target'), '5');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('floor must be'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Target'), '10');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add category'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Open Source',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Open Source'), findsOneWidget);
      await tester.tap(find.byTooltip('Archive category').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
      await tester.pumpAndSettle();
      expect(find.text('Archived'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('0 / 10 h'), findsOneWidget);
      expect(find.text('Open Source'), findsNothing);
      await disposeApp(tester);
    },
  );
  desktopTest(
    'research journal three prompts, searchable history and latest Next',
    (tester) async {
      await launch(tester);
      await tester.tap(find.text('Research journal').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New entry'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Learned'),
        'The LLM stays frozen.',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Question'),
        'Which loss function?',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Next'),
        'Read section 3.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('PICK UP HERE'), findsOneWidget);
      // The latest-next summary and the entry's new standalone Next section.
      expect(find.text('Read section 3.'), findsNWidgets(2));
      await capture(tester, 'journal');
      await tester.enterText(
        find.widgetWithText(TextField, 'Search journal'),
        'loss',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Which loss function?', findRichText: true),
        findsOneWidget,
      );
      await disposeApp(tester);
    },
  );
  desktopTest(
    'review auto score, exactly three wins, saves across navigation',
    (tester) async {
      final week = Week.containing(DateTime.now());
      final p = repository.loadWeek(week, current: week).first;
      repository.commit(p.goalId, 700, week);
      await launch(tester);
      await tester.tap(find.text('Weekly review').first);
      await tester.pumpAndSettle();
      expect(find.text('7 / 8 h'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'What went wrong?'),
        'Avoided research until Thursday.',
      );
      expect(
        repository.review(week).wentWrong,
        'Avoided research until Thursday.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
      await capture(tester, 'weekly-review');
      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next week'));
      await tester.pumpAndSettle();
      expect(find.text('Avoided research until Thursday.'), findsOneWidget);
      await disposeApp(tester);
    },
  );
}
