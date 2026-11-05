import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'schedule_colour_test.dart' show colouredBlock;
import 'support/sync_fakes.dart';

AcademicEvent colouredEvent(ScheduleColour colour, {String? id}) =>
    AcademicEvent(
      id: id ?? const Uuid().v4(),
      title: 'Exam preparation',
      date: '2026-11-05',
      type: AcademicType.exam,
      note: 'Room 4',
      colour: colour,
    );

void main() {
  LocalStudyRepository memory() =>
      LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));

  test(
    'schema 9 migration preserves four block colours, event content, triggers and causal metadata',
    () {
      final repo = memory();
      addTearDown(repo.close);
      for (final colour in ScheduleColour.values.take(4)) {
        repo.saveSchedule(colouredBlock(colour));
        repo.saveAcademicEvent(colouredEvent(ScheduleColour.blue));
      }
      repo.deleteSchedule(repo.schedule(1).first.id);
      repo.deleteAcademicEvent(
        repo.academicEvents(DateTime(2026, 11)).first.id,
      );
      final db = repo.database.handle;
      final objects = db.select(
        "SELECT name,sql FROM sqlite_master WHERE tbl_name='schedule_blocks' AND type IN ('trigger','index') AND sql IS NOT NULL ORDER BY name",
      );
      final create =
          db
                  .select(
                    "SELECT sql FROM sqlite_master WHERE name='schedule_blocks'",
                  )
                  .single['sql']
              as String;
      db.execute(
        create
            .replaceFirst('"schedule_blocks"', 'schedule_blocks_old')
            .replaceFirst("'red','black'", "'red'"),
      );
      db.execute(
        'INSERT INTO schedule_blocks_old SELECT * FROM schedule_blocks; DROP TABLE schedule_blocks; ALTER TABLE schedule_blocks_old RENAME TO schedule_blocks',
      );
      for (final object in objects) {
        db.execute(object['sql'] as String);
      }
      db.execute(
        'ALTER TABLE academic_events DROP COLUMN colour; PRAGMA user_version=9',
      );
      SyncStore(repo.database).bind(account, project);
      db.execute(
        "UPDATE sync_records SET dirty=0 WHERE table_name='academic_events'",
      );
      final copy = SyncStore(
        repo.database,
      ).pendingRows('schedule_blocks').first;
      db.execute(
        'INSERT INTO sync_conflicts(table_name,record_id,version,writer,payload,saved_at) VALUES (?,?,?,?,?,?)',
        [
          'schedule_blocks',
          copy['id'],
          copy['sync_version'],
          copy['sync_writer'],
          jsonEncode(copy),
          '2026-11-05T10:00:00Z',
        ],
      );
      expect(
        () => db.execute("UPDATE schedule_blocks SET colour='black'"),
        throwsA(isA<SqliteException>()),
      );
      List<Map<String, Object?>> rows(String table) => db
          .select('SELECT * FROM $table')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final before = {
        for (final table in [
          'schedule_blocks',
          'academic_events',
          'sync_records',
          'sync_meta',
          'sync_conflicts',
        ])
          table: rows(table),
      };
      StudyDatabase(db);
      expect(db.select('PRAGMA user_version').single.values.single, 10);
      for (final table in before.keys) {
        expect(
          rows(table),
          table == 'academic_events'
              ? before[table]!.map((r) => {...r, 'colour': 'blue'}).toList()
              : before[table],
        );
      }
      expect(
        db.select(
          "SELECT name,sql FROM sqlite_master WHERE tbl_name='schedule_blocks' AND type IN ('trigger','index') AND sql IS NOT NULL ORDER BY name",
        ),
        objects,
      );
      final store = SyncStore(repo.database);
      final clock = int.parse(store.meta('clock'));
      final block = repo.schedule(1).first;
      final oldHistory =
          store
                  .pendingRows('schedule_blocks')
                  .firstWhere((r) => r['id'] == block.id)['sync_history']
              as Map;
      repo.saveSchedule(colouredBlock(ScheduleColour.black, id: block.id));
      repo.saveAcademicEvent(colouredEvent(ScheduleColour.black));
      expect(int.parse(store.meta('clock')), greaterThan(clock));
      final newHistory =
          store
                  .pendingRows('schedule_blocks')
                  .firstWhere((r) => r['id'] == block.id)['sync_history']
              as Map;
      for (final writer in oldHistory.keys) {
        expect(newHistory[writer], greaterThanOrEqualTo(oldHistory[writer]));
      }
      for (final table in ['schedule_blocks', 'academic_events']) {
        for (final invalid in ['purple', null]) {
          expect(
            () => db.execute('UPDATE $table SET colour=?', [invalid]),
            throwsA(isA<SqliteException>()),
          );
        }
      }
      expect(
        () => db.execute('UPDATE schedule_blocks SET end_minute=start_minute'),
        throwsA(isA<SqliteException>()),
      );
    },
  );

  test(
    'all five event colours persist through file reopen and validate strictly',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'monthly-colours-',
      );
      final path = '${directory.path}/study.sqlite';
      var repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      try {
        for (final colour in ScheduleColour.values) {
          repo.saveAcademicEvent(colouredEvent(colour));
        }
        repo.close();
        repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        expect(
          repo.academicEvents(DateTime(2026, 11)).map((e) => e.colour).toSet(),
          ScheduleColour.values.toSet(),
        );
        final row = colouredEvent(ScheduleColour.red).toMap()..remove('colour');
        expect(AcademicEvent.fromMap(row).colour, ScheduleColour.blue);
        for (final invalid in [null, 'purple', 1, 'Black']) {
          expect(
            () => AcademicEvent.fromMap({...row, 'colour': invalid}),
            throwsFormatException,
          );
        }
      } finally {
        repo.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'backup 8 round-trips both palettes and imports formats 2-7 without partial invalid restores',
    () {
      final source = memory(), target = memory();
      addTearDown(source.close);
      addTearDown(target.close);
      for (final colour in ScheduleColour.values) {
        source.saveSchedule(colouredBlock(colour));
        source.saveAcademicEvent(colouredEvent(colour));
      }
      final backup = source.exportJson();
      expect(jsonDecode(backup)['version'], 8);
      target.restoreJson(backup);
      expect(
        target.schedule(1).map((b) => b.colour).toSet(),
        ScheduleColour.values.toSet(),
      );
      expect(
        target.academicEvents(DateTime(2026, 11)).map((e) => e.colour).toSet(),
        ScheduleColour.values.toSet(),
      );
      for (final version in [2, 3, 4, 5, 6, 7]) {
        final legacy = jsonDecode(backup);
        legacy['version'] = version;
        for (final row in legacy['tables']['academic_events']) {
          row.remove('colour');
        }
        final blocks = legacy['tables']['schedule_blocks'] as List;
        blocks.removeWhere((r) => r['colour'] == 'black');
        if (version < 7) {
          for (final row in blocks) {
            row.remove('colour');
          }
        }
        target.restoreJson(jsonEncode(legacy));
        if (version == 2) {
          expect(
            target
                .academicEvents(DateTime(2026, 11))
                .map((e) => e.colour)
                .toSet(),
            ScheduleColour.values.toSet(),
          );
        } else {
          expect(
            target
                .academicEvents(DateTime(2026, 11))
                .every((e) => e.colour == ScheduleColour.blue),
            isTrue,
          );
        }
        if (version == 7) {
          expect(
            target.schedule(1).map((b) => b.colour).toSet(),
            ScheduleColour.values.take(4).toSet(),
          );
        }
      }
      for (final table in ['schedule_blocks', 'academic_events']) {
        for (final invalid in ['purple', null, 7]) {
          final bad = jsonDecode(backup);
          bad['tables'][table][0]['colour'] = invalid;
          final before = jsonDecode(target.exportJson())['tables'];
          expect(
            () => target.restoreJson(jsonEncode(bad)),
            throwsFormatException,
          );
          expect(jsonDecode(target.exportJson())['tables'], before);
        }
        final missing = jsonDecode(backup);
        missing['tables'][table][0].remove('colour');
        expect(
          () => target.restoreJson(jsonEncode(missing)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'event colours and Black blocks converge with offline and concurrent edits',
    () async {
      final pc = memory(), phone = memory();
      addTearDown(pc.close);
      addTearDown(phone.close);
      final cloud = FakeCloud();
      Future<void> sync(LocalStudyRepository repo) => SyncEngine(
        SyncStore(repo.database),
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      final event = colouredEvent(ScheduleColour.black),
          block = colouredBlock(ScheduleColour.black);
      pc.saveAcademicEvent(event);
      pc.saveSchedule(block);
      await sync(pc);
      await sync(phone);
      expect(
        phone.academicEvents(DateTime(2026, 11)).single.colour,
        ScheduleColour.black,
      );
      expect(phone.schedule(1).single.colour, ScheduleColour.black);
      cloud.offline = true;
      phone.saveAcademicEvent(
        colouredEvent(ScheduleColour.orange, id: event.id),
      );
      await expectLater(sync(phone), throwsA(isA<SocketException>()));
      cloud.offline = false;
      await sync(phone);
      await sync(pc);
      expect(
        pc.academicEvents(DateTime(2026, 11)).single.colour,
        ScheduleColour.orange,
      );
      pc.saveAcademicEvent(colouredEvent(ScheduleColour.green, id: event.id));
      phone.saveAcademicEvent(colouredEvent(ScheduleColour.red, id: event.id));
      await sync(pc);
      await sync(phone);
      await sync(pc);
      await sync(phone);
      expect(
        pc.academicEvents(DateTime(2026, 11)).single.toMap(),
        phone.academicEvents(DateTime(2026, 11)).single.toMap(),
      );
      expect(
        SyncStore(pc.database).conflicts + SyncStore(phone.database).conflicts,
        greaterThan(0),
      );
      expect(
        SyncStore(pc.database).pending + SyncStore(phone.database).pending,
        0,
      );
      final row = {
        ...SyncStore(pc.database).pendingRows('academic_events').firstOrNull ??
            event.toMap(),
      };
      row.remove('colour');
      expect(
        () => SyncStore(pc.database).apply({
          'academic_events': [row],
        }, account),
        throwsFormatException,
      );
      expect(
        pc.academicEvents(DateTime(2026, 11)).single.toMap(),
        phone.academicEvents(DateTime(2026, 11)).single.toMap(),
      );
    },
  );
}
