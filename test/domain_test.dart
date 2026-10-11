import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/domain/models.dart';

void main() {
  group('Local calendar weeks', () {
    test(
      'Monday and Sunday use the same Monday; missing midnight needs no job',
      () {
        expect(Week.containing(DateTime(2026, 9, 21)).key, '2026-09-21');
        expect(
          Week.containing(DateTime(2026, 9, 27, 23, 59, 59)).key,
          '2026-09-21',
        );
        expect(Week.containing(DateTime(2026, 9, 28)).key, '2026-09-28');
        expect(Week.containing(DateTime(2026, 9, 28, 16)).key, '2026-09-28');
      },
    );
    test('DST Sundays, year and month boundaries use calendar dates', () {
      for (final date in [
        DateTime(2026, 3, 29, 23, 59),
        DateTime(2026, 10, 25, 23, 59),
      ]) {
        final week = Week.containing(date);
        expect(week.start.weekday, DateTime.monday);
        expect(week.end.day, date.day);
        expect(week.shift(1).start.weekday, DateTime.monday);
      }
      expect(Week.containing(DateTime(2027, 1, 1)).key, '2026-12-28');
      expect(Week.parse('2026-12-28').shift(1).key, '2027-01-04');
      expect(() => Week.parse('2026-09-22'), throwsFormatException);
    });
  });
  group('Exact decimal amounts', () {
    test('decimal, locale comma, quarter hour, and accumulation', () {
      expect(Amount.parse('1.5'), 150);
      expect(Amount.parse(' 1,25 '), 125);
      expect(Amount.parse('0.1') * 10, 100);
      expect(Amount.format(425), '4.25');
      expect(Amount.format(450), '4.5');
      expect(Amount.format(400), '4');
    });
    test(
      'reject invalid, negative, nonfinite and fractional discrete amounts',
      () {
        for (final value in [
          '',
          '-1',
          'NaN',
          'Infinity',
          '0',
          '1.234',
          '1,2.3',
          '1e3',
          '1000001',
          '184467440737095517',
          '999999999999999999999999999999999999',
        ]) {
          expect(() => Amount.parse(value), throwsFormatException);
        }
        expect(
          () => Amount.parse('1.5', discrete: true),
          throwsFormatException,
        );
        expect(Amount.parse('1', discrete: true), 100);
      },
    );
  });
  group('Progress semantics', () {
    const config = GoalConfig(
      name: 'Research',
      measurement: Measurement.continuous,
      unit: 'h',
      floor: 600,
      target: 800,
      increment: 100,
      step: 25,
    );
    WeeklyProgress progress(int amount, {GoalConfig cfg = config}) =>
        WeeklyProgress(
          goalId: 'g',
          categoryId: 'c',
          week: '2026-09-21',
          config: cfg,
          total: amount,
          activeEntries: 0,
        );
    test('below, equal floor, between, equal target, exceeded', () {
      expect(progress(400).state, ProgressState.belowFloor);
      expect(progress(600).state, ProgressState.floorProtected);
      expect(progress(650).state, ProgressState.floorProtected);
      expect(progress(800).state, ProgressState.targetReached);
      expect(progress(1000).state, ProgressState.exceeded);
      expect(progress(150).fraction, .1875);
      expect(progress(400).fraction, .5);
      expect(progress(1000).fraction, 1);
      expect(progress(1000).total, 1000);
      expect(progress(0).floorFraction, .75);
    });
    test('zero floor, equal floor/target, invalid goals', () {
      GoalConfig cfg(int floor, int target) => GoalConfig(
        name: 'X',
        measurement: Measurement.continuous,
        unit: 'h',
        floor: floor,
        target: target,
        increment: 100,
        step: 25,
      );
      cfg(0, 100).validate();
      cfg(100, 100).validate();
      expect(progress(0, cfg: cfg(0, 100)).state, ProgressState.floorProtected);
      expect(
        progress(100, cfg: cfg(100, 100)).state,
        ProgressState.targetReached,
      );
      for (final c in [cfg(101, 100), cfg(-1, 100), cfg(0, 0)]) {
        expect(c.validate, throwsFormatException);
      }
    });
  });
}
