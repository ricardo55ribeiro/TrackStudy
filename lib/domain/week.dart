/// Local calendar arithmetic: never subtract 24-hour durations across DST.
class Week implements Comparable<Week> {
  final String key;
  const Week._(this.key);
  factory Week.containing(DateTime local) {
    final monday = DateTime(
      local.year,
      local.month,
      local.day - local.weekday + 1,
    );
    return Week._(
      '${monday.year.toString().padLeft(4, '0')}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}',
    );
  }
  factory Week.parse(String key) {
    final date = DateTime.tryParse(key);
    if (date == null || date.weekday != 1 || Week.containing(date).key != key) {
      throw const FormatException('Invalid Monday week date');
    }
    return Week._(key);
  }
  DateTime get start => DateTime.parse(key);
  DateTime get end => DateTime(start.year, start.month, start.day + 6);
  Week shift(int count) =>
      Week.containing(DateTime(start.year, start.month, start.day + 7 * count));
  @override
  int compareTo(Week other) => key.compareTo(other.key);
  @override
  bool operator ==(Object other) => other is Week && key == other.key;
  @override
  int get hashCode => key.hashCode;
}
