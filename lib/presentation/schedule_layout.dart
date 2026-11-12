import 'dart:math' as math;
import 'dart:ui';

import '../domain/planning.dart';

const weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const scheduleMinuteHeight = 1.4;
const scheduleBlockRadius = Radius.circular(7);

Rect scheduleBlockBounds(
  SchedulePlacement placement, {
  required int firstMinute,
  required double width,
  required double left,
  double top = 0,
}) {
  final block = placement.block;
  return Rect.fromLTWH(
    left + width * placement.lane / placement.lanes + 3,
    top + (block.startMinute - firstMinute) * scheduleMinuteHeight,
    math.max(1, width / placement.lanes - 6),
    (block.endMinute - block.startMinute) * scheduleMinuteHeight - 1,
  );
}

String scheduleBlockTime(ScheduleBlock block, {String separator = '-'}) =>
    '${WallTime.label(block.startMinute)}$separator${WallTime.label(block.endMinute)}';

({double padding, String? title, String? time, String? description})
scheduleBlockContent(
  ScheduleBlock block,
  double height, {
  double textScale = 1,
  String timeSeparator = '-',
}) => (
  padding: height >= 40 * textScale ? 8 : 0,
  title: height >= 22 * textScale ? block.title : null,
  time: height >= 58 * textScale
      ? scheduleBlockTime(block, separator: timeSeparator)
      : null,
  description:
      height >= 82 * textScale && (block.description?.isNotEmpty ?? false)
      ? block.description
      : null,
);
