import 'package:sqlite3/sqlite3.dart';

// Explicit decisions take precedence over automatic upgrade baselines
// The earliest baseline describes the upgrade boundary, never a later revival
const categoryStateOrder =
    'is_baseline ASC, CASE WHEN is_baseline=0 THEN week_start END DESC, week_start ASC, id';

String categoryInclusionSql(String category, String week) =>
    '''COALESCE((SELECT included FROM category_states
    WHERE category_id=$category AND week_start<=$week
    ORDER BY $categoryStateOrder LIMIT 1),1)''';

// Global flags are a compatibility cache of the authoritative lifecycle
// Updating that cache must not create a separate competing causal operation
void normalizeCategoryStatuses(Database db) {
  final applying = db
      .select("SELECT value FROM sync_meta WHERE key='applying'")
      .single['value'];
  db.execute("UPDATE sync_meta SET value='1' WHERE key='applying'");
  try {
    for (final category in db.select('SELECT * FROM categories')) {
      final states = db.select(
        'SELECT * FROM category_states WHERE category_id=? ORDER BY $categoryStateOrder LIMIT 1',
        [category['id']],
      );
      if (states.isEmpty) continue;
      final state = states.single;
      final active = state['included'];
      final archived = active == 1 ? null : state['changed_at'];
      if (category['active'] != active || category['archived_at'] != archived) {
        db.execute('UPDATE categories SET active=?,archived_at=? WHERE id=?', [
          active,
          archived,
          category['id'],
        ]);
      }
    }
  } finally {
    db.execute("UPDATE sync_meta SET value=? WHERE key='applying'", [applying]);
  }
}
