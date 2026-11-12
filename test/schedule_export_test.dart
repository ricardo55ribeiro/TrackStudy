import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/platform/schedule_png_file.dart';
import 'package:trackstudy/presentation/planning_colours.dart';
import 'package:trackstudy/presentation/schedule.dart';
import 'package:trackstudy/presentation/schedule_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'schedule export options validate days and hours',
    (tester) async {
      final repository = LocalStudyRepository(
        StudyDatabase(sqlite3.openInMemory()),
      );
      addTearDown(repository.close);
      if (defaultTargetPlatform == TargetPlatform.android) {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Scaffold(
              body: ScheduleScreen(
                active: false,
                clock: () => DateTime(2026, 11, 12),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        defaultTargetPlatform == TargetPlatform.android
            ? find.byTooltip('Export Daily Schedule')
            : find.text('Export'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Export Daily Schedule'), findsOneWidget);
      expect(find.text('08:00'), findsWidgets);
      expect(find.text('18:00'), findsWidgets);

      final chips = find.byType(FilterChip);
      expect(
        tester
            .widgetList<FilterChip>(chips)
            .map((chip) => (chip.label as Text).data),
        [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ],
      );
      expect(
        tester.widgetList<FilterChip>(chips).map((chip) => chip.selected),
        [true, true, true, true, true, false, false],
      );
      for (var i = 0; i < 5; i++) {
        await tester.tap(chips.at(i));
        await tester.pumpAndSettle();
      }
      final export = find.widgetWithText(FilledButton, 'Export');
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
      expect(find.text('Select at least one day.'), findsOneWidget);
      final sunday = find.widgetWithText(FilterChip, 'Sunday');
      await tester.ensureVisible(sunday);
      await tester.pumpAndSettle();
      await tester.tap(sunday);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(export).onPressed, isNotNull);

      final start = find.widgetWithText(
        DropdownButtonFormField<int>,
        'Start hour',
      );
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      final menu = find.byType(Scrollable).last;
      final hour = find.descendant(of: menu, matching: find.text('18:00'));
      await tester.scrollUntilVisible(hour, 120, scrollable: menu);
      await tester.pumpAndSettle();
      await tester.tap(hour);
      await tester.pumpAndSettle();
      expect(
        find.text('End hour must be later than start hour.'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Export Daily Schedule'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  const early = ScheduleBlock(
    id: 'early',
    title: 'Early class',
    description: 'Lab 2',
    weekday: 2,
    startMinute: 510,
    endMinute: 630,
    colour: ScheduleColour.orange,
  );
  const overlap = ScheduleBlock(
    id: 'overlap',
    title: 'Overlapping class',
    weekday: 2,
    startMinute: 570,
    endMinute: 660,
    colour: ScheduleColour.green,
  );
  const late = ScheduleBlock(
    id: 'late',
    title: 'Late class',
    weekday: 2,
    startMinute: 720,
    endMinute: 810,
    colour: ScheduleColour.red,
  );
  const excludedDay = ScheduleBlock(
    id: 'excluded',
    title: 'Excluded day',
    weekday: 1,
    startMinute: 540,
    endMinute: 780,
    colour: ScheduleColour.black,
  );
  const outside = ScheduleBlock(
    id: 'outside',
    title: 'Outside window',
    weekday: 2,
    startMinute: 780,
    endMinute: 840,
    colour: ScheduleColour.black,
  );

  for (final brightness in Brightness.values) {
    test(
      'PNG clips the time window and matches the $brightness palette',
      () async {
        final options = ScheduleExportOptions(
          days: {7, 2},
          startHour: 9,
          endHour: 13,
        );
        expect(options.days, [2, 7]);
        final bytes = await renderSchedulePng(
          options: options,
          blocksByDay: {
            1: [excludedDay],
            2: [early, overlap, late, outside],
          },
          brightness: brightness,
        );
        expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final codec = await ui.instantiateImageCodec(bytes);
        addTearDown(codec.dispose);
        final image = (await codec.getNextFrame()).image;
        addTearDown(image.dispose);
        expect((image.width, image.height), (682, 408));
        final pixels = (await image.toByteData())!;
        Color pixel(int x, int y) {
          final offset = (y * image.width + x) * 4;
          return Color.fromARGB(
            pixels.getUint8(offset + 3),
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          );
        }

        final (background, heading, grid) = switch (brightness) {
          Brightness.dark => (
            const Color(0xff0e1422),
            const Color(0xff131c2d),
            const Color(0xff283346),
          ),
          Brightness.light => (
            const Color(0xfffafbfc),
            const Color(0xffedf2f8),
            const Color(0xffcdd6e2),
          ),
        };
        expect(pixel(16, 30), heading);
        expect(pixel(8, 118), heading);
        expect(pixel(500, 132), grid);
        expect(pixel(376, 20), grid);
        final orange = early.colour.background(brightness);
        final green = overlap.colour.background(brightness);
        final red = late.colour.background(brightness);
        expect(pixel(200, 50), orange);
        expect(pixel(200, 45), isNot(orange));
        expect(pixel(200, 100), orange);
        expect(pixel(350, 85), background);
        expect(pixel(350, 150), green);
        expect(pixel(200, 190), background);
        expect(pixel(350, 190), green);
        expect(pixel(500, 100), background);
        expect(pixel(200, 365), red);
        expect(pixel(350, 365), background);
        expect(pixel(200, 381), red);
        expect(pixel(200, 386), background);

        bool hasInk(int x, int y, Color fill) {
          return [
            for (var row = y; row < y + 16; row++)
              for (var col = x; col < x + 75; col++) pixel(col, row),
          ].any((colour) => colour != fill);
        }

        expect(hasInk(81, 55, orange), isTrue);
        expect(hasInk(81, 74, orange), isTrue);
        expect(hasInk(81, 91, orange), isTrue);
        expect(hasInk(234, 133, green), isFalse);
      },
    );
  }

  test('PNG draws spaces on both sides of the time separator', () async {
    const block = ScheduleBlock(
      id: 'meeting',
      title: 'Meeting AI',
      weekday: 1,
      startMinute: 765,
      endMinute: 840,
    );
    final bytes = await renderSchedulePng(
      options: ScheduleExportOptions(days: {1}, startHour: 12, endHour: 15),
      blocksByDay: {
        1: [block],
      },
      brightness: Brightness.dark,
    );
    final codec = await ui.instantiateImageCodec(bytes);
    addTearDown(codec.dispose);
    final image = (await codec.getNextFrame()).image;
    addTearDown(image.dispose);
    final pixels = (await image.toByteData())!;
    final fill = pixels.getUint32((146 * image.width + 300) * 4);

    bool hasTimeInk(int x) {
      for (var y = 138; y < 151; y++) {
        if (pixels.getUint32((y * image.width + x) * 4) != fill) return true;
      }
      return false;
    }

    // Ahem uses 12 px cells for the time row
    expect([135, 147, 159, 171, 183].map(hasTimeInk), [
      true,
      false,
      true,
      false,
      true,
    ]);
  });

  test('PNG dimensions follow the selected day count and hour range', () async {
    for (final (days, start, end, width, height) in [
      ({1, 2, 3, 4, 5}, 8, 18, 1600, 912),
      ({1, 2, 3, 4, 5, 6, 7}, 0, 24, 2212, 2088),
      ({6}, 14, 18, 376, 408),
    ]) {
      final bytes = await renderSchedulePng(
        options: ScheduleExportOptions(
          days: days,
          startHour: start,
          endHour: end,
        ),
        blocksByDay: const {},
        brightness: Brightness.dark,
      );
      final header = ByteData.sublistView(bytes);
      expect((header.getUint32(16), header.getUint32(20)), (width, height));
    }
  });

  test('Windows save uses the chosen path and writes the PNG bytes', () async {
    final directory = Directory.systemTemp.createTempSync('schedule-export-');
    addTearDown(() => directory.deleteSync(recursive: true));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final file = File('${directory.path}/chosen.png');
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    const name = 'trackstudy-daily-schedule-2026-11-12-080000.png';
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var canceled = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getSavePath');
      expect(call.arguments['suggestedName'], name);
      expect(call.arguments['acceptedTypeGroups'].single['extensions'], [
        'png',
      ]);
      return canceled ? null : file.path;
    });
    expect(await saveSchedulePng(bytes, name), file.path);
    expect(file.readAsBytesSync(), bytes);
    canceled = true;
    expect(await saveSchedulePng(bytes, name), isNull);
  });

  test('Android save passes bytes to the Downloads channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dev.trackstudy/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    const name = 'trackstudy-daily-schedule-2026-11-12-080000.png';
    String? location = 'Downloads/$name';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'savePng');
      expect(call.arguments, {'name': name, 'data': bytes});
      return location;
    });
    expect(await saveSchedulePng(bytes, name), location);
    location = null;
    expect(await saveSchedulePng(bytes, name), isNull);
  });
}
