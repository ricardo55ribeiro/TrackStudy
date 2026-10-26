import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'support/sync_fakes.dart';
import 'support/tab_reordering.dart';

void main() {
  test(
    'tab IDs normalize invalid, missing, repeated and future preferences',
    () {
      for (final value in ['', 'broken JSON', '{}', 'null', '42']) {
        expect(StudyTabOrder.decode(value), StudyTab.values);
      }
      expect(
        StudyTabOrder.decode('["month","week","month","unknown",3,"journal"]'),
        [
          StudyTab.month,
          StudyTab.week,
          StudyTab.journal,
          StudyTab.review,
          StudyTab.schedule,
        ],
      );
      expect(StudyTabOrder.decode('["schedule"]'), [
        StudyTab.week,
        StudyTab.schedule,
        StudyTab.journal,
        StudyTab.review,
        StudyTab.month,
      ]);
    },
  );
  test(
    'file-backed tab order survives restart, hiding and backup restore',
    () async {
      final dir = await Directory.systemTemp.createTemp('trackstudy-tabs-');
      final path = '${dir.path}/tabs.sqlite';
      var repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      var c = StudyController(repo, watchClock: false);
      try {
        c.reorderTab(4, 0);
        c.setTabVisible(StudyTab.month, false);
        c.setTabVisible(StudyTab.week, false);
        final order = c.tabOrder;
        final backup = repo.exportJson();
        c.dispose();
        repo.close();
        repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        c = StudyController(repo, watchClock: false);
        expect(c.tabOrder, order);
        expect(c.tabVisible(StudyTab.month), isFalse);
        expect(c.tabVisible(StudyTab.week), isFalse);
        c.setTabVisible(StudyTab.month, true);
        expect(c.tabOrder, order);
        c.reorderTab(0, 4);
        expect(c.tabOrder, StudyTab.values);
        repo.restoreJson(backup);
        expect(c.tabOrder, order);
        expect(c.tabVisible(StudyTab.month), isFalse);
      } finally {
        c.dispose();
        repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('tab order stays local and never enters the sync queue', () async {
    final pc = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
    final phone = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
    final a = StudyController(pc, watchClock: false),
        b = StudyController(phone, watchClock: false);
    addTearDown(() {
      a.dispose();
      b.dispose();
      pc.close();
      phone.close();
    });
    final cloud = FakeCloud();
    Future<void> sync(LocalStudyRepository r) => SyncEngine(
      SyncStore(r.database),
      cloud,
      backup: () async {},
    ).synchronize(account, project, () => true);
    await sync(pc);
    await sync(phone);
    a.reorderTab(3, 0);
    b.reorderTab(4, 0);
    a.setTabVisible(StudyTab.journal, false);
    expect(
      SyncStore(pc.database).pending + SyncStore(phone.database).pending,
      0,
    );
    await sync(pc);
    await sync(phone);
    expect(a.tabOrder.first, StudyTab.schedule);
    expect(b.tabOrder.first, StudyTab.month);
    expect(b.tabVisible(StudyTab.journal), isTrue);
    expect(cloud.tables.containsKey('preferences'), isFalse);
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'drag handles reorder navigation and preserve switches on $platform',
      (tester) async {
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 1100,
          850,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = LocalStudyRepository(
          StudyDatabase(sqlite3.openInMemory()),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repositoryProvider.overrideWithValue(repo)],
            child: const TrackStudyApp(),
          ),
        );
        await tester.pumpAndSettle();
        await exerciseTabReordering(
          tester,
          touch: platform == TargetPlatform.android,
        );
        await tester.pumpWidget(const SizedBox());
        repo.close();
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
