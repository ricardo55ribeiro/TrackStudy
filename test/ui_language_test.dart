import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/domain/planning.dart';

void main() {
  test('navigation labels use the requested names on every platform', () {
    expect(StudyTab.values.map((tab) => tab.label), [
      'Progress Bars',
      'To-Do List',
      'Research Journal',
      'Weekly Review',
      'Daily Schedule',
      'Monthly View',
    ]);
  });

  test('application-owned source avoids long dashes and known serial commas', () {
    final files = [
      ...Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
      File(
        'android/app/src/main/kotlin/dev/trackstudy/trackstudy/MainActivity.kt',
      ),
      File('windows/runner/flutter_window.cpp'),
    ];
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(matches(RegExp(r'[\u2013\u2014]'))),
        reason: file.path,
      );
      expect(
        source,
        isNot(matches(RegExp(r'academic events,\s+and local preferences'))),
        reason: file.path,
      );
      expect(
        source,
        isNot(matches(RegExp(r'h, count,\s+or custom'))),
        reason: file.path,
      );
    }
  });
}
