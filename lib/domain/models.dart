enum Measurement { continuous, discrete }

/// Fixed hundredths of a displayed unit. 1.5 hours is exactly 150 ticks.
/// This supports custom units and avoids rounding during accumulation.
abstract final class Amount {
  static const scale = 100;
  static const max = 100000000;
  static int parse(
    String raw, {
    bool discrete = false,
    bool allowZero = false,
  }) {
    final normalized = raw.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(normalized)) {
      throw const FormatException('Use a number with at most two decimals.');
    }
    final parts = normalized.split('.');
    // Bound the whole part before scaling so native integer overflow cannot
    // turn an oversized pasted value into a small, valid addition.
    final whole = int.tryParse(parts[0]);
    if (whole == null || whole > max ~/ scale) {
      throw const FormatException('Enter a positive amount up to 1,000,000.');
    }
    final result =
        whole * scale +
        (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
    if (result > max || result < (allowZero ? 0 : 1)) {
      throw const FormatException('Enter a positive amount up to 1,000,000.');
    }
    if (discrete && result % scale != 0) {
      throw const FormatException('Use a whole number for this category.');
    }
    return result;
  }

  static String format(int ticks) {
    final whole = ticks ~/ scale;
    final fraction = ticks % scale;
    return fraction == 0
        ? '$whole'
        : '$whole.${fraction.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
  }
}

class GoalConfig {
  final String name;
  final Measurement measurement;
  final String unit;
  final int floor, target, increment, step;
  const GoalConfig({
    required this.name,
    required this.measurement,
    required this.unit,
    required this.floor,
    required this.target,
    required this.increment,
    required this.step,
  });
  void validate() {
    if (name.trim().isEmpty || name.length > 80 || unit.length > 20) {
      throw const FormatException(
        'Name is required (up to 80 characters). Unit may contain up to 20 characters.',
      );
    }
    if (target <= 0 || target > Amount.max || floor < 0 || floor > target) {
      throw const FormatException(
        'Target must be positive and floor must be between zero and target.',
      );
    }
    if (increment <= 0 ||
        increment > Amount.max ||
        step <= 0 ||
        step > Amount.max) {
      throw const FormatException(
        'Default addition and step must be positive.',
      );
    }
    if (measurement == Measurement.discrete &&
        [floor, target, increment, step].any((v) => v % 100 != 0)) {
      throw const FormatException('Discrete categories require whole numbers.');
    }
  }

  Map<String, Object?> toMap() => {
    'name': name.trim(),
    'measurement': measurement.name,
    'unit': unit.trim(),
    'floor': floor,
    'target': target,
    'increment': increment,
    'step': step,
  };
  factory GoalConfig.fromMap(Map<String, Object?> m) => GoalConfig(
    name: m['name'] as String,
    measurement: Measurement.values.byName(m['measurement'] as String),
    unit: m['unit'] as String,
    floor: m['floor'] as int,
    target: m['target'] as int,
    increment: m['increment'] as int,
    step: m['step'] as int,
  );
}

class Category {
  final String id;
  final GoalConfig config;
  final int position;
  final bool active, archived;
  const Category(
    this.id,
    this.config,
    this.position,
    this.active,
    this.archived,
  );
}

enum ProgressState { belowFloor, floorProtected, targetReached, exceeded }

class WeeklyProgress {
  final String goalId, categoryId, week;
  final GoalConfig config;
  final int total, activeEntries;
  const WeeklyProgress({
    required this.goalId,
    required this.categoryId,
    required this.week,
    required this.config,
    required this.total,
    required this.activeEntries,
  });
  double get fraction => (total / config.target).clamp(0, 1);
  double get floorFraction => config.floor / config.target;
  ProgressState get state => total > config.target
      ? ProgressState.exceeded
      : total == config.target
      ? ProgressState.targetReached
      : total >= config.floor
      ? ProgressState.floorProtected
      : ProgressState.belowFloor;
  String get value =>
      '${Amount.format(total)} / ${Amount.format(config.target)}${config.unit.isEmpty ? '' : ' ${config.unit}'}';
}

class LedgerEntry {
  final String id, goalId, createdAt;
  final int amount;
  final String? undoneAt;
  const LedgerEntry(
    this.id,
    this.goalId,
    this.amount,
    this.createdAt,
    this.undoneAt,
  );
}

class JournalEntry {
  final String id, createdAt, learned, question, next;
  final String? answer, answeredAt;
  final Map<String, String> experiment;
  const JournalEntry({
    required this.id,
    required this.createdAt,
    required this.learned,
    required this.question,
    required this.next,
    this.experiment = const {},
    this.answer,
    this.answeredAt,
  });
}

class WeeklyReview {
  final String week, wentWrong, change, upcoming, danger, countermeasure;
  final List<String> wins;
  final List<bool> done;
  const WeeklyReview({
    required this.week,
    this.wentWrong = '',
    this.change = '',
    this.upcoming = '',
    this.danger = '',
    this.countermeasure = '',
    this.wins = const ['', '', ''],
    this.done = const [false, false, false],
  });
  Map<String, Object?> toMap() => {
    'wentWrong': wentWrong,
    'change': change,
    'upcoming': upcoming,
    'danger': danger,
    'countermeasure': countermeasure,
    'wins': wins,
    'done': done,
  };
  factory WeeklyReview.fromMap(String week, Map<String, dynamic> m) =>
      WeeklyReview(
        week: week,
        wentWrong: m['wentWrong'] as String,
        change: m['change'] as String,
        upcoming: m['upcoming'] as String,
        danger: m['danger'] as String,
        countermeasure: m['countermeasure'] as String,
        wins: List<String>.from(m['wins'] as List),
        done: List<bool>.from(m['done'] as List),
      );
}
