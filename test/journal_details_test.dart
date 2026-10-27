import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/models.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'support/sync_fakes.dart';

LocalStudyRepository memory() =>
    LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
JournalEntry thought({String? id, String question = 'Why objective Y?'}) =>
    JournalEntry(
      id: id ?? const Uuid().v4(),
      createdAt: '2026-09-29T10:00:00Z',
      learned: 'Embedding method X',
      question: question,
      next: 'Read section 3',
    );
ScheduleBlock lesson({String? id, String? description}) => ScheduleBlock(
  id: id ?? const Uuid().v4(),
  title: 'IAES (L)',
  weekday: 1,
  startMinute: 510,
  endMinute: 600,
  description: description,
);
void main() {
  test(
    'schema 5 migration preserves records, identity and dirty queue with null new fields',
    () {
      final repo = memory();
      addTearDown(repo.close);
      final entry = thought(), block = lesson();
      repo.saveJournal(entry);
      repo.saveSchedule(block);
      final store = SyncStore(repo.database), raw = repo.database.handle;
      final device = store.meta('device'), pending = store.pending;
      raw.execute(
        'DROP TABLE todo_tasks; DROP TABLE todo_topics; ALTER TABLE journal DROP COLUMN answer; ALTER TABLE journal DROP COLUMN answered_at; ALTER TABLE schedule_blocks DROP COLUMN description; PRAGMA user_version=5',
      );
      final originalJournal = raw.select('SELECT * FROM journal').single;
      StudyDatabase(raw);
      expect(
        raw.select('PRAGMA user_version').single.values.single,
        StudyDatabase.version,
      );
      for (final field in originalJournal.entries) {
        expect(
          raw.select('SELECT * FROM journal').single[field.key],
          field.value,
        );
      }
      expect(repo.journal('').single.answer, isNull);
      expect(repo.journal('').single.answeredAt, isNull);
      expect(repo.schedule(1).single.description, isNull);
      expect(repo.schedule(1).single.id, block.id);
      expect(store.meta('device'), device);
      expect(store.pending, pending);
    },
  );
  test(
    'answer add/edit/clear preserves question and other fields; rejects empty or changed questions',
    () {
      final repo = memory();
      addTearDown(repo.close);
      final entry = thought();
      repo.saveJournal(entry);
      repo.answerJournal(
        entry.id,
        'Because Y optimizes embeddings.',
        question: entry.question,
      );
      expect(
        repo.journal('optimizes').single.answer,
        'Because Y optimizes embeddings.',
      );
      expect(repo.journal('').single.answeredAt, isNotNull);
      repo.answerJournal(
        entry.id,
        'Improved explanation',
        question: entry.question,
      );
      expect(repo.journal('').single.answer, 'Improved explanation');
      expect(repo.journal('').single.question, entry.question);
      expect(repo.journal('').single.learned, entry.learned);
      expect(
        () => repo.answerJournal(
          entry.id,
          'Wrong context',
          question: 'Changed question',
        ),
        throwsFormatException,
      );
      expect(repo.journal('').single.answer, 'Improved explanation');
      repo.answerJournal(entry.id, ' ', question: entry.question);
      expect(repo.journal('').single.answer, isNull);
      expect(repo.journal('').single.answeredAt, isNull);
      final empty = thought(question: ' ');
      repo.saveJournal(empty);
      expect(
        () => repo.answerJournal(empty.id, 'Meaningless', question: ' '),
        throwsFormatException,
      );
    },
  );
  test(
    'answer and description persist through a real file reopen and edit/clear',
    () async {
      final dir = await Directory.systemTemp.createTemp('trackstudy-details-');
      final path = '${dir.path}/test.sqlite';
      var repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      final entry = thought(), block = lesson(description: 'V0.04');
      try {
        repo.saveJournal(entry);
        repo.answerJournal(entry.id, 'Explanation', question: entry.question);
        repo.saveSchedule(block);
        repo.close();
        repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        expect(repo.journal('').single.answer, 'Explanation');
        expect(repo.schedule(1).single.description, 'V0.04');
        repo.saveSchedule(
          lesson(id: block.id, description: 'Building V, V0.05'),
        );
        expect(repo.schedule(1).single.description, 'Building V, V0.05');
        repo.saveSchedule(lesson(id: block.id, description: ' '));
        expect(repo.schedule(1).single.description, isNull);
      } finally {
        repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'format 4 backups include fields; formats 2 and 3 default absent fields safely',
    () {
      final repo = memory();
      addTearDown(repo.close);
      final entry = thought(), block = lesson(description: 'V0.04');
      repo.saveJournal(entry);
      repo.answerJournal(entry.id, 'Explanation', question: entry.question);
      repo.saveSchedule(block);
      final backup = repo.exportJson();
      expect(jsonDecode(backup)['version'], 5);
      final restored = memory();
      addTearDown(restored.close);
      restored.restoreJson(backup);
      expect(restored.journal('').single.answer, 'Explanation');
      expect(restored.schedule(1).single.description, 'V0.04');
      final legacy = jsonDecode(backup) as Map<String, dynamic>;
      legacy['version'] = 3;
      for (final dynamic row in legacy['tables']['journal']) {
        row.remove('answer');
        row.remove('answered_at');
      }
      for (final dynamic row in legacy['tables']['schedule_blocks']) {
        row.remove('description');
      }
      restored.restoreJson(jsonEncode(legacy));
      expect(restored.journal('').single.answer, isNull);
      expect(restored.schedule(1).single.description, isNull);
      legacy['version'] = 2;
      legacy['tables'].remove('schedule_blocks');
      legacy['tables'].remove('academic_events');
      restored.restoreJson(jsonEncode(legacy));
      expect(restored.journal('').single.id, entry.id);
      expect(restored.schedule(1).single.id, block.id);
    },
  );
  test(
    'two-client offline answer and description edits converge without duplicate echoes; clear syncs',
    () async {
      final pc = memory(), phone = memory();
      addTearDown(pc.close);
      addTearDown(phone.close);
      final cloud = FakeCloud(),
          a = SyncStore(pc.database),
          b = SyncStore(phone.database);
      Future<void> sync(SyncStore store) => SyncEngine(
        store,
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      final entry = thought(), block = lesson(description: 'V0.04');
      pc.saveJournal(entry);
      pc.saveSchedule(block);
      await sync(a);
      await sync(b);
      cloud.offline = true;
      phone.answerJournal(
        entry.id,
        'Phone answer offline',
        question: entry.question,
      );
      phone.saveSchedule(lesson(id: block.id, description: 'Phone room'));
      await expectLater(sync(b), throwsA(isA<SocketException>()));
      expect(b.pending, greaterThan(0));
      cloud.offline = false;
      await sync(b);
      await sync(a);
      expect(pc.journal('').single.answer, 'Phone answer offline');
      expect(pc.schedule(1).single.description, 'Phone room');
      pc.answerJournal(
        entry.id,
        'Windows correction',
        question: entry.question,
      );
      await sync(a);
      await sync(b);
      expect(phone.journal('').single.answer, 'Windows correction');
      for (var i = 0; i < 3; i++) {
        await sync(a);
        await sync(b);
      }
      expect(a.conflicts + b.conflicts + cloud.conflicts.length, 0);
      expect(cloud.tables['journal']!.length, 1);
      expect(cloud.tables['schedule_blocks']!.length, 1);
      phone.answerJournal(entry.id, null, question: entry.question);
      phone.saveSchedule(lesson(id: block.id));
      await sync(b);
      await sync(a);
      expect(pc.journal('').single.answer, isNull);
      expect(pc.schedule(1).single.description, isNull);
    },
  );
}
