import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'support/sync_fakes.dart';

void main() {
  LocalStudyRepository memory() =>
      LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  test(
    'topic order validates a complete live set and never alters tasks or tombstones',
    () {
      final repo = memory();
      addTearDown(repo.close);
      repo.reorderTodoTopics([]);
      final a = repo.addTodoTopic('A');
      repo.reorderTodoTopics([a]);
      final b = repo.addTodoTopic('B'), c = repo.addTodoTopic('C');
      final dead = repo.addTodoTopic('Deleted');
      repo.deleteTodoTopic(dead);
      repo.addTodoTask(a, 'Active');
      final done = repo.addTodoTask(b, 'Finished');
      repo.completeTodoTask(done);
      final tasks = repo.db.select('SELECT * FROM todo_tasks');
      final deleted = repo.db.select('SELECT * FROM todo_topics WHERE id=?', [
        dead,
      ]);
      repo.reorderTodoTopics([c, a, b]);
      expect(repo.todoTopics().map((t) => t.id), [c, a, b]);
      expect(repo.todoTopics().map((t) => t.position), [0, 1, 2]);
      expect(repo.db.select('SELECT * FROM todo_tasks'), tasks);
      expect(
        repo.db.select('SELECT * FROM todo_topics WHERE id=?', [dead]),
        deleted,
      );
      final before = repo.db.select('SELECT * FROM todo_topics');
      for (final invalid in [
        <String>[],
        [a, b],
        [a, a, c],
        [a, b, dead],
        [a, b, c, 'unknown'],
      ]) {
        expect(() => repo.reorderTodoTopics(invalid), throwsFormatException);
        expect(repo.todoTopics().map((t) => t.id), [c, a, b]);
        expect(repo.db.select('SELECT * FROM todo_topics'), before);
      }
      expect(repo.db.select('SELECT * FROM todo_tasks'), tasks);
      final pending = SyncStore(repo.database).pendingRows('todo_topics');
      repo.reorderTodoTopics([c, a, b]);
      expect(SyncStore(repo.database).pendingRows('todo_topics'), pending);
    },
  );

  test(
    'topic order survives restart and offline sync without changing task ownership',
    () async {
      final folder = await Directory.systemTemp.createTemp('topic-order-');
      final path = '${folder.path}/fixture.sqlite';
      var repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      final peer = memory();
      final cloud = FakeCloud();
      Future<void> sync(LocalStudyRepository r) => SyncEngine(
        SyncStore(r.database),
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      try {
        final ids = List.generate(4, (i) => repo.addTodoTopic('Topic $i'));
        for (final id in ids) {
          repo.addTodoTask(id, 'Task $id');
        }
        await sync(repo);
        await sync(peer);
        final tasks = peer.db.select('SELECT * FROM todo_tasks');
        final order = ids.reversed.toList();
        repo.reorderTodoTopics(order);
        cloud.offline = true;
        await expectLater(sync(repo), throwsA(isA<SocketException>()));
        final pending = SyncStore(repo.database).pending;
        expect(pending, greaterThan(0));
        repo.close();
        repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        expect(repo.todoTopics().map((t) => t.id), order);
        expect(SyncStore(repo.database).pending, pending);
        cloud.offline = false;
        await sync(repo);
        await sync(peer);
        expect(peer.todoTopics().map((t) => t.id), order);
        expect(peer.db.select('SELECT * FROM todo_tasks'), tasks);
        peer.reorderTodoTopics([ids[1], ids[3], ids[0], ids[2]]);
        await sync(peer);
        await sync(repo);
        expect(repo.todoTopics().map((t) => t.id), [
          ids[1],
          ids[3],
          ids[0],
          ids[2],
        ]);
        expect(
          SyncStore(repo.database).pending + SyncStore(peer.database).pending,
          0,
        );
      } finally {
        repo.close();
        peer.close();
        await folder.delete(recursive: true);
      }
    },
  );

  for (final reverse in [false, true]) {
    test(
      'concurrent topic orders converge with stable membership: $reverse',
      () async {
        final left = memory(), right = memory(), cloud = FakeCloud();
        addTearDown(left.close);
        addTearDown(right.close);
        Future<void> sync(LocalStudyRepository r) => SyncEngine(
          SyncStore(r.database),
          cloud,
          backup: () async {},
        ).synchronize(account, project, () => true);
        final ids = List.generate(3, (i) => left.addTodoTopic('Topic $i'));
        for (final id in ids) {
          left.addTodoTask(id, 'Task $id');
        }
        await sync(left);
        await sync(right);
        left.reorderTodoTopics([ids[1], ids[2], ids[0]]);
        right.reorderTodoTopics([ids[2], ids[0], ids[1]]);
        for (final r
            in reverse
                ? [right, left, right, left]
                : [left, right, left, right]) {
          await sync(r);
        }
        expect(
          left.todoTopics().map((t) => t.id),
          right.todoTopics().map((t) => t.id),
        );
        expect(left.todoTopics().map((t) => t.id).toSet(), ids.toSet());
        for (final repo in [left, right]) {
          for (final id in ids) {
            expect(repo.todoTasks(id).single.text, 'Task $id');
          }
          expect(SyncStore(repo.database).pending, 0);
        }
      },
    );
  }
}
