import 'dart:convert';

/// Calendar dates and recurring times deliberately have no UTC conversion.
abstract final class LocalDate {
  static String key(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  static DateTime parse(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Choose a valid calendar date.');
    }
    final date = DateTime.tryParse(value);
    if (date == null || key(date) != value || date.year < 1900) {
      throw const FormatException('Choose a valid calendar date.');
    }
    return date;
  }

  static DateTime month(DateTime date, int offset) =>
      DateTime(date.year, date.month + offset);
  static List<DateTime> monthCells(DateTime month) {
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final offset = first.weekday - 1;
    return List.generate(
      ((offset + days + 6) ~/ 7) * 7,
      (i) => DateTime(month.year, month.month, 1 - offset + i),
    );
  }
}

abstract final class WallTime {
  static double minutes(DateTime time) =>
      time.hour * 60 +
      time.minute +
      time.second / 60 +
      time.millisecond / 60000;
  static String label(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  static int parse(String text) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
    if (match != null) {
      final hour = int.parse(match[1]!), minute = int.parse(match[2]!);
      if (hour < 24 && minute < 60 || hour == 24 && minute == 0) {
        return hour * 60 + minute;
      }
    }
    throw const FormatException('Use a time such as 08:30 (00:00-24:00).');
  }
}

class ScheduleBlock {
  final String id, title;
  final String? description;
  final int weekday, startMinute, endMinute;
  const ScheduleBlock({
    required this.id,
    required this.title,
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
    this.description,
  });
  void validate() {
    if ((description?.length ?? 0) > 2000) {
      throw const FormatException(
        'Keep the description within 2000 characters.',
      );
    }
    if (title.trim().isEmpty || title.length > 120) {
      throw const FormatException('Enter a title of 1-120 characters.');
    }
    if (weekday < 1 ||
        weekday > 7 ||
        startMinute < 0 ||
        startMinute >= 1440 ||
        endMinute > 1440 ||
        endMinute <= startMinute) {
      throw const FormatException(
        'Choose a weekday and an end time later than the start.',
      );
    }
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title.trim(),
    'weekday': weekday,
    'start_minute': startMinute,
    'end_minute': endMinute,
    'description': description?.trim().isEmpty ?? true
        ? null
        : description!.trim(),
  };
  factory ScheduleBlock.fromMap(Map<String, Object?> row) => ScheduleBlock(
    id: row['id'] as String,
    title: row['title'] as String,
    weekday: row['weekday'] as int,
    startMinute: row['start_minute'] as int,
    endMinute: row['end_minute'] as int,
    description: row['description'] as String?,
  );
}

enum AcademicType {
  exam,
  test,
  project,
  presentation,
  deadline,
  other;

  String get label => '${name[0].toUpperCase()}${name.substring(1)}';
}

class AcademicEvent {
  final String id, title, date, note;
  final AcademicType type;
  const AcademicEvent({
    required this.id,
    required this.title,
    required this.date,
    required this.type,
    this.note = '',
  });
  void validate() {
    LocalDate.parse(date);
    if (title.trim().isEmpty || title.length > 120 || note.length > 2000) {
      throw const FormatException(
        'Enter a title of 1-120 characters and a note up to 2,000 characters.',
      );
    }
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title.trim(),
    'event_date': date,
    'event_type': type.name,
    'note': note.trim(),
  };
  factory AcademicEvent.fromMap(Map<String, Object?> row) => AcademicEvent(
    id: row['id'] as String,
    title: row['title'] as String,
    date: row['event_date'] as String,
    type: AcademicType.values.byName(row['event_type'] as String),
    note: row['note'] as String,
  );
}

class SchedulePlacement {
  final ScheduleBlock block;
  final int lane, lanes;
  const SchedulePlacement(this.block, this.lane, this.lanes);
}

/// Interval partitioning: connected overlap groups share the available width.
List<SchedulePlacement> layoutSchedule(List<ScheduleBlock> blocks) {
  final sorted = [...blocks]
    ..sort((a, b) {
      final order = a.startMinute.compareTo(b.startMinute);
      return order != 0 ? order : a.id.compareTo(b.id);
    });
  final result = <SchedulePlacement>[];
  var group = <(ScheduleBlock, int)>[], ends = <int>[];
  void flush() {
    result.addAll(group.map((p) => SchedulePlacement(p.$1, p.$2, ends.length)));
    group = [];
    ends = [];
  }

  for (final block in sorted) {
    if (ends.isNotEmpty && ends.every((end) => end <= block.startMinute)) {
      flush();
    }
    var lane = ends.indexWhere((end) => end <= block.startMinute);
    if (lane < 0) {
      lane = ends.length;
      ends.add(block.endMinute);
    } else {
      ends[lane] = block.endMinute;
    }
    group.add((block, lane));
  }
  flush();
  return result;
}

enum StudyTab {
  week,
  todo,
  journal,
  review,
  schedule,
  month;

  String get label => switch (this) {
    week => 'Progress Bars',
    todo => 'To-Do List',
    journal => 'Research Journal',
    review => 'Weekly Review',
    schedule => 'Daily Schedule',
    month => 'Monthly View',
  };
}

/// Stable IDs in a device-local preference, ignoring unknown and duplicate IDs
/// Legacy orders omit week, so insert it first only when it is missing
abstract final class StudyTabOrder {
  static List<StudyTab> decode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) return normalize(decoded);
    } on FormatException {
      // Missing or malformed older preferences use the normal default order.
    }
    return normalize(const []);
  }

  static List<StudyTab> normalize(Iterable<Object?> ids) {
    final tabs = <StudyTab>{};
    for (final id in ids) {
      for (final tab in StudyTab.values) {
        if (tab.name == id) tabs.add(tab);
      }
    }
    final order = <StudyTab>{
      if (!tabs.contains(StudyTab.week)) StudyTab.week,
      ...tabs,
      ...StudyTab.values,
    }.toList();
    if (!tabs.contains(StudyTab.todo)) {
      order.remove(StudyTab.todo);
      order.insert(order.indexOf(StudyTab.week) + 1, StudyTab.todo);
    }
    return List.unmodifiable(order);
  }
}
