import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/planning.dart';
import 'planning_colours.dart';
import 'schedule_layout.dart';

class ScheduleExportOptions {
  final List<int> days;
  final int startHour, endHour;

  ScheduleExportOptions({
    required Set<int> days,
    required this.startHour,
    required this.endHour,
  }) : days = List.unmodifiable(days.toList()..sort()) {
    if (days.isEmpty || days.any((day) => day < 1 || day > weekdays.length)) {
      throw ArgumentError.value(days, 'days', 'Select valid weekdays');
    }
    if (startHour < 0 || endHour > 24 || endHour <= startHour) {
      throw ArgumentError('Select an increasing hour range within 00:00-24:00');
    }
  }
}

class ScheduleExportDialog extends StatefulWidget {
  const ScheduleExportDialog({super.key});

  @override
  State<ScheduleExportDialog> createState() => _ScheduleExportDialogState();
}

class _ScheduleExportDialogState extends State<ScheduleExportDialog> {
  final days = {1, 2, 3, 4, 5};
  int startHour = 8, endHour = 18;

  Widget hourField({
    required String label,
    required int value,
    required int first,
    required int last,
    required ValueChanged<int> onChanged,
  }) => DropdownButtonFormField<int>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (var hour = first; hour <= last; hour++)
        DropdownMenuItem(value: hour, child: Text(WallTime.label(hour * 60))),
    ],
    onChanged: (hour) => setState(() => onChanged(hour!)),
  );

  @override
  Widget build(BuildContext context) {
    final errorStyle = TextStyle(color: Theme.of(context).colorScheme.error);
    return AlertDialog(
      scrollable: true,
      title: const Text('Export Daily Schedule'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Days to include'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < weekdays.length; i++)
                  FilterChip(
                    label: Text(weekdays[i]),
                    selected: days.contains(i + 1),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        days.add(i + 1);
                      } else {
                        days.remove(i + 1);
                      }
                    }),
                  ),
              ],
            ),
            if (days.isEmpty)
              Text('Select at least one day.', style: errorStyle),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: hourField(
                    label: 'Start hour',
                    value: startHour,
                    first: 0,
                    last: 23,
                    onChanged: (hour) => startHour = hour,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: hourField(
                    label: 'End hour',
                    value: endHour,
                    first: 1,
                    last: 24,
                    onChanged: (hour) => endHour = hour,
                  ),
                ),
              ],
            ),
            if (endHour <= startHour)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'End hour must be later than start hour.',
                  style: errorStyle,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: days.isEmpty || endHour <= startHour
              ? null
              : () => Navigator.pop(
                  context,
                  ScheduleExportOptions(
                    days: days,
                    startHour: startHour,
                    endHour: endHour,
                  ),
                ),
          child: const Text('Export'),
        ),
      ],
    );
  }
}

Future<Uint8List> renderSchedulePng({
  required ScheduleExportOptions options,
  required Map<int, List<ScheduleBlock>> blocksByDay,
  required Brightness brightness,
}) async {
  const gutter = 70.0, dayWidth = 306.0, header = 48.0, footer = 24.0;
  final (background, heading, grid, label) = switch (brightness) {
    Brightness.dark => (
      const Color(0xff0e1422),
      const Color(0xff131c2d),
      const Color(0xff283346),
      const Color(0xffdce5f3),
    ),
    Brightness.light => (
      const Color(0xfffafbfc),
      const Color(0xffedf2f8),
      const Color(0xffcdd6e2),
      const Color(0xff253348),
    ),
  };
  const hourHeight = 60 * scheduleMinuteHeight;
  final width = gutter + options.days.length * dayWidth;
  final end = header + (options.endHour - options.startHour) * hourHeight;
  final height = end + footer;
  final frame = Rect.fromLTWH(0, 0, width, height);
  final border = RRect.fromRectAndRadius(
    frame.deflate(.5),
    const Radius.circular(12),
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, frame);
  final paint = Paint();

  canvas.drawRect(frame, paint..color = background);
  canvas.save();
  canvas.clipRRect(border);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, header), paint..color = heading);
  canvas.drawRect(
    Rect.fromLTRB(0, header, gutter, height),
    paint..color = heading,
  );

  paint.color = grid;
  for (var hour = options.startHour; hour <= options.endHour; hour++) {
    final y = header + (hour - options.startHour) * hourHeight;
    canvas.drawLine(Offset(0, y + .5), Offset(width, y + .5), paint);
    _paintText(
      canvas,
      WallTime.label(hour * 60),
      Offset(0, y + 6),
      gutter - 12,
      TextStyle(color: label, fontSize: 12),
      align: TextAlign.right,
    );
  }

  for (final (index, day) in options.days.indexed) {
    final left = gutter + index * dayWidth;
    canvas.drawLine(
      Offset(left + .5, index == 0 ? header : 0),
      Offset(left + .5, height),
      paint,
    );
    _paintText(
      canvas,
      weekdays[day - 1].toUpperCase(),
      Offset(left, 15),
      dayWidth,
      TextStyle(color: label, fontSize: 16, fontWeight: FontWeight.w700),
      align: TextAlign.center,
    );
    final visible = Rect.fromLTRB(left, header, left + dayWidth, end);
    for (final placement in layoutSchedule(blocksByDay[day] ?? const [])) {
      final bounds = scheduleBlockBounds(
        placement,
        firstMinute: options.startHour * 60,
        width: dayWidth,
        left: left,
        top: header,
      ).intersect(visible);
      if (!bounds.isEmpty) {
        _paintBlock(canvas, bounds, placement.block, brightness);
      }
    }
  }
  canvas.restore();
  canvas.drawRRect(border, paint..style = PaintingStyle.stroke);

  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width.round(), height.round());
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

void _paintBlock(
  Canvas canvas,
  Rect bounds,
  ScheduleBlock block,
  Brightness brightness,
) {
  final fill = block.colour.background(brightness);
  final ink = block.colour.foreground(brightness);
  final shape = RRect.fromRectAndRadius(bounds, scheduleBlockRadius);
  canvas.drawRRect(shape, Paint()..color = fill);
  canvas.save();
  canvas.clipRRect(shape);
  canvas.drawRRect(
    shape,
    Paint()
      ..style = PaintingStyle.stroke
      ..color = ink.withValues(alpha: .25),
  );
  final content = scheduleBlockContent(
    block,
    bounds.height,
    timeSeparator: ' - ',
  );
  final left = bounds.left + content.padding;
  final top = bounds.top + content.padding;
  final width = bounds.width - content.padding * 2;
  final style = TextStyle(color: ink, fontWeight: FontWeight.bold);
  if (width > 0) {
    if (content.title case final title?) {
      _paintText(
        canvas,
        title,
        Offset(left, top),
        width,
        style.copyWith(fontSize: 14),
      );
    }
    if (content.time case final time?) {
      _paintText(
        canvas,
        time,
        Offset(left, top + 18),
        width,
        style.copyWith(fontSize: 12),
      );
    }
    if (content.description case final description?) {
      _paintText(
        canvas,
        description,
        Offset(left, top + 35),
        width,
        style.copyWith(color: ink.withValues(alpha: .88), fontSize: 11),
      );
    }
  }
  canvas.restore();
}

void _paintText(
  Canvas canvas,
  String text,
  Offset offset,
  double width,
  TextStyle style, {
  TextAlign align = TextAlign.left,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: 1,
    ellipsis: '…',
  )..layout(minWidth: width, maxWidth: width);
  painter.paint(canvas, offset);
  painter.dispose();
}
