import 'dart:convert';
import 'sync_gateway.dart';

/// Per-record causal history. Counters order writes by each installation; they
/// do not rely on server timestamps or interpret every newer row as a conflict.
Map<String, int> historyOf(SyncRow row) {
  final raw = row['sync_history'];
  final history = <String, int>{};
  if (raw != null) {
    if (raw is! Map) throw const FormatException('Invalid sync history');
    for (final entry in raw.entries) {
      if (entry.key is! String ||
          (entry.key as String).isEmpty ||
          (entry.key as String).length > 64 ||
          entry.value is! int ||
          (entry.value as int) < 0 ||
          (entry.value as int) > 9007199254740991) {
        throw const FormatException('Invalid sync history');
      }
      history[entry.key as String] = entry.value as int;
    }
  }
  final writer = row['sync_writer'] as String;
  final version = row['sync_version'] as int;
  if (writer.isNotEmpty && version > (history[writer] ?? 0)) {
    history[writer] = version;
  }
  return history;
}

bool coversHistory(Map<String, int> a, Map<String, int> b) =>
    b.entries.every((e) => (a[e.key] ?? 0) >= e.value);

Map<String, int> mergeHistory(Map<String, int> a, Map<String, int> b) => {
  ...a,
  for (final key in b.keys) key: (a[key] ?? 0) > b[key]! ? a[key]! : b[key]!,
};

bool sameSyncContent(SyncRow a, SyncRow b) {
  Object? canonical(Object? value) {
    if (value is Map) {
      return {
        for (final key in value.keys.cast<String>().toList()..sort())
          key: canonical(value[key]),
      };
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  SyncRow content(SyncRow row) => {
    for (final e in row.entries)
      if (!e.key.startsWith('sync_') &&
          !{
            'id',
            'user_id',
            'revision',
            'dirty',
            'created_at',
            'updated_at',
          }.contains(e.key))
        e.key: e.key.endsWith('_at') && e.value != null
            ? DateTime.parse(e.value as String).toUtc().toIso8601String()
            : e.value,
  };
  return jsonEncode(canonical(content(a))) == jsonEncode(canonical(content(b)));
}
