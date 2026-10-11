import 'dart:convert';
import '../data/database.dart';
import '../domain/models.dart';
import '../domain/week.dart';
import '../domain/planning.dart';
import 'sync_gateway.dart';
import 'sync_history.dart';

/// Durable replication metadata is separate from user-visible domain tables.
class SyncStore {
  final StudyDatabase database;
  SyncStore(this.database);
  String meta(String key) {
    final rows = database.handle.select(
      'SELECT value FROM sync_meta WHERE key=?',
      [key],
    );
    return rows.isEmpty ? '' : rows.first['value'] as String;
  }

  void setMeta(String key, String value) => database.handle.execute(
    'INSERT INTO sync_meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  int get pending =>
      database.handle
              .select('SELECT count(*) n FROM sync_records WHERE dirty=1')
              .first['n']
          as int;
  int get conflicts =>
      database.handle
              .select(
                'SELECT count(*) n FROM sync_conflicts WHERE archived_at IS NULL',
              )
              .first['n']
          as int;
  int get savedCopies =>
      database.handle.select('SELECT count(*) n FROM sync_conflicts').first['n']
          as int;
  String exportConflicts() => const JsonEncoder.withIndent('  ').convert(
    database.handle
        .select('SELECT * FROM sync_conflicts')
        .map((r) => Map<String, dynamic>.from(r))
        .toList(),
  );

  List<SyncRow> get activeEntryCopies => database.handle
      .select(
        "SELECT * FROM sync_conflicts WHERE table_name='entries' AND archived_at IS NULL",
      )
      .map((r) => Map<String, dynamic>.from(r))
      .toList();

  SyncRow? entryForArchival(SyncRow copy) {
    final rows = database.handle.select(
      '''SELECT e.*,s.version sync_version,s.writer sync_writer,s.history sync_history
      FROM entries e JOIN sync_records s ON s.record_id=e.id AND s.table_name='entries'
      WHERE e.id=? AND s.dirty=0''',
      [copy['record_id']],
    );
    if (rows.isEmpty) return null;
    final entry = _wire('entries', Map<String, dynamic>.from(rows.first));
    final old = jsonDecode(copy['payload'] as String) as SyncRow;
    if (entry['sync_writer'] != meta('device') ||
        copy['writer'] != entry['sync_writer'] ||
        (copy['version'] as int) > (entry['sync_version'] as int) ||
        old['goal_id'] != entry['goal_id'] ||
        old['amount'] != entry['amount'] ||
        old['source'] != entry['source']) {
      return null;
    }
    return entry;
  }

  bool archiveEntryCopy(SyncRow copy, SyncRow verifiedEntry) {
    final current = entryForArchival(copy);
    if (current == null ||
        !sameSyncContent(current, verifiedEntry) ||
        current['sync_version'] != verifiedEntry['sync_version'] ||
        current['sync_writer'] != verifiedEntry['sync_writer']) {
      return false;
    }
    database.handle.execute(
      '''UPDATE sync_conflicts SET archived_at=?
      WHERE table_name='entries' AND record_id=? AND version=? AND writer=?''',
      [
        DateTime.now().toUtc().toIso8601String(),
        copy['record_id'],
        copy['version'],
        copy['writer'],
      ],
    );
    return true;
  }

  void bind(String account, String project) {
    if ((meta('account').isNotEmpty && meta('account') != account) ||
        (meta('project').isNotEmpty && meta('project') != project)) {
      throw const FormatException(
        'This local dataset belongs to another account or project. Sign in with the original account.',
      );
    }
    database.transaction(() {
      setMeta('account', account);
      setMeta('project', project);
    });
  }

  List<SyncRow> pendingRows(String table) {
    if (!syncTables.contains(table)) throw ArgumentError('Invalid sync table');
    return database.handle
        .select(
          '''SELECT t.*,s.version sync_version,s.writer sync_writer,s.history sync_history
      FROM $table t JOIN sync_records s ON s.record_id=t.id AND s.table_name=? WHERE s.dirty=1 ORDER BY s.version,t.id''',
          [table],
        )
        .map((r) => _wire(table, Map<String, dynamic>.from(r)))
        .toList();
  }

  SyncRow _wire(String table, SyncRow row) {
    if (table == 'categories') row['active'] = row['active'] == 1;
    for (final field in ['experiment', 'content', 'sync_history']) {
      if (row.containsKey(field)) row[field] = jsonDecode(row[field] as String);
    }
    return row;
  }

  int _compare(SyncRow a, SyncRow b) {
    final version = (a['sync_version'] as int).compareTo(
      b['sync_version'] as int,
    );
    return version != 0
        ? version
        : (a['sync_writer'] as String).compareTo(b['sync_writer'] as String);
  }

  void _saveConflict(String table, SyncRow row) {
    database.handle.execute(
      'INSERT OR IGNORE INTO sync_conflicts (table_name,record_id,version,writer,payload,saved_at) VALUES (?,?,?,?,?,?)',
      [
        table,
        row['id'],
        row['sync_version'],
        row['sync_writer'],
        jsonEncode(row),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  void apply(
    Map<String, List<SyncRow>> remote,
    String account, {
    bool bootstrap = false,
  }) {
    database.transaction(() {
      setMeta('applying', '1');
      // Upgraded databases are never considered pristine. Only untouched,
      // automatically generated defaults on a new device can be adopted away.
      if (bootstrap &&
          meta('pristine_seed') == '1' &&
          (remote['categories']?.isNotEmpty ?? false)) {
        for (final table in [
          'entries',
          'journal',
          'reviews',
          'schedule_blocks',
          'academic_events',
        ]) {
          if (database.handle
              .select('SELECT id FROM $table LIMIT 1')
              .isNotEmpty) {
            throw StateError('Pristine seed unexpectedly contains user data');
          }
        }
        database.handle.execute(
          'DELETE FROM weekly_goals; DELETE FROM categories; DELETE FROM sync_records;',
        );
      }
      for (final table in syncTables) {
        for (final row in remote[table] ?? <SyncRow>[]) {
          _applyRow(table, row, account);
        }
      }
      setMeta('pristine_seed', '0');
      setMeta('applying', '0');
    });
  }

  void _applyRow(String table, SyncRow remote, String account) {
    if (remote['user_id'] != account) {
      throw StateError('Cloud record has unexpected ownership');
    }
    final version = remote['sync_version'] as int;
    final remoteHistory = historyOf(remote);
    var mergedHistory = remoteHistory;
    if (version < 0 || version > 9007199254740991) {
      throw const FormatException('Invalid cloud version');
    }
    final clock = int.parse(meta('clock'));
    final observed = remoteHistory.values.fold(
      version,
      (a, b) => a > b ? a : b,
    );
    if (observed > clock) setMeta('clock', '$observed');
    final id = remote['id'] as String;
    // Reconcile concurrent creations of the same natural-key snapshot/review.
    // Ledger entry UUIDs are never changed or duplicated.
    if (table == 'weekly_goals' || table == 'reviews') {
      final matches = database.handle.select(
        'SELECT id FROM $table WHERE week_start=?${table == 'weekly_goals' ? ' AND category_id=?' : ''}',
        [
          remote['week_start'],
          if (table == 'weekly_goals') remote['category_id'],
        ],
      );
      if (matches.isNotEmpty && matches.first['id'] != id) {
        final oldId = matches.first['id'] as String;
        final old = database.handle.select('SELECT * FROM $table WHERE id=?', [
          oldId,
        ]).first;
        final copy = Map<String, dynamic>.from(old)..['id'] = id;
        database.handle.execute('PRAGMA defer_foreign_keys=ON');
        database.handle.execute('DELETE FROM $table WHERE id=?', [oldId]);
        _upsert(table, copy);
        if (table == 'weekly_goals') {
          database.handle.execute(
            'UPDATE entries SET goal_id=? WHERE goal_id=?',
            [id, oldId],
          );
        }
        database.handle.execute(
          'UPDATE sync_records SET record_id=? WHERE table_name=? AND record_id=?',
          [id, table, oldId],
        );
      }
    }
    final rows = database.handle.select(
      '''SELECT t.*,s.version sync_version,s.writer sync_writer,s.history sync_history,s.dirty
      FROM $table t JOIN sync_records s ON s.record_id=t.id AND s.table_name=? WHERE t.id=?''',
      [table, id],
    );
    if (rows.isNotEmpty) {
      final local = _wire(table, Map<String, dynamic>.from(rows.first));
      final localHistory = historyOf(local);
      mergedHistory = mergeHistory(localHistory, remoteHistory);
      final localCovers = coversHistory(localHistory, remoteHistory);
      final remoteCovers = coversHistory(remoteHistory, localHistory);
      final divergent =
          !localCovers && !remoteCovers && !sameSyncContent(local, remote);
      final order = remoteCovers && !localCovers
          ? 1
          : localCovers && !remoteCovers
          ? -1
          : _compare(remote, local);
      if (order < 0) {
        if (divergent) _saveConflict(table, remote);
        database.handle.execute(
          'UPDATE sync_records SET history=?,dirty=1 WHERE table_name=? AND record_id=?',
          [jsonEncode(mergedHistory), table, id],
        );
        return;
      }
      if (divergent) _saveConflict(table, local);
      if (table == 'weekly_goals' &&
          (local['measurement'] != remote['measurement'] ||
              local['unit'] != remote['unit']) &&
          database.handle.select(
            'SELECT id FROM entries WHERE goal_id=? LIMIT 1',
            [id],
          ).isNotEmpty) {
        throw const FormatException(
          'Sync paused: this week has entries with a different unit on another device. Restore matching units on that device, then retry. Local entries are unchanged.',
        );
      }
    }
    final columns = database.handle
        .select('PRAGMA table_info($table)')
        .map((r) => r['name'] as String);
    final data = <String, dynamic>{
      for (final column in columns) column: remote[column],
    };
    if (table == 'categories') {
      data['active'] = remote['active'] == true ? 1 : 0;
    }
    if (table == 'categories' || table == 'weekly_goals') {
      GoalConfig.fromMap(data).validate();
    }
    if (data.containsKey('week_start')) {
      Week.parse(data['week_start'] as String);
    }
    if (table == 'reviews') {
      final review = WeeklyReview.fromMap(
        data['week_start'] as String,
        Map<String, dynamic>.from(data['content'] as Map),
      );
      if (review.wins.length != 3 || review.done.length != 3) {
        throw const FormatException('Invalid cloud review');
      }
    }
    if (table == 'journal') Map<String, String>.from(data['experiment'] as Map);
    if (table == 'schedule_blocks') ScheduleBlock.fromMap(data).validate();
    if (table == 'academic_events') AcademicEvent.fromMap(data).validate();
    for (final field in ['experiment', 'content']) {
      if (data.containsKey(field)) data[field] = jsonEncode(data[field]);
    }
    for (final field in [
      'created_at',
      'updated_at',
      'archived_at',
      'undone_at',
      'deleted_at',
      'answered_at',
    ]) {
      if (data[field] != null) {
        data[field] = DateTime.parse(
          data[field] as String,
        ).toUtc().toIso8601String();
      }
    }
    _upsert(table, data);
    database.handle.execute(
      '''INSERT INTO sync_records (table_name,record_id,version,writer,dirty,history) VALUES (?,?,?,?,?,?)
      ON CONFLICT(table_name,record_id) DO UPDATE SET version=excluded.version,writer=excluded.writer,dirty=excluded.dirty,history=excluded.history''',
      [
        table,
        id,
        version,
        remote['sync_writer'],
        coversHistory(remoteHistory, mergedHistory) ? 0 : 1,
        jsonEncode(mergedHistory),
      ],
    );
  }

  void _upsert(String table, SyncRow data) {
    database.handle.execute(
      '''INSERT INTO $table (${data.keys.join(',')}) VALUES (${List.filled(data.length, '?').join(',')})
      ON CONFLICT(id) DO UPDATE SET ${data.keys.where((k) => k != 'id').map((k) => '$k=excluded.$k').join(',')}''',
      data.values.toList(),
    );
  }
}
