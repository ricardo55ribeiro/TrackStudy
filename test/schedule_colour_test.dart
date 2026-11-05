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
import 'support/sync_fakes.dart';

ScheduleBlock colouredBlock(ScheduleColour colour, {String? id}) =>
    ScheduleBlock(
      id: id ?? const Uuid().v4(),
      title: 'Research',
      description: 'Room 4',
      weekday: 1,
      startMinute: 540,
      endMinute: 600,
      colour: colour,
    );

void main() {
  LocalStudyRepository memory() =>
      LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));

  test(
    'symbolic colours validate and absent legacy values default to Blue',
    () {
      final row = colouredBlock(ScheduleColour.orange).toMap();
      expect(ScheduleBlock.fromMap(row).colour, ScheduleColour.orange);
      row.remove('colour');
      expect(ScheduleBlock.fromMap(row).colour, ScheduleColour.blue);
      for (final invalid in [null, '', 'purple', 'Blue', 1]) {
        expect(
          () => ScheduleBlock.fromMap({...row, 'colour': invalid}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'schema 8 upgrade defaults to Blue and preserves all data and sync metadata',
    () {
      final repo = memory();
      addTearDown(repo.close);
      for (final colour in ScheduleColour.values) {
        repo.saveSchedule(colouredBlock(colour));
      }
      final raw = repo.database.handle;
      repo.deleteSchedule(repo.schedule(1).first.id);
      raw.execute(
        'ALTER TABLE schedule_blocks DROP COLUMN colour; ALTER TABLE academic_events DROP COLUMN colour; PRAGMA user_version=8',
      );
      List<Map<String, Object?>> rows(String table) => raw
          .select('SELECT * FROM $table')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final before = rows('schedule_blocks');
      final metadata = {
        for (final table in ['sync_records', 'sync_meta', 'sync_conflicts'])
          table: rows(table),
      };
      StudyDatabase(raw);
      expect(
        raw.select('PRAGMA user_version').single.values.single,
        StudyDatabase.version,
      );
      expect(
        rows('schedule_blocks'),
        before.map((r) => {...r, 'colour': 'blue'}).toList(),
      );
      for (final table in metadata.keys) {
        expect(rows(table), metadata[table]);
      }
      expect(
        () => raw.execute("UPDATE schedule_blocks SET colour='purple'"),
        throwsA(isA<SqliteException>()),
      );
    },
  );

  test('all colours persist through a database close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'schedule-colours-',
    );
    final path = '${directory.path}/study.sqlite';
    var repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
    try {
      for (final colour in ScheduleColour.values) {
        repo.saveSchedule(colouredBlock(colour));
      }
      repo.close();
      repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      expect(
        repo.schedule(1).map((b) => b.colour).toSet(),
        ScheduleColour.values.toSet(),
      );
      expect(repo.schedule(1).every((b) => b.description == 'Room 4'), isTrue);
    } finally {
      repo.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'backup 8 preserves colours, formats 3-6 default missing colours and invalid values are atomic',
    () {
      final source = memory(), target = memory();
      addTearDown(source.close);
      addTearDown(target.close);
      for (final colour in ScheduleColour.values) {
        source.saveSchedule(colouredBlock(colour));
      }
      final backup = source.exportJson();
      expect(jsonDecode(backup)['version'], 8);
      target.restoreJson(backup);
      expect(
        target.schedule(1).map((b) => b.colour).toSet(),
        ScheduleColour.values.toSet(),
      );
      for (final version in [3, 4, 5, 6]) {
        final legacy = jsonDecode(backup) as Map<String, dynamic>;
        legacy['version'] = version;
        for (final row in legacy['tables']['schedule_blocks']) {
          row.remove('colour');
        }
        target.restoreJson(jsonEncode(legacy));
        expect(target.schedule(1), hasLength(5));
        expect(
          target.schedule(1).every((b) => b.colour == ScheduleColour.blue),
          isTrue,
        );
      }
      for (final value in [null, 'purple', 12]) {
        final bad = jsonDecode(backup);
        bad['tables']['schedule_blocks'][0]['colour'] = value;
        final before = target.exportJson();
        expect(
          () => target.restoreJson(jsonEncode(bad)),
          throwsFormatException,
        );
        expect(
          jsonDecode(target.exportJson())['tables'],
          jsonDecode(before)['tables'],
        );
      }
      final missing = jsonDecode(backup);
      missing['tables']['schedule_blocks'][0].remove('colour');
      expect(
        () => target.restoreJson(jsonEncode(missing)),
        throwsFormatException,
      );
    },
  );

  test(
    'two devices synchronize independent colours, offline edits and concurrent conflicts',
    () async {
      final windows = memory(), android = memory();
      addTearDown(windows.close);
      addTearDown(android.close);
      final cloud = FakeCloud();
      Future<void> sync(LocalStudyRepository repo) => SyncEngine(
        SyncStore(repo.database),
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      final blocks = [for (final c in ScheduleColour.values) colouredBlock(c)];
      for (final block in blocks) {
        windows.saveSchedule(block);
      }
      await sync(windows);
      await sync(android);
      expect(
        android.schedule(1).map((b) => b.toMap()),
        windows.schedule(1).map((b) => b.toMap()),
      );
      cloud.offline = true;
      android.saveSchedule(colouredBlock(ScheduleColour.red, id: blocks[0].id));
      windows.saveSchedule(
        colouredBlock(ScheduleColour.green, id: blocks[1].id),
      );
      await expectLater(sync(android), throwsA(isA<SocketException>()));
      expect(SyncStore(android.database).pending, greaterThan(0));
      cloud.offline = false;
      await sync(windows);
      await sync(android);
      await sync(windows);
      expect(
        windows.schedule(1).firstWhere((b) => b.id == blocks[0].id).colour,
        ScheduleColour.red,
      );
      expect(
        android.schedule(1).firstWhere((b) => b.id == blocks[1].id).colour,
        ScheduleColour.green,
      );
      windows.saveSchedule(
        colouredBlock(ScheduleColour.orange, id: blocks[0].id),
      );
      android.saveSchedule(
        colouredBlock(ScheduleColour.green, id: blocks[0].id),
      );
      await sync(windows);
      await sync(android);
      await sync(windows);
      await sync(android);
      expect(
        android.schedule(1).map((b) => b.toMap()),
        windows.schedule(1).map((b) => b.toMap()),
      );
      expect(SyncStore(android.database).pending, 0);
      expect(SyncStore(windows.database).pending, 0);
      expect(
        SyncStore(android.database).conflicts +
            SyncStore(windows.database).conflicts,
        greaterThan(0),
      );
    },
  );

  test(
    'missing cloud colour rolls back the whole pull and retains pending edits',
    () {
      final repo = memory();
      addTearDown(repo.close);
      final block = colouredBlock(ScheduleColour.red);
      repo.saveSchedule(block);
      final store = SyncStore(repo.database);
      final row = {
        ...store.pendingRows('schedule_blocks').single,
        'user_id': account,
      };
      row.remove('colour');
      final before = store.pendingRows('schedule_blocks');
      expect(
        () => store.apply({
          'schedule_blocks': [row],
        }, account),
        throwsFormatException,
      );
      expect(store.pendingRows('schedule_blocks'), before);
      expect(repo.schedule(1).single.colour, ScheduleColour.red);
    },
  );
}
