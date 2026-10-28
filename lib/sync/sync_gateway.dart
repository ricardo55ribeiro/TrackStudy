const syncTables = [
  'categories',
  'category_states',
  'weekly_goals',
  'entries',
  'journal',
  'reviews',
  'schedule_blocks',
  'academic_events',
  'todo_topics',
  'todo_tasks',
];
typedef SyncRow = Map<String, dynamic>;

abstract interface class SyncGateway {
  Future<Map<String, List<SyncRow>>> pull(String accountId);
  Future<SyncRow> merge(String table, SyncRow row);
}

abstract interface class ConflictArchiveGateway {
  Future<bool> archiveEntryCopy(SyncRow entry, int version, String writer);
}

class SupabaseConfiguration {
  final String url, publishableKey;
  const SupabaseConfiguration({
    this.url = const String.fromEnvironment('SUPABASE_URL'),
    this.publishableKey = const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
  });
  bool get configured =>
      Uri.tryParse(url)?.scheme == 'https' &&
      (Uri.tryParse(url)?.host.isNotEmpty ?? false) &&
      publishableKey.startsWith('sb_publishable_');
  String get status =>
      configured ? 'Local only' : 'Local only · cloud is not configured';
}

class SyncCancelled implements Exception {}
