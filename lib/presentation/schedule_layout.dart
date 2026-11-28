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

typedef ScheduleRange = ({int start, int end});

ScheduleRange snapScheduleRange(
  double anchorY,
  double pointerY, {
  required int firstMinute,
}) {
  const slotMinutes = 30;
  const dayEnd = 1440;
  assert(
    firstMinute >= 0 &&
        firstMinute <= dayEnd - slotMinutes &&
        firstMinute % slotMinutes == 0,
  );

  double slotAt(double y) {
    final minute = firstMinute + y / scheduleMinuteHeight;
    final slot = minute.clamp(firstMinute, dayEnd) / slotMinutes;
    final boundary = slot.round();
    // Correct rounding error from layout and pointer coordinates at boundaries
    return (slot - boundary).abs() < 1e-9 ? boundary.toDouble() : slot;
  }

  final anchor = slotAt(anchorY), pointer = slotAt(pointerY);
  final start = math.min(
    math.min(anchor, pointer).floor(),
    dayEnd ~/ slotMinutes - 1,
  );
  final end = math.max(math.max(anchor, pointer).ceil(), start + 1);
  return (start: start * slotMinutes, end: end * slotMinutes);
}

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
