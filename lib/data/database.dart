import 'package:sqlite3/sqlite3.dart';

class StudyDatabase {
  final Database handle;
  StudyDatabase(this.handle) {
    handle.execute('PRAGMA foreign_keys = ON');
    handle.execute('PRAGMA busy_timeout = 5000');
    handle.execute('PRAGMA journal_mode = WAL');
    handle.execute('PRAGMA synchronous = FULL');
    migrate();
  }
  static const version = 7;
  void transaction(void Function() action) {
    handle.execute('BEGIN IMMEDIATE');
    try {
      action();
      handle.execute('COMMIT');
    } catch (_) {
      handle.execute('ROLLBACK');
      rethrow;
    }
  }

  void migrate() {
    final old = handle.select('PRAGMA user_version').first.values.first as int;
    if (old > version) {
      throw StateError(
        'This database belongs to a newer TrackStudy version. Please upgrade the app.',
      );
    }
    transaction(() {
      if (old < 1) {
        handle.execute('''
CREATE TABLE categories (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, measurement TEXT NOT NULL CHECK(measurement IN ('continuous','discrete')),
 unit TEXT NOT NULL, floor INTEGER NOT NULL CHECK(floor>=0), target INTEGER NOT NULL CHECK(target>0 AND target>=floor),
 increment INTEGER NOT NULL CHECK(increment>0), step INTEGER NOT NULL CHECK(step>0),
 position INTEGER NOT NULL, active INTEGER NOT NULL CHECK(active IN (0,1)),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT
);
CREATE TABLE weekly_goals (
 id TEXT PRIMARY KEY, category_id TEXT NOT NULL REFERENCES categories(id), week_start TEXT NOT NULL,
 name TEXT NOT NULL, measurement TEXT NOT NULL CHECK(measurement IN ('continuous','discrete')), unit TEXT NOT NULL,
 floor INTEGER NOT NULL CHECK(floor>=0), target INTEGER NOT NULL CHECK(target>0 AND target>=floor),
 increment INTEGER NOT NULL CHECK(increment>0), step INTEGER NOT NULL CHECK(step>0),
 position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 UNIQUE(category_id,week_start)
);
CREATE TABLE entries (
 id TEXT PRIMARY KEY, goal_id TEXT NOT NULL REFERENCES weekly_goals(id),
 amount INTEGER NOT NULL CHECK(typeof(amount)='integer' AND amount>0 AND amount<=100000000),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, undone_at TEXT, source TEXT NOT NULL
);
CREATE TABLE journal (
 id TEXT PRIMARY KEY, learned TEXT NOT NULL, question TEXT NOT NULL, next TEXT NOT NULL,
 experiment TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE reviews (
 id TEXT PRIMARY KEY, week_start TEXT NOT NULL UNIQUE, content TEXT NOT NULL,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
''');
      }
      if (old < 2) {
        handle.execute('''
CREATE INDEX entries_goal_active ON entries(goal_id,undone_at,created_at);
CREATE INDEX goals_week ON weekly_goals(week_start,position);
CREATE INDEX journal_date ON journal(created_at DESC);
''');
      }
      if (old < 3) {
        handle.execute('''
CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO sync_meta VALUES ('clock','0'),('applying','0'),('device',lower(hex(randomblob(16))));
CREATE TABLE sync_records (
 table_name TEXT NOT NULL, record_id TEXT NOT NULL,
 version INTEGER NOT NULL, writer TEXT NOT NULL, dirty INTEGER NOT NULL,
 PRIMARY KEY(table_name,record_id)
);
CREATE TABLE sync_conflicts (
 table_name TEXT NOT NULL, record_id TEXT NOT NULL, version INTEGER NOT NULL,
 writer TEXT NOT NULL, payload TEXT NOT NULL, saved_at TEXT NOT NULL,
 PRIMARY KEY(table_name,record_id,version,writer)
);
''');
        for (final table in [
          'categories',
          'weekly_goals',
          'entries',
          'journal',
          'reviews',
        ]) {
          handle.execute(
            "INSERT INTO sync_records SELECT '$table',id,1,(SELECT value FROM sync_meta WHERE key='device'),1 FROM $table",
          );
          for (final event in ['INSERT', 'UPDATE']) {
            handle.execute('''
CREATE TRIGGER sync_${table}_${event.toLowerCase()} AFTER $event ON $table
WHEN (SELECT value FROM sync_meta WHERE key='applying')='0'
BEGIN
 UPDATE sync_meta SET value=CAST(value AS INTEGER)+1 WHERE key='clock';
 INSERT INTO sync_records VALUES ('$table',NEW.id,(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock'),(SELECT value FROM sync_meta WHERE key='device'),1)
 ON CONFLICT(table_name,record_id) DO UPDATE SET version=excluded.version,writer=excluded.writer,dirty=1;
 ${table == 'weekly_goals' && event == 'INSERT' ? '' : "UPDATE sync_meta SET value='0' WHERE key='pristine_seed';"}
END;
''');
          }
          handle.execute('''
CREATE TRIGGER sync_${table}_delete AFTER DELETE ON $table
WHEN (SELECT value FROM sync_meta WHERE key='applying')='0'
BEGIN
 DELETE FROM sync_records WHERE table_name='$table' AND record_id=OLD.id;
 UPDATE sync_meta SET value='0' WHERE key='pristine_seed';
END;
''');
        }
        handle.execute("UPDATE sync_meta SET value='1' WHERE key='clock'");
      }
      if (old < 4) {
        handle.execute(
          "ALTER TABLE sync_records ADD COLUMN history TEXT NOT NULL DEFAULT '{}'",
        );
        handle.execute(
          'ALTER TABLE sync_conflicts ADD COLUMN archived_at TEXT',
        );
        for (final table in [
          'categories',
          'weekly_goals',
          'entries',
          'journal',
          'reviews',
        ]) {
          for (final event in ['INSERT', 'UPDATE']) {
            handle.execute('DROP TRIGGER sync_${table}_${event.toLowerCase()}');
            handle.execute('''
CREATE TRIGGER sync_${table}_${event.toLowerCase()} AFTER $event ON $table
WHEN (SELECT value FROM sync_meta WHERE key='applying')='0'
BEGIN
 UPDATE sync_meta SET value=CAST(value AS INTEGER)+1 WHERE key='clock';
 INSERT INTO sync_records (table_name,record_id,version,writer,dirty,history)
 VALUES ('$table',NEW.id,(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock'),(SELECT value FROM sync_meta WHERE key='device'),1,
 json_object((SELECT value FROM sync_meta WHERE key='device'),(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock')))
 ON CONFLICT(table_name,record_id) DO UPDATE SET
 history=json_set(json_set(sync_records.history,'\$.'||json_quote(sync_records.writer),sync_records.version),'\$.'||json_quote(excluded.writer),excluded.version),
 version=excluded.version,writer=excluded.writer,dirty=1;
 ${table == 'weekly_goals' && event == 'INSERT' ? '' : "UPDATE sync_meta SET value='0' WHERE key='pristine_seed';"}
END;
''');
          }
        }
      }
      if (old < 5) {
        handle.execute('''
CREATE TABLE schedule_blocks (
 id TEXT PRIMARY KEY, title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),
 start_minute INTEGER NOT NULL CHECK(typeof(start_minute)='integer' AND start_minute>=0 AND start_minute<1440),
 end_minute INTEGER NOT NULL CHECK(typeof(end_minute)='integer' AND end_minute>start_minute AND end_minute<=1440),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX schedule_day ON schedule_blocks(weekday,start_minute);
CREATE TABLE academic_events (
 id TEXT PRIMARY KEY, title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 event_date TEXT NOT NULL, event_type TEXT NOT NULL CHECK(event_type IN ('exam','test','project','presentation','deadline','other')),
 note TEXT NOT NULL CHECK(length(note)<=2000), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX academic_date ON academic_events(event_date);
''');
        for (final table in ['schedule_blocks', 'academic_events']) {
          for (final event in ['INSERT', 'UPDATE']) {
            handle.execute('''
CREATE TRIGGER sync_${table}_${event.toLowerCase()} AFTER $event ON $table
WHEN (SELECT value FROM sync_meta WHERE key='applying')='0'
BEGIN
 UPDATE sync_meta SET value=CAST(value AS INTEGER)+1 WHERE key='clock';
 INSERT INTO sync_records (table_name,record_id,version,writer,dirty,history)
 VALUES ('$table',NEW.id,(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock'),(SELECT value FROM sync_meta WHERE key='device'),1,
 json_object((SELECT value FROM sync_meta WHERE key='device'),(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock')))
 ON CONFLICT(table_name,record_id) DO UPDATE SET
 history=json_set(json_set(sync_records.history,'\$.'||json_quote(sync_records.writer),sync_records.version),'\$.'||json_quote(excluded.writer),excluded.version),
 version=excluded.version,writer=excluded.writer,dirty=1;
 UPDATE sync_meta SET value='0' WHERE key='pristine_seed';
END;
''');
          }
        }
      }
      if (old < 6) {
        handle.execute('''
ALTER TABLE journal ADD COLUMN answer TEXT;
ALTER TABLE journal ADD COLUMN answered_at TEXT;
ALTER TABLE schedule_blocks ADD COLUMN description TEXT CHECK(description IS NULL OR length(description)<=2000);
''');
      }
      if (old < 7) {
        handle.execute('''
CREATE TABLE todo_topics (
 id TEXT PRIMARY KEY, title TEXT NOT NULL CHECK(length(trim(title))>0),
 position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position>=0),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE todo_tasks (
 id TEXT PRIMARY KEY, topic_id TEXT NOT NULL REFERENCES todo_topics(id),
 text TEXT NOT NULL CHECK(length(trim(text))>0),
 position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position>=0),
 completed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX todo_topics_order ON todo_topics(position,id);
CREATE INDEX todo_tasks_order ON todo_tasks(topic_id,position,id);
CREATE INDEX todo_tasks_finished ON todo_tasks(topic_id,completed_at DESC,id);
CREATE TRIGGER todo_task_parent BEFORE UPDATE OF topic_id ON todo_tasks
WHEN NEW.topic_id<>OLD.topic_id
BEGIN SELECT RAISE(ABORT,'A task cannot change topic'); END;
''');
        for (final table in ['todo_topics', 'todo_tasks']) {
          handle.execute('''
CREATE TRIGGER ${table}_keep_deleted BEFORE UPDATE ON $table
WHEN OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
BEGIN SELECT RAISE(ABORT,'Deleted to-do records cannot be restored with the same ID'); END;
''');
          for (final event in ['INSERT', 'UPDATE']) {
            handle.execute('''
CREATE TRIGGER sync_${table}_${event.toLowerCase()} AFTER $event ON $table
WHEN (SELECT value FROM sync_meta WHERE key='applying')='0'
BEGIN
 UPDATE sync_meta SET value=CAST(value AS INTEGER)+1 WHERE key='clock';
 INSERT INTO sync_records (table_name,record_id,version,writer,dirty,history)
 VALUES ('$table',NEW.id,(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock'),(SELECT value FROM sync_meta WHERE key='device'),1,
 json_object((SELECT value FROM sync_meta WHERE key='device'),(SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key='clock')))
 ON CONFLICT(table_name,record_id) DO UPDATE SET
 history=json_set(json_set(sync_records.history,'\$.'||json_quote(sync_records.writer),sync_records.version),'\$.'||json_quote(excluded.writer),excluded.version),
 version=excluded.version,writer=excluded.writer,dirty=1;
 UPDATE sync_meta SET value='0' WHERE key='pristine_seed';
END;
''');
          }
        }
      }
      handle.execute('PRAGMA user_version = $version');
    });
  }

  void close() => handle.close();
}
