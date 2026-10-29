import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import '../domain/models.dart';
import '../domain/repository.dart';
import '../domain/week.dart';
import '../domain/planning.dart';
import '../domain/todo.dart';
import 'database.dart';
import 'category_lifecycle.dart';

class LocalStudyRepository implements StudyRepository {
  final StudyDatabase database;
  @override
  final String location;
  final DateTime Function() clock;
  final _uuid = const Uuid();
  Database get db => database.handle;
  String get now => clock().toUtc().toIso8601String();
  LocalStudyRepository(
    this.database, {
    this.location = 'In memory',
    DateTime Function()? clock,
    bool seed = true,
  }) : clock = clock ?? DateTime.now {
    if (seed && preference('initialized', '') != 'yes') {
      _seed();
    }
  }
  void _insert(String table, Map<String, Object?> row) {
    db.execute(
      'INSERT INTO $table (${row.keys.join(',')}) VALUES (${List.filled(row.length, '?').join(',')})',
      row.values.toList(),
    );
  }

  void _seed() => database.transaction(() {
    const defaults = [
      ('Research', 6, 8),
      ('CSPH', 6, 8),
      ('NLP', 3, 5),
      ('IAES', 1, 2),
      ('Gym', 3, 5),
      ('Sleep', 5, 7),
      ('Wake-up', 5, 7),
    ];
    for (var i = 0; i < defaults.length; i++) {
      final d = defaults[i];
      _insert('categories', {
        'id': _uuid.v4(),
        ...GoalConfig(
          name: d.$1,
          measurement: i < 4 ? Measurement.continuous : Measurement.discrete,
          unit: i < 4 ? 'h' : '',
          floor: d.$2 * 100,
          target: d.$3 * 100,
          increment: 100,
          step: i < 4 ? 25 : 100,
        ).toMap(),
        'position': i,
        'active': 1,
        'created_at': now,
        'updated_at': now,
        'archived_at': null,
      });
    }
    setPreference('initialized', 'yes');
    db.execute("INSERT OR REPLACE INTO sync_meta VALUES ('pristine_seed','1')");
  });
  @override
  List<Category> categories() => db
      .select('SELECT * FROM categories ORDER BY position,id')
      .map(
        (r) => Category(
          r['id'] as String,
          GoalConfig.fromMap(r),
          r['position'] as int,
          r['active'] == 1,
          r['archived_at'] != null,
        ),
      )
      .toList();
  void _ensureWeek(Week week) {
    _initializeLifecycle(week);
    final included = db
        .select(
          'SELECT c.id FROM categories c WHERE ${categoryInclusionSql('c.id', '?')}=1',
          [week.key],
        )
        .map((r) => r['id'])
        .toSet();
    for (final c in categories().where((c) => included.contains(c.id))) {
      if (db.select(
        'SELECT id FROM weekly_goals WHERE category_id=? AND week_start=?',
        [c.id, week.key],
      ).isEmpty) {
        _insert('weekly_goals', {
          'id': _uuid.v4(),
          'category_id': c.id,
          'week_start': week.key,
          ...c.config.toMap(),
          'position': c.position,
          'created_at': now,
          'updated_at': now,
        });
      }
    }
  }

  @override
  List<WeeklyProgress> loadWeek(Week week, {required Week current}) {
    database.transaction(() {
      _initializeLifecycle(current);
      if (week == current) _ensureWeek(week);
    });
    return db
        .select(
          '''SELECT g.*, COALESCE(SUM(CASE WHEN e.undone_at IS NULL THEN e.amount ELSE 0 END),0) total,
      COUNT(CASE WHEN e.undone_at IS NULL THEN e.id END) active_entries FROM weekly_goals g
      JOIN categories c ON c.id=g.category_id LEFT JOIN entries e ON e.goal_id=g.id
      WHERE g.week_start=? AND ${categoryInclusionSql('g.category_id', 'g.week_start')}=1
      GROUP BY g.id ORDER BY ${week == current ? 'c.position' : 'g.position'},g.id''',
          [week.key],
        )
        .map(
          (r) => WeeklyProgress(
            goalId: r['id'] as String,
            categoryId: r['category_id'] as String,
            week: week.key,
            config: GoalConfig.fromMap(r),
            total: r['total'] as int,
            activeEntries: r['active_entries'] as int,
          ),
        )
        .toList();
  }

  @override
  void saveCategory(String? id, GoalConfig config, Week current) {
    config.validate();
    database.transaction(() {
      if (id == null) {
        final categoryId = _uuid.v4();
        _insert('categories', {
          'id': categoryId,
          ...config.toMap(),
          'position': categories().length,
          'active': 1,
          'created_at': now,
          'updated_at': now,
          'archived_at': null,
        });
        _saveCategoryState(categoryId, current, included: true);
      } else {
        final old = categories().firstWhere((c) => c.id == id);
        final used = db.select(
          'SELECT e.id FROM entries e JOIN weekly_goals g ON g.id=e.goal_id WHERE g.category_id=? AND g.week_start=? LIMIT 1',
          [id, current.key],
        ).isNotEmpty;
        if (used &&
            (old.config.measurement != config.measurement ||
                old.config.unit != config.unit)) {
          throw const FormatException(
            'This week already has entries. Change the unit/type next week, or add a new category.',
          );
        }
        final values = config.toMap();
        final assignments = values.keys.map((k) => '$k=?').join(',');
        db.execute(
          'UPDATE categories SET $assignments,updated_at=? WHERE id=?',
          [...values.values, now, id],
        );
        db.execute(
          'UPDATE weekly_goals SET $assignments,updated_at=? WHERE category_id=? AND week_start=?',
          [...values.values, now, id, current.key],
        );
      }
      _ensureWeek(current);
    });
  }

  @override
  void setCategoryStatus(
    String id, {
    required Week current,
    required bool active,
    required bool archived,
  }) => database.transaction(() {
    if (!categories().any((c) => c.id == id)) {
      throw const FormatException('This bar is no longer available.');
    }
    _initializeLifecycle(current);
    _saveCategoryState(id, current, included: active && !archived);
    normalizeCategoryStatuses(db);
    _ensureWeek(current);
  });

  void _initializeLifecycle(Week current) {
    for (final row in db.select(
      '''SELECT c.* FROM categories c
      WHERE NOT EXISTS (SELECT 1 FROM category_states s WHERE s.category_id=c.id)''',
    )) {
      _saveCategoryState(
        row['id'] as String,
        current,
        included: row['active'] == 1 && row['archived_at'] == null,
        baseline: true,
        changedAt: row['archived_at'] as String?,
      );
    }
    normalizeCategoryStatuses(db);
  }

  void _saveCategoryState(
    String id,
    Week week, {
    required bool included,
    bool baseline = false,
    String? changedAt,
  }) {
    final stamp = now;
    db.execute(
      '''INSERT INTO category_states
      (id,category_id,week_start,included,is_baseline,changed_at,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(category_id,week_start) DO UPDATE SET
      included=excluded.included,is_baseline=excluded.is_baseline,
      changed_at=excluded.changed_at,updated_at=excluded.updated_at''',
      [
        _uuid.v5(
          Namespace.url.value,
          'trackstudy:category-state:$id:${week.key}',
        ),
        id,
        week.key,
        included ? 1 : 0,
        baseline ? 1 : 0,
        changedAt ?? stamp,
        stamp,
        stamp,
      ],
    );
  }

  @override
  void reorder(List<String> ids) {
    final actual = categories().map((c) => c.id).toSet();
    if (ids.length != actual.length ||
        ids.toSet().length != ids.length ||
        !actual.containsAll(ids)) {
      throw const FormatException('Invalid category order');
    }
    database.transaction(() {
      for (var i = 0; i < ids.length; i++) {
        db.execute('UPDATE categories SET position=?,updated_at=? WHERE id=?', [
          i,
          now,
          ids[i],
        ]);
      }
    });
  }

  GoalConfig _editableGoal(String id, Week current) {
    final rows = db.select(
      'SELECT g.* FROM weekly_goals g JOIN categories c ON c.id=g.category_id WHERE g.id=? AND g.week_start=? AND c.active=1 AND c.archived_at IS NULL AND ${categoryInclusionSql('g.category_id', 'g.week_start')}=1',
      [id, current.key],
    );
    if (rows.isEmpty) {
      throw const FormatException(
        'Only active categories in the current week can be changed.',
      );
    }
    return GoalConfig.fromMap(rows.first);
  }

  @override
  void commit(String goalId, int amount, Week current) =>
      database.transaction(() {
        final config = _editableGoal(goalId, current);
        if (amount <= 0 ||
            amount > Amount.max ||
            (config.measurement == Measurement.discrete && amount % 100 != 0)) {
          throw const FormatException('Invalid addition');
        }
        _insert('entries', {
          'id': _uuid.v4(),
          'goal_id': goalId,
          'amount': amount,
          'created_at': now,
          'updated_at': now,
          'undone_at': null,
          'source': 'manual',
        });
      });
  @override
  void undo(String goalId, Week current) => database.transaction(() {
    _editableGoal(goalId, current);
    // rowid breaks timestamp ties in local insertion order; UUID remains identity.
    final rows = db.select(
      'SELECT id FROM entries WHERE goal_id=? AND undone_at IS NULL ORDER BY created_at DESC,rowid DESC LIMIT 1',
      [goalId],
    );
    if (rows.isNotEmpty) {
      db.execute(
        'UPDATE entries SET undone_at=?,updated_at=? WHERE id=? AND undone_at IS NULL',
        [now, now, rows.first['id']],
      );
    }
  });
  @override
  List<LedgerEntry> entries(String goalId) => db
      .select(
        'SELECT * FROM entries WHERE goal_id=? ORDER BY created_at DESC,rowid DESC',
        [goalId],
      )
      .map(
        (r) => LedgerEntry(
          r['id'] as String,
          r['goal_id'] as String,
          r['amount'] as int,
          r['created_at'] as String,
          r['undone_at'] as String?,
        ),
      )
      .toList();
  @override
  void setUndone(String entryId, bool undone, Week current) =>
      database.transaction(() {
        final r = db.select('SELECT * FROM entries WHERE id=?', [
          entryId,
        ]).first;
        _editableGoal(r['goal_id'] as String, current);
        db.execute('UPDATE entries SET undone_at=?,updated_at=? WHERE id=?', [
          undone ? now : null,
          now,
          entryId,
        ]);
      });
  @override
  List<JournalEntry> journal(String search) => db
      .select(
        'SELECT * FROM journal WHERE deleted_at IS NULL ORDER BY created_at DESC,rowid DESC',
      )
      .map(
        (r) => JournalEntry(
          id: r['id'] as String,
          createdAt: r['created_at'] as String,
          learned: r['learned'] as String,
          question: r['question'] as String,
          next: r['next'] as String,
          answer: r['answer'] as String?,
          answeredAt: r['answered_at'] as String?,
          experiment: (jsonDecode(r['experiment'] as String) as Map)
              .cast<String, String>(),
        ),
      )
      .where(
        (j) =>
            '${j.learned} ${j.question} ${j.answer ?? ''} ${j.next} ${j.experiment.values.join(' ')}'
                .toLowerCase()
                .contains(search.toLowerCase()),
      )
      .toList();
  @override
  void saveJournal(JournalEntry entry) {
    if ([
      entry.learned,
      entry.question,
      entry.next,
    ].every((s) => s.trim().isEmpty)) {
      throw const FormatException('Write at least one thought before saving.');
    }
    db.execute(
      '''INSERT INTO journal(id,learned,question,next,experiment,created_at,updated_at,answer,answered_at)
      VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET learned=excluded.learned,question=excluded.question,
      next=excluded.next,experiment=excluded.experiment,updated_at=excluded.updated_at,
      answer=excluded.answer,answered_at=excluded.answered_at''',
      [
        entry.id,
        entry.learned,
        entry.question,
        entry.next,
        jsonEncode(entry.experiment),
        entry.createdAt,
        now,
        entry.question.trim().isEmpty || (entry.answer?.trim().isEmpty ?? true)
            ? null
            : entry.answer!.trim(),
        entry.question.trim().isEmpty || (entry.answer?.trim().isEmpty ?? true)
            ? null
            : entry.answeredAt ?? now,
      ],
    );
  }

  @override
  void answerJournal(String id, String? answer, {required String question}) {
    database.transaction(() {
      final rows = db.select(
        'SELECT question FROM journal WHERE id=? AND deleted_at IS NULL',
        [id],
      );
      if (rows.isEmpty ||
          rows.single['question'] != question ||
          question.trim().isEmpty) {
        throw const FormatException(
          'This question has changed or is no longer available. Reopen the answer editor.',
        );
      }
      final value = answer?.trim();
      final saved = value == null || value.isEmpty ? null : value;
      db.execute(
        'UPDATE journal SET answer=?,answered_at=?,updated_at=? WHERE id=?',
        [saved, saved == null ? null : now, now, id],
      );
    });
  }

  @override
  WeeklyReview review(Week week) {
    final rows = db.select(
      'SELECT content FROM reviews WHERE week_start=? AND deleted_at IS NULL',
      [week.key],
    );
    return rows.isEmpty
        ? WeeklyReview(week: week.key)
        : WeeklyReview.fromMap(
            week.key,
            jsonDecode(rows.first['content'] as String) as Map<String, dynamic>,
          );
  }

  @override
  void saveReview(WeeklyReview review) {
    Week.parse(review.week);
    if (review.wins.length != 3 || review.done.length != 3) {
      throw const FormatException('Exactly three wins are required.');
    }
    db.execute(
      '''INSERT INTO reviews(id,week_start,content,created_at,updated_at) VALUES(?,?,?,?,?)
      ON CONFLICT(week_start) DO UPDATE SET content=excluded.content,updated_at=excluded.updated_at,deleted_at=NULL''',
      [_uuid.v4(), review.week, jsonEncode(review.toMap()), now, now],
    );
  }

  @override
  String preference(String key, String fallback) {
    final rows = db.select('SELECT value FROM preferences WHERE key=?', [key]);
    return rows.isEmpty ? fallback : rows.first['value'] as String;
  }

  @override
  List<ScheduleBlock> schedule(int weekday) => db
      .select(
        'SELECT * FROM schedule_blocks WHERE weekday=? AND deleted_at IS NULL ORDER BY start_minute,end_minute,id',
        [weekday],
      )
      .map(ScheduleBlock.fromMap)
      .toList();
  @override
  void saveSchedule(ScheduleBlock block) {
    block.validate();
    _savePlanning('schedule_blocks', block.toMap());
  }

  @override
  void deleteSchedule(String id) => _deletePlanning('schedule_blocks', id);
  @override
  List<AcademicEvent> academicEvents(DateTime month) => db
      .select(
        'SELECT * FROM academic_events WHERE event_date>=? AND event_date<=? AND deleted_at IS NULL ORDER BY event_date,title,id',
        [
          LocalDate.key(DateTime(month.year, month.month)),
          LocalDate.key(DateTime(month.year, month.month + 1, 0)),
        ],
      )
      .map(AcademicEvent.fromMap)
      .toList();
  @override
  void saveAcademicEvent(AcademicEvent event) {
    event.validate();
    _savePlanning('academic_events', event.toMap());
  }

  @override
  void deleteAcademicEvent(String id) => _deletePlanning('academic_events', id);
  void _savePlanning(String table, Map<String, Object?> row) {
    if (!Uuid.isValidUUID(fromString: row['id'] as String)) {
      throw const FormatException('Invalid record identifier');
    }
    final data = {
      ...row,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
    };
    db.execute(
      'INSERT INTO $table (${data.keys.join(',')}) VALUES (${List.filled(data.length, '?').join(',')}) ON CONFLICT(id) DO UPDATE SET ${data.keys.where((k) => k != 'id' && k != 'created_at').map((k) => '$k=excluded.$k').join(',')}',
      data.values.toList(),
    );
  }

  void _deletePlanning(String table, String id) => db.execute(
    'UPDATE $table SET deleted_at=?,updated_at=? WHERE id=? AND deleted_at IS NULL',
    [now, now, id],
  );

  @override
  List<TodoTopic> todoTopics() => db
      .select(
        'SELECT * FROM todo_topics WHERE deleted_at IS NULL ORDER BY position,id',
      )
      .map(TodoTopic.fromMap)
      .toList();

  @override
  List<TodoTask> todoTasks(String topicId) => db
      .select(
        '''SELECT t.* FROM todo_tasks t JOIN todo_topics p ON p.id=t.topic_id
    WHERE t.topic_id=? AND t.deleted_at IS NULL AND p.deleted_at IS NULL
    ORDER BY t.position,t.id''',
        [topicId],
      )
      .map(TodoTask.fromMap)
      .toList();

  void _requireTodoTopic(String id) {
    if (db.select(
      'SELECT id FROM todo_topics WHERE id=? AND deleted_at IS NULL',
      [id],
    ).isEmpty) {
      throw const FormatException('This topic is no longer available.');
    }
  }

  TodoTask _requireTodoTask(String id) {
    final rows = db.select(
      '''SELECT t.* FROM todo_tasks t JOIN todo_topics p ON p.id=t.topic_id
      WHERE t.id=? AND t.deleted_at IS NULL AND p.deleted_at IS NULL''',
      [id],
    );
    if (rows.isEmpty) {
      throw const FormatException('This task is no longer available.');
    }
    return TodoTask.fromMap(rows.single);
  }

  int _nextTodoPosition(String topicId) =>
      db.select(
            'SELECT COALESCE(MAX(position),-1)+1 n FROM todo_tasks WHERE topic_id=? AND deleted_at IS NULL',
            [topicId],
          ).single['n']
          as int;

  @override
  String addTodoTopic(String title) {
    final text = todoText(title), id = _uuid.v4(), stamp = now;
    database.transaction(
      () => _insert('todo_topics', {
        'id': id,
        'title': text,
        'position': db
            .select('SELECT COALESCE(MAX(position),-1)+1 n FROM todo_topics')
            .single['n'],
        'created_at': stamp,
        'updated_at': stamp,
        'deleted_at': null,
      }),
    );
    return id;
  }

  @override
  void renameTodoTopic(String id, String title) {
    final text = todoText(title);
    _requireTodoTopic(id);
    db.execute('UPDATE todo_topics SET title=?,updated_at=? WHERE id=?', [
      text,
      now,
      id,
    ]);
  }

  @override
  void deleteTodoTopic(String id) => database.transaction(() {
    final stamp = now;
    db.execute(
      'UPDATE todo_tasks SET deleted_at=?,updated_at=? WHERE topic_id=? AND deleted_at IS NULL',
      [stamp, stamp, id],
    );
    db.execute(
      'UPDATE todo_topics SET deleted_at=?,updated_at=? WHERE id=? AND deleted_at IS NULL',
      [stamp, stamp, id],
    );
  });

  @override
  void reorderTodoTopics(List<String> ids) => database.transaction(() {
    final topics = todoTopics().map((topic) => topic.id).toSet();
    if (ids.length != topics.length ||
        ids.toSet().length != ids.length ||
        !topics.containsAll(ids)) {
      throw const FormatException('Topics changed. Try dragging again.');
    }
    final stamp = now;
    for (var i = 0; i < ids.length; i++) {
      db.execute(
        'UPDATE todo_topics SET position=?,updated_at=? WHERE id=? AND position<>?',
        [i, stamp, ids[i], i],
      );
    }
  });

  @override
  String addTodoTask(String topicId, String text) {
    final value = todoText(text), id = _uuid.v4(), stamp = now;
    database.transaction(() {
      _requireTodoTopic(topicId);
      _insert('todo_tasks', {
        'id': id,
        'topic_id': topicId,
        'text': value,
        'position': _nextTodoPosition(topicId),
        'completed_at': null,
        'created_at': stamp,
        'updated_at': stamp,
        'deleted_at': null,
      });
    });
    return id;
  }

  @override
  void editTodoTask(String id, String text) {
    final value = todoText(text);
    _requireTodoTask(id);
    db.execute('UPDATE todo_tasks SET text=?,updated_at=? WHERE id=?', [
      value,
      now,
      id,
    ]);
  }

  @override
  void deleteTodoTask(String id) => _deletePlanning('todo_tasks', id);

  @override
  void reorderTodoTasks(String topicId, List<String> ids) {
    _requireTodoTopic(topicId);
    final tasks = todoTasks(topicId);
    final active = tasks.where((t) => !t.completed).map((t) => t.id).toSet();
    if (ids.length != active.length ||
        ids.toSet().length != ids.length ||
        !active.containsAll(ids)) {
      throw const FormatException('Tasks changed. Try dragging again.');
    }
    database.transaction(() {
      final stamp = now;
      var activeIndex = 0;
      // Keep completed slots while normalizing ties from concurrent creation
      for (var i = 0; i < tasks.length; i++) {
        final id = tasks[i].completed ? tasks[i].id : ids[activeIndex++];
        db.execute(
          'UPDATE todo_tasks SET position=?,updated_at=? WHERE id=? AND position<>?',
          [i, stamp, id, i],
        );
      }
    });
  }

  @override
  void completeTodoTask(String id) {
    final task = _requireTodoTask(id);
    if (task.completed) return;
    final stamp = now;
    db.execute('UPDATE todo_tasks SET completed_at=?,updated_at=? WHERE id=?', [
      stamp,
      stamp,
      id,
    ]);
  }

  @override
  void restoreTodoTask(
    String id, {
    String? undoCompletion,
  }) => database.transaction(() {
    final task = _requireTodoTask(id);
    if (!task.completed) return;
    if (undoCompletion != null && task.completedAt != undoCompletion) {
      throw const FormatException(
        'This completion changed on another device. Reopen the task.',
      );
    }
    db.execute(
      'UPDATE todo_tasks SET completed_at=NULL,position=?,updated_at=? WHERE id=?',
      [
        undoCompletion == null
            ? _nextTodoPosition(task.topicId)
            : task.position,
        now,
        id,
      ],
    );
  });

  @override
  void setPreference(String key, String value) => db.execute(
    'INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  static const tables = [
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
    'preferences',
  ];
  @override
  String exportJson() => const JsonEncoder.withIndent('  ').convert({
    'format': 'trackstudy',
    'version': 6,
    'exported_at': now,
    'tables': {
      for (final table in tables)
        table: db
            .select(
              'SELECT * FROM $table${table == 'preferences' ? " WHERE key NOT LIKE 'windows.%'" : ''}',
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
    },
  });
  @override
  void restoreJson(String data) {
    // Validate a complete restore in a throwaway database before touching live data.
    final candidate = LocalStudyRepository(
      StudyDatabase(sqlite3.openInMemory()),
      seed: false,
    );
    try {
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      if (decoded['format'] != 'trackstudy' ||
          ![2, 3, 4, 5, 6].contains(decoded['version'])) {
        throw const FormatException('Unsupported backup format/version');
      }
      final rows = decoded['tables'] as Map<String, dynamic>;
      final legacy = decoded['version'] == 2;
      candidate.database.transaction(() {
        for (final table in tables) {
          if ((decoded['version'] as int) < 6 && table == 'category_states') {
            continue;
          }
          if ((decoded['version'] as int) < 5 && table.startsWith('todo_')) {
            continue;
          }
          if (legacy &&
              ['schedule_blocks', 'academic_events'].contains(table)) {
            continue;
          }
          final columns = candidate.db
              .select('PRAGMA table_info($table)')
              .map((r) => r['name'] as String)
              .toSet();
          for (final raw in rows[table] as List) {
            final row = (raw as Map).cast<String, Object?>();
            if ((decoded['version'] as int) < 4) {
              if (table == 'journal') {
                row.putIfAbsent('answer', () => null);
                row.putIfAbsent('answered_at', () => null);
              }
              if (table == 'schedule_blocks') {
                row.putIfAbsent('description', () => null);
              }
            }
            if (row.length != columns.length ||
                !columns.containsAll(row.keys)) {
              throw const FormatException('Invalid backup columns');
            }
            for (final key in ['id', 'category_id', 'goal_id', 'topic_id']) {
              if (row.containsKey(key) &&
                  !Uuid.isValidUUID(fromString: row[key] as String)) {
                throw const FormatException('Invalid record identifier');
              }
            }
            for (final key in [
              'created_at',
              'updated_at',
              'undone_at',
              'archived_at',
              'deleted_at',
              'answered_at',
              'completed_at',
              'changed_at',
            ]) {
              if (row[key] != null &&
                  DateTime.tryParse(row[key] as String) == null) {
                throw const FormatException('Invalid timestamp');
              }
            }
            if (table == 'categories' || table == 'weekly_goals') {
              GoalConfig.fromMap(row).validate();
              if (row['position'] is! int || (row['position'] as int) < 0) {
                throw const FormatException('Invalid category position');
              }
            }
            if (row.containsKey('week_start')) {
              Week.parse(row['week_start'] as String);
            }
            if (table == 'reviews') {
              final review = WeeklyReview.fromMap(
                row['week_start'] as String,
                jsonDecode(row['content'] as String) as Map<String, dynamic>,
              );
              if (review.wins.length != 3 || review.done.length != 3) {
                throw const FormatException('Invalid review wins');
              }
            }
            if (table == 'journal') {
              if (row['answer'] != null &&
                  (row['answer'] is! String ||
                      (row['question'] as String).trim().isEmpty)) {
                throw const FormatException('An answer needs a question.');
              }
              Map<String, String>.from(
                jsonDecode(row['experiment'] as String) as Map,
              );
            }
            if (table == 'schedule_blocks') {
              ScheduleBlock.fromMap(row).validate();
            }
            if (table == 'academic_events') {
              AcademicEvent.fromMap(row).validate();
            }
            if (table.startsWith('todo_')) {
              todoText(
                row[table == 'todo_topics' ? 'title' : 'text'] as String,
              );
            }
            if (table == 'preferences' &&
                (row['key'] as String).startsWith('windows.')) {
              continue;
            }
            candidate._insert(table, row);
          }
        }
      });
      candidate.journal('');
      if (candidate.db
          .select(
            "SELECT e.id FROM entries e JOIN weekly_goals g ON g.id=e.goal_id WHERE g.measurement='discrete' AND e.amount%100!=0",
          )
          .isNotEmpty) {
        throw const FormatException('Invalid discrete entry');
      }
      if (candidate.preference('initialized', '') != 'yes') {
        throw const FormatException('Incomplete backup');
      }
      database.transaction(() {
        // Older backups cannot erase lifecycle decisions they never contained
        final retainedStates = (decoded['version'] as int) < 6
            ? db
                  .select('SELECT * FROM category_states')
                  .map((r) => Map<String, Object?>.from(r))
                  .toList()
            : <Map<String, Object?>>[];
        final windowsPreferences = db
            .select("SELECT * FROM preferences WHERE key LIKE 'windows.%'")
            .map((r) => Map<String, Object?>.from(r))
            .toList();
        for (final table in tables.reversed) {
          if (table.startsWith('todo_')) continue;
          if (['schedule_blocks', 'academic_events'].contains(table)) continue;
          db.execute('DELETE FROM $table');
        }
        final todoIds = <String, String>{};
        for (final table in tables) {
          if (table.startsWith('todo_')) {
            if ((decoded['version'] as int) < 5) continue;
            final restored = candidate.db.select('SELECT * FROM $table');
            final ids = restored.map((r) => r['id']).toSet();
            for (final row in db.select(
              'SELECT id FROM $table WHERE deleted_at IS NULL',
            )) {
              if (!ids.contains(row['id'])) {
                _deletePlanning(table, row['id'] as String);
              }
            }
            for (final row in restored) {
              final data = Map<String, Object?>.from(row)..['updated_at'] = now;
              final old = db.select(
                'SELECT deleted_at FROM $table WHERE id=?',
                [data['id']],
              );
              final movedParent =
                  table == 'todo_tasks' &&
                  todoIds.containsKey(data['topic_id']);
              // An explicit backup recovery creates new identities for deleted data
              if (movedParent ||
                  (data['deleted_at'] == null &&
                      old.isNotEmpty &&
                      old.single['deleted_at'] != null)) {
                final previous = data['id'] as String;
                data['id'] = todoIds[previous] = _uuid.v4();
              }
              if (table == 'todo_tasks') {
                data['topic_id'] =
                    todoIds[data['topic_id']] ?? data['topic_id'];
                final parent = db.select(
                  'SELECT deleted_at FROM todo_topics WHERE id=?',
                  [data['topic_id']],
                ).single;
                data['deleted_at'] ??= parent['deleted_at'];
              }
              db.execute(
                'INSERT INTO $table (${data.keys.join(',')}) VALUES (${List.filled(data.length, '?').join(',')}) ON CONFLICT(id) DO UPDATE SET ${data.keys.where((k) => k != 'id' && k != 'created_at').map((k) => '$k=excluded.$k').join(',')}',
                data.values.toList(),
              );
            }
            continue;
          }
          if (['schedule_blocks', 'academic_events'].contains(table)) {
            if (legacy) {
              continue; // Old backups cannot erase data they never contained.
            }
            final restored = candidate.db.select('SELECT * FROM $table');
            final ids = restored.map((r) => r['id']).toSet();
            for (final row in db.select(
              'SELECT id FROM $table WHERE deleted_at IS NULL',
            )) {
              if (!ids.contains(row['id'])) {
                _deletePlanning(table, row['id'] as String);
              }
            }
            for (final row in restored) {
              final data = Map<String, Object?>.from(row)..['updated_at'] = now;
              db.execute(
                'INSERT INTO $table (${data.keys.join(',')}) VALUES (${List.filled(data.length, '?').join(',')}) ON CONFLICT(id) DO UPDATE SET ${data.keys.where((k) => k != 'id' && k != 'created_at').map((k) => '$k=excluded.$k').join(',')}',
                data.values.toList(),
              );
            }
            continue;
          }
          for (final row in candidate.db.select('SELECT * FROM $table')) {
            _insert(table, row);
          }
        }
        for (final row in windowsPreferences) {
          _insert('preferences', row);
        }
        final restoredCategories = categories().map((c) => c.id).toSet();
        for (final state in retainedStates) {
          if (restoredCategories.contains(state['category_id'])) {
            _insert('category_states', state);
          }
        }
        _initializeLifecycle(Week.containing(clock()));
      });
    } catch (e) {
      throw FormatException('Restore rejected; existing data is unchanged. $e');
    } finally {
      candidate.close();
    }
  }

  @override
  void close() => database.close();
}
