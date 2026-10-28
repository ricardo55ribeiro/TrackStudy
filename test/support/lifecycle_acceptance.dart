import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'sync_fakes.dart';

Future<void> exerciseWeeklyLifecycle() async {
  final folder = await Directory.systemTemp.createTemp('native-bar-lifecycle-');
  final path = '${folder.path}/fixture.sqlite';
  var local = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
  final peer = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  final cloud = FakeCloud();
  final w1 = Week.containing(DateTime.now()).shift(-3);
  final w2 = w1.shift(1), w3 = w1.shift(2), w4 = w1.shift(3);
  Future<void> sync(LocalStudyRepository repo) => SyncEngine(
    SyncStore(repo.database),
    cloud,
    backup: () async {},
  ).synchronize(account, project, () => true);
  try {
    final first = local.loadWeek(w1, current: w1).first;
    local.commit(first.goalId, 100, w1);
    await sync(local);
    await sync(peer);
    final second = peer.loadWeek(w2, current: w2).first;
    peer.commit(second.goalId, 300, w2);
    peer.loadWeek(w3, current: w3);
    local.setCategoryStatus(
      first.categoryId,
      current: w2,
      active: false,
      archived: true,
    );
    await sync(local);
    local.close();
    local = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
    local.setCategoryStatus(
      first.categoryId,
      current: w4,
      active: true,
      archived: false,
    );
    await sync(local);
    await sync(peer);
    await sync(local);
    for (final repo in [local, peer]) {
      expect(repo.loadWeek(w1, current: w4).first.total, 100);
      for (final week in [w2, w3]) {
        expect(
          repo
              .loadWeek(week, current: w4)
              .any((p) => p.categoryId == first.categoryId),
          isFalse,
        );
      }
      expect(repo.loadWeek(w4, current: w4).first.categoryId, first.categoryId);
      expect(repo.entries(second.goalId).single.amount, 300);
    }
    final backup = local.exportJson();
    local.restoreJson(backup);
    expect(
      local
          .loadWeek(w2, current: w4)
          .any((p) => p.categoryId == first.categoryId),
      isFalse,
    );
    expect(local.entries(second.goalId).single.amount, 300);
  } finally {
    local.close();
    peer.close();
    await folder.delete(recursive: true);
  }
}
