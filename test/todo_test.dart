import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'support/sync_fakes.dart';

void main() {
  var now = DateTime.utc(2026, 10, 26, 10);
  LocalStudyRepository memory() => LocalStudyRepository(
    StudyDatabase(sqlite3.openInMemory()),
    clock: () => now,
  );
  test(
    'topic and task CRUD, Unicode, trimming, isolation and permanent deletion',
    () {
      final r = memory();
      addTearDown(r.close);
      for (final text in ['', '  ', '\n\t']) {
        expect(() => r.addTodoTopic(text), throwsFormatException);
      }
      final a = r.addTodoTopic('  Investigação  '), b = r.addTodoTopic('CSPH');
      expect(r.todoTopics().map((t) => t.id), [a, b]);
      expect(r.todoTopics().first.title, 'Investigação');
      r.renameTodoTopic(a, '  Português çãé  ');
      expect(r.todoTopics().first.title, 'Português çãé');
      expect(() => r.renameTodoTopic(a, ' '), throwsFormatException);
      final x = r.addTodoTask(a, '  Ler Capítulo 5  '),
          y = r.addTodoTask(b, 'Other');
      expect(r.todoTasks(a).single.id, x);
      expect(r.todoTasks(b).single.id, y);
      r.editTodoTask(x, '  ${'Long text '.padRight(4000, 'a')}  ');
      expect(r.todoTasks(a).single.text.length, 4000);
      expect(() => r.addTodoTask(a, ' '), throwsFormatException);
      expect(() => r.editTodoTask(x, ''), throwsFormatException);
      r.deleteTodoTopic(a);
      expect(r.todoTopics().single.id, b);
      expect(r.todoTasks(a), isEmpty);
      expect(
        r.db.select('SELECT deleted_at FROM todo_tasks WHERE id=?', [
          x,
        ]).single['deleted_at'],
        isNotNull,
      );
      expect(() => r.addTodoTask(a, 'Late'), throwsFormatException);
      expect(() => r.renameTodoTopic(a, 'Revive'), throwsFormatException);
      expect(() => r.editTodoTask(x, 'Revive'), throwsFormatException);
      r.deleteTodoTask(y);
      expect(r.todoTasks(b), isEmpty);
      expect(r.todoTopics().single.id, b);
    },
  );

  test(
    'ordering is transactional, deterministic with ties and restricted to active siblings',
    () {
      final r = memory();
      addTearDown(r.close);
      final topic = r.addTodoTopic('A'), other = r.addTodoTopic('B');
      final a = r.addTodoTask(topic, 'A'),
          b = r.addTodoTask(topic, 'B'),
          c = r.addTodoTask(topic, 'C');
      final foreign = r.addTodoTask(other, 'Foreign');
      r.reorderTodoTasks(topic, [c, a, b]);
      expect(r.todoTasks(topic).map((t) => t.id), [c, a, b]);
      for (final bad in [
        [a, b],
        [a, a, b],
        [a, b, foreign],
      ]) {
        expect(() => r.reorderTodoTasks(topic, bad), throwsFormatException);
      }
      r.db.execute('UPDATE todo_tasks SET position=0 WHERE topic_id=?', [
        topic,
      ]);
      expect(r.todoTasks(topic).map((t) => t.id), [a, b, c]..sort());
      r.reorderTodoTasks(topic, [c, b, a]);
      expect(r.todoTasks(topic).map((t) => t.id), [c, b, a]);
      r.completeTodoTask(b);
      expect(() => r.reorderTodoTasks(topic, [a, b, c]), throwsFormatException);
      r.reorderTodoTasks(topic, [a, c]);
      expect(r.todoTasks(topic).where((t) => !t.completed).map((t) => t.id), [
        a,
        c,
      ]);
      expect(r.todoTasks(other).single.id, foreign);
    },
  );

  test(
    'completion saves immediately, undo preserves slot and restore appends with a new completion time',
    () {
      final r = memory();
      addTearDown(r.close);
      final topic = r.addTodoTopic('Research');
      final a = r.addTodoTask(topic, 'A'), b = r.addTodoTask(topic, 'B');
      r.completeTodoTask(a);
      final stamp = r.todoTasks(topic).first.completedAt!;
      expect(stamp, now.toIso8601String());
      r.restoreTodoTask(a, undoCompletion: stamp);
      expect(r.todoTasks(topic).map((t) => t.id), [a, b]);
      r.completeTodoTask(a);
      r.restoreTodoTask(a);
      expect(r.todoTasks(topic).map((t) => t.id), [b, a]);
      expect(r.todoTasks(topic).last.completedAt, isNull);
      now = now.add(const Duration(minutes: 1));
      r.completeTodoTask(a);
      expect(r.todoTasks(topic).last.completedAt, isNot(stamp));
      expect(
        () => r.restoreTodoTask(a, undoCompletion: stamp),
        throwsFormatException,
      );
      expect(r.todoTasks(topic).length, 2);
    },
  );

  test(
    'SQLite upgrade preserves every existing table, preferences and sync metadata',
    () {
      final r = memory();
      addTearDown(r.close);
      final week = Week.containing(now);
      r.commit(r.loadWeek(week, current: week).first.goalId, 150, week);
      r.setPreference(
        'tab.order',
        '["month","week","journal","review","schedule"]',
      );
      r.setPreference('tab.week', 'false');
      r.setPreference('windows.background', 'true');
      final s = SyncStore(r.database);
      s.bind(account, project);
      r.db.execute(
        'DROP TABLE todo_tasks; DROP TABLE todo_topics; PRAGMA user_version=6',
      );
      final tables = r.db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((v) => v['name'] as String)
          .toList();
      final before = {
        for (final t in tables)
          t: r.db
              .select('SELECT * FROM $t')
              .map((v) => Map<String, Object?>.from(v))
              .toList(),
      };
      StudyDatabase(r.db);
      for (final t in tables) {
        expect(r.db.select('SELECT * FROM $t'), before[t], reason: t);
      }
      expect(r.db.select('PRAGMA user_version').single.values.single, 7);
      expect(r.todoTopics(), isEmpty);
    },
  );

  test(
    'disk restart retains IDs, order, pending completion, deletion and sync queue',
    () async {
      final dir = await Directory.systemTemp.createTemp('trackstudy-todo-');
      final file = '${dir.path}/test.sqlite';
      var r = LocalStudyRepository(StudyDatabase(sqlite3.open(file)));
      try {
        final topic = r.addTodoTopic('Research');
        final a = r.addTodoTask(topic, 'A'), b = r.addTodoTask(topic, 'B');
        r.reorderTodoTasks(topic, [b, a]);
        r.completeTodoTask(b);
        final pending = SyncStore(r.database).pending;
        r.close();
        r = LocalStudyRepository(StudyDatabase(sqlite3.open(file)));
        expect(r.todoTopics().single.id, topic);
        expect(r.todoTasks(topic).map((t) => t.id), [b, a]);
        expect(r.todoTasks(topic).first.completed, isTrue);
        expect(SyncStore(r.database).pending, pending);
        r.deleteTodoTask(a);
        r.close();
        r = LocalStudyRepository(StudyDatabase(sqlite3.open(file)));
        expect(r.todoTasks(topic).single.id, b);
        expect(
          SyncStore(r.database)
              .pendingRows('todo_tasks')
              .where((t) => t['deleted_at'] != null)
              .single['id'],
          a,
        );
      } finally {
        r.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'backup roundtrip, older backup retention, validation and deleted identity recovery',
    () {
      final r = memory(), restored = memory();
      addTearDown(r.close);
      addTearDown(restored.close);
      final old = jsonDecode(r.exportJson()) as Map<String, dynamic>;
      old['version'] = 4;
      old['tables'].remove('todo_topics');
      old['tables'].remove('todo_tasks');
      final topic = r.addTodoTopic('Research');
      final a = r.addTodoTask(topic, 'A'), b = r.addTodoTask(topic, 'B');
      r.reorderTodoTasks(topic, [b, a]);
      r.completeTodoTask(b);
      final backup = r.exportJson();
      restored.restoreJson(backup);
      expect(restored.todoTasks(topic).map((t) => t.id), [b, a]);
      expect(
        restored.todoTasks(topic).first.completedAt,
        r.todoTasks(topic).first.completedAt,
      );
      restored.restoreJson(jsonEncode(old));
      expect(restored.todoTasks(topic).length, 2);
      final bad = jsonDecode(backup);
      bad['tables']['todo_tasks'][0]['topic_id'] = account;
      expect(
        () => restored.restoreJson(jsonEncode(bad)),
        throwsFormatException,
      );
      expect(restored.todoTasks(topic).length, 2);
      restored.deleteTodoTopic(topic);
      restored.restoreJson(backup);
      final recovered = restored.todoTopics().single.id;
      expect(recovered, isNot(topic));
      expect(restored.todoTasks(recovered).map((t) => t.text), ['B', 'A']);
      expect(restored.todoTasks(recovered).first.completed, isTrue);
      expect(
        restored.db.select('SELECT deleted_at FROM todo_topics WHERE id=?', [
          topic,
        ]).single['deleted_at'],
        isNotNull,
      );
      restored.restoreJson(memoryBackupWithoutTodos(r));
      expect(restored.todoTopics(), isEmpty);
      expect(
        restored.db.select(
          'SELECT id FROM todo_tasks WHERE deleted_at IS NULL',
        ),
        isEmpty,
      );
    },
  );

  test(
    'legacy full order insertion respects hidden Progress Bars and keeps preferences local',
    () async {
      final r = memory(), phone = memory();
      addTearDown(r.close);
      addTearDown(phone.close);
      r.setPreference(
        'tab.order',
        '["review","month","week","schedule","journal"]',
      );
      r.setPreference('tab.week', 'false');
      r.setPreference('tab.journal', 'false');
      final c = StudyController(r, watchClock: false);
      addTearDown(c.dispose);
      expect(c.tabOrder, [
        StudyTab.review,
        StudyTab.month,
        StudyTab.week,
        StudyTab.todo,
        StudyTab.schedule,
        StudyTab.journal,
      ]);
      expect(c.tabVisible(StudyTab.todo), isTrue);
      final topic = r.addTodoTopic('Independent');
      r.addTodoTask(topic, 'Retained');
      c.setTabVisible(StudyTab.todo, false);
      c.setTabVisible(StudyTab.todo, true);
      expect(r.todoTasks(topic).single.text, 'Retained');
      c.reorderTab(3, 0);
      expect(c.enabledTabs.first, StudyTab.todo);
      final cloud = FakeCloud();
      await synchronize(r, cloud);
      await synchronize(phone, cloud);
      expect(phone.preference('tab.order', ''), '');
      expect(phone.todoTopics().single.id, topic);
    },
  );

  test(
    'two-device offline CRUD, order, completion, restore and retry converge without duplicates',
    () async {
      final a = memory(), b = memory();
      addTearDown(a.close);
      addTearDown(b.close);
      final cloud = FakeCloud();
      final topic = a.addTodoTopic('Research');
      final x = a.addTodoTask(topic, 'A'), y = a.addTodoTask(topic, 'B');
      await synchronize(a, cloud);
      await synchronize(b, cloud);
      cloud.offline = true;
      b.renameTodoTopic(topic, 'Investigação');
      b.editTodoTask(x, 'Ler Capítulo 5');
      b.reorderTodoTasks(topic, [y, x]);
      b.completeTodoTask(y);
      await expectLater(synchronize(b, cloud), throwsA(isA<SocketException>()));
      cloud.offline = false;
      await synchronize(b, cloud);
      await synchronize(a, cloud);
      expect(a.todoTopics().single.title, 'Investigação');
      expect(a.todoTasks(topic).map((t) => t.id), [y, x]);
      expect(a.todoTasks(topic).first.completed, isTrue);
      expect(a.todoTasks(topic).last.text, 'Ler Capítulo 5');
      a.restoreTodoTask(y);
      await synchronize(a, cloud);
      await synchronize(b, cloud);
      expect(b.todoTasks(topic).map((t) => t.id), [x, y]);
      expect(b.todoTasks(topic).last.completedAt, isNull);
      b.deleteTodoTask(x);
      cloud.loseResponseFor = 'todo_tasks';
      await expectLater(synchronize(b, cloud), throwsA(isA<SocketException>()));
      for (var i = 0; i < 3; i++) {
        await synchronize(b, cloud);
        await synchronize(a, cloud);
      }
      expect(a.todoTasks(topic).single.id, y);
      expect(cloud.tables['todo_tasks']!.length, 2);
      expect(SyncStore(a.database).pending + SyncStore(b.database).pending, 0);
      expect(cloud.conflicts, isEmpty);
    },
  );

  test(
    'concurrent task creation and reorder converge with deterministic ties',
    () async {
      final a = memory(), b = memory();
      addTearDown(a.close);
      addTearDown(b.close);
      final cloud = FakeCloud();
      final topic = a.addTodoTopic('Research');
      final x = a.addTodoTask(topic, 'A'), y = a.addTodoTask(topic, 'B');
      await synchronize(a, cloud);
      await synchronize(b, cloud);
      final z = a.addTodoTask(topic, 'PC offline task');
      final w = b.addTodoTask(topic, 'Phone offline task');
      a.reorderTodoTasks(topic, [z, y, x]);
      b.reorderTodoTasks(topic, [y, w, x]);
      for (var i = 0; i < 3; i++) {
        await synchronize(a, cloud);
        await synchronize(b, cloud);
      }
      final order = a.todoTasks(topic).map((t) => t.id).toList();
      expect(b.todoTasks(topic).map((t) => t.id), order);
      expect(order.toSet(), {x, y, z, w});
      expect(cloud.tables['todo_tasks']!.length, 4);
      expect(SyncStore(a.database).pending + SyncStore(b.database).pending, 0);
    },
  );

  test(
    'undo made during a completion upload is not overwritten by its response',
    () async {
      final r = memory();
      addTearDown(r.close);
      final cloud = FakeCloud();
      final topic = r.addTodoTopic('Research');
      final task = r.addTodoTask(topic, 'A');
      await synchronize(r, cloud);
      r.completeTodoTask(task);
      final stamp = r.todoTasks(topic).single.completedAt!;
      cloud.duringUpload = (table, row) {
        if (table == 'todo_tasks') {
          cloud.duringUpload = null;
          r.restoreTodoTask(task, undoCompletion: stamp);
        }
      };
      await synchronize(r, cloud);
      expect(r.todoTasks(topic).single.completedAt, isNull);
      expect(SyncStore(r.database).pending, 1);
      await synchronize(r, cloud);
      expect(cloud.tables['todo_tasks']![task]!['completed_at'], isNull);
      expect(SyncStore(r.database).pending, 0);
    },
  );

  for (final deleteTopic in [false, true]) {
    test(
      'deletion wins against higher offline counters and late children: topic=$deleteTopic',
      () async {
        final a = memory(), b = memory();
        addTearDown(a.close);
        addTearDown(b.close);
        final cloud = FakeCloud();
        final topic = a.addTodoTopic('Research');
        final task = a.addTodoTask(topic, 'A');
        await synchronize(a, cloud);
        await synchronize(b, cloud);
        SyncStore(b.database).setMeta('clock', '10000');
        b.editTodoTask(task, 'Offline edit');
        b.renameTodoTopic(topic, 'Offline name');
        if (deleteTopic) {
          b.addTodoTask(topic, 'Created after deletion elsewhere');
          a.deleteTodoTopic(topic);
        } else {
          a.deleteTodoTask(task);
        }
        await synchronize(a, cloud);
        await synchronize(b, cloud);
        await synchronize(a, cloud);
        for (final repo in [a, b]) {
          expect(repo.todoTasks(topic), isEmpty);
          if (deleteTopic) expect(repo.todoTopics(), isEmpty);
          expect(SyncStore(repo.database).pending, 0);
        }
        expect(
          cloud.tables['todo_tasks']!.values.every(
            (t) => t['deleted_at'] != null,
          ),
          isTrue,
        );
      },
    );
  }
}

Future<void> synchronize(LocalStudyRepository r, FakeCloud cloud) => SyncEngine(
  SyncStore(r.database),
  cloud,
  backup: () async {},
).synchronize(account, project, () => true);

String memoryBackupWithoutTodos(LocalStudyRepository r) {
  final data = jsonDecode(r.exportJson());
  data['tables']['todo_topics'] = [];
  data['tables']['todo_tasks'] = [];
  return jsonEncode(data);
}
