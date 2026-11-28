import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/presentation/schedule_layout.dart';

void main() {
  ScheduleRange snap(double anchor, double pointer, {int first = 0}) =>
      snapScheduleRange(
        (anchor - first) * scheduleMinuteHeight,
        (pointer - first) * scheduleMinuteHeight,
        firstMinute: first,
      );

  test('snaps outward in either direction and respects exact boundaries', () {
    expect(snap(552, 643), (start: 540, end: 660));
    expect(snap(575, 681), (start: 570, end: 690));
    expect(snap(681, 575), (start: 570, end: 690));
    expect(snap(570 - 1e-10, 600 + 1e-10), (start: 570, end: 600));
    expect(snap(600, 570), (start: 570, end: 600));
    expect(snap(575, 575.2), (start: 570, end: 600));
    expect(snap(599.999, 600.001), (start: 570, end: 630));
    expect(snap(600, 600), (start: 600, end: 630));
  });

  test('clamps to the rendered hours and preserves the last interval', () {
    expect(snap(0, -90), (start: 0, end: 30));
    expect(snap(340, 360, first: 360), (start: 360, end: 390));
    expect(snap(340, 450, first: 360), (start: 360, end: 450));
    expect(snap(570, 601, first: 360), (start: 570, end: 630));
    expect(snap(1410, 1440), (start: 1410, end: 1440));
    expect(snap(1440, 1500), (start: 1410, end: 1440));
    expect(snap(1500, 1410), (start: 1410, end: 1440));
    expect(snap(-20, 1500), (start: 0, end: 1440));
  });

  test('all sampled pairs produce valid half-hour intervals', () {
    const positions = [-15.0, 0.0, 20.25, 30.0, 1410.5, 1440.0, 1500.0];
    for (final first in [0, 360, 1380]) {
      for (final anchor in positions) {
        for (final pointer in positions) {
          final range = snap(anchor, pointer, first: first);
          expect(range.start, inInclusiveRange(first, 1439));
          expect(range.end, lessThanOrEqualTo(1440));
          expect(range.end - range.start, greaterThanOrEqualTo(30));
          expect(range.start % 30, 0);
          expect(range.end % 30, 0);
        }
      }
    }
  });
}
