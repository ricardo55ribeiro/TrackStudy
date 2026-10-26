import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/domain/planning.dart';

void main() {
  test('navigation labels use the requested names on every platform', () {
    expect(StudyTab.values.map((tab) => tab.label), [
      'Progress Bars',
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
        isNot(contains('academic events, and local preferences')),
        reason: file.path,
      );
      expect(source, isNot(contains('h, count, or custom')), reason: file.path);
    }
  });
}
