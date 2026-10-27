import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/common.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'package:trackstudy/presentation/settings.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'support/sync_fakes.dart';
import 'support/settings_acceptance.dart';

void main() {
  test('legacy order and visibility upgrade without resetting preferences', () {
    final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
    addTearDown(repo.close);
    repo.setPreference('tab.order', '["month","schedule","journal","review"]');
    repo.setPreference('tab.journal', 'false');
    final c = StudyController(repo, watchClock: false);
    addTearDown(c.dispose);
    expect(c.tabOrder, [
      StudyTab.week,
      StudyTab.todo,
      StudyTab.month,
      StudyTab.schedule,
      StudyTab.journal,
      StudyTab.review,
    ]);
    expect(c.tabVisible(StudyTab.journal), isFalse);
    c.reorderTab(0, 3);
    expect(c.tabOrder, [
      StudyTab.todo,
      StudyTab.month,
      StudyTab.schedule,
      StudyTab.week,
      StudyTab.journal,
      StudyTab.review,
    ]);
    expect(c.setTabVisible(StudyTab.week, false), isTrue);
    expect(c.enabledTabs.first, StudyTab.todo);
    c.setTabVisible(StudyTab.week, true);
    expect(c.tabOrder[3], StudyTab.week);
  });

  test(
    'last tab cannot be disabled and malformed all-hidden settings recover',
    () {
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
      final c = StudyController(repo, watchClock: false);
      addTearDown(c.dispose);
      c.reorderTab(5, 0);
      for (final tab in StudyTab.values.where((tab) => tab != StudyTab.month)) {
        expect(c.setTabVisible(tab, false), isTrue);
      }
      expect(c.setTabVisible(StudyTab.month, false), isFalse);
      expect(c.enabledTabs, [StudyTab.month]);
      repo.setPreference('tab.month', 'false');
      expect(c.enabledTabs, [StudyTab.month]);
      expect(c.setTabVisible(StudyTab.month, false), isFalse);
      expect(c.setTabVisible(StudyTab.week, true), isTrue);
      expect(c.enabledTabs, [StudyTab.week]);
    },
  );

  test(
    'category order and archives survive restart and sync with history intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'trackstudy-category-order-',
      );
      final path = '${directory.path}/fixture.sqlite';
      var repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
      var c = StudyController(repo, watchClock: false);
      final phone = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      final cloud = FakeCloud();
      Future<void> sync(LocalStudyRepository r) => SyncEngine(
        SyncStore(r.database),
        cloud,
        backup: () async {},
      ).synchronize(account, project, () => true);
      try {
        final ids = repo.categories().map((category) => category.id).toList();
        final gym = c.progress.firstWhere((p) => p.config.name == 'Gym');
        final past = c.current.shift(-1);
        final oldGym = repo
            .loadWeek(past, current: past)
            .firstWhere((p) => p.categoryId == gym.categoryId);
        repo.commit(oldGym.goalId, 200, past);
        repo.commit(gym.goalId, 100, c.current);
        repo.setCategoryStatus(ids[2], active: false, archived: true);
        c.reorderCategory(3, 0);
        final order = repo.categories().map((category) => category.id).toList();
        expect(order, [ids[4], ids[0], ids[2], ids[1], ids[3], ids[5], ids[6]]);
        expect(c.progress.first.categoryId, gym.categoryId);
        final tables = jsonDecode(repo.exportJson())['tables'] as Map;
        for (var i = 0; i < 3; i++) {
          repo.setCategoryStatus(gym.categoryId, active: false, archived: true);
          c.refresh();
          expect(
            c.progress.any((p) => p.categoryId == gym.categoryId),
            isFalse,
          );
          repo.setCategoryStatus(gym.categoryId, active: true, archived: false);
          c.refresh();
          expect(c.progress.first.goalId, gym.goalId);
          expect(c.progress.first.total, 100);
        }
        final after = jsonDecode(repo.exportJson())['tables'] as Map;
        expect(after['weekly_goals'], tables['weekly_goals']);
        expect(after['entries'], tables['entries']);
        c.dispose();
        repo.close();
        repo = LocalStudyRepository(StudyDatabase(sqlite3.open(path)));
        c = StudyController(repo, watchClock: false);
        expect(repo.categories().map((category) => category.id), order);
        expect(c.progress.first.goalId, gym.goalId);
        expect(c.progress.first.total, 100);
        await sync(repo);
        await sync(phone);
        expect(phone.categories().map((category) => category.id), order);
        expect(
          phone.categories().where((category) => category.archived).single.id,
          ids[2],
        );
        expect(phone.loadWeek(c.current, current: c.current).first.total, 100);
        expect(
          phone
              .loadWeek(past, current: c.current)
              .firstWhere((p) => p.categoryId == gym.categoryId)
              .total,
          200,
        );
        expect(cloud.tables['categories']!.length, ids.length);
        expect(SyncStore(repo.database).pending, 0);
        final dataBefore = jsonDecode(repo.exportJson())['tables'] as Map;
        final syncBefore = repo.db
            .select('SELECT * FROM sync_records')
            .map((row) => Map<String, Object?>.from(row))
            .toList();
        c.setTabVisible(StudyTab.week, false);
        c.reorderTab(4, 0);
        final dataAfter = jsonDecode(repo.exportJson())['tables'] as Map;
        for (final table in dataBefore.keys.where(
          (key) => key != 'preferences',
        )) {
          expect(
            dataAfter[table],
            dataBefore[table],
            reason: '$table is unchanged',
          );
        }
        expect(repo.db.select('SELECT * FROM sync_records'), syncBefore);
        await sync(repo);
        await sync(phone);
        expect(phone.preference('tab.week', 'true'), 'true');
        expect(phone.preference('tab.order', ''), '');
      } finally {
        c.dispose();
        repo.close();
        phone.close();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    Future<LocalStudyRepository> launch(
      WidgetTester tester, {
      bool monthFirst = false,
    }) async {
      tester.view.physicalSize = Size(
        platform == TargetPlatform.android ? 360 : 1100,
        850,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
      addTearDown(repo.close);
      if (monthFirst) {
        repo.setPreference(
          'tab.order',
          '["month","week","journal","review","schedule"]',
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: const TrackStudyApp(),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('category controls, drag and collapsed archives on $platform', (
      tester,
    ) async {
      await launch(tester);
      await exerciseCategorySettings(
        tester,
        touch: platform == TargetPlatform.android,
      );
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets('Settings sections retain their required order on $platform', (
      tester,
    ) async {
      await launch(tester);
      tester.view.physicalSize = Size(
        platform == TargetPlatform.android ? 360 : 1100,
        3000,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<SectionTitle>(find.byType(SectionTitle))
            .map((title) => title.text),
        [
          'Appearance',
          'Tabs on this device',
          'Categories',
          if (platform == TargetPlatform.windows) 'Windows',
          'Week',
          'Data',
          'Sync',
        ],
      );
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets(
      'startup, category dependency and safe last-tab navigation on $platform',
      (tester) async {
        final repo = await launch(tester, monthFirst: true);
        expect(find.byType(MonthlyScreen), findsOneWidget);
        final c = ProviderScope.containerOf(
          tester.element(find.byType(StudyShell)),
        ).read(studyProvider);
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        final progressSwitch = find.widgetWithText(
          SwitchListTile,
          'Progress Bars',
        );
        await tester.tap(progressSwitch);
        await tester.pumpAndSettle();
        expect(find.text('Categories'), findsNothing);
        expect(find.byType(ArchivedCategories), findsNothing);
        expect(repo.categories().length, 7);
        await tester.tap(progressSwitch);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Categories'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Categories'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(MonthlyScreen), findsOneWidget);
        c.setTabVisible(StudyTab.month, false);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('input-Research')), findsOneWidget);
        for (final tab in [
          StudyTab.todo,
          StudyTab.journal,
          StudyTab.review,
          StudyTab.schedule,
        ]) {
          c.setTabVisible(tab, false);
        }
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(progressSwitch);
        await tester.pumpAndSettle();
        expect(find.text('Keep at least one tab enabled.'), findsOneWidget);
        expect(c.enabledTabs, [StudyTab.week]);
        expect(c.tabOrder.first, StudyTab.month);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  for (final width in [320.0, 360.0, 1100.0]) {
    testWidgets(
      'month arrows remain grouped and navigate at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = LocalStudyRepository(
          StudyDatabase(sqlite3.openInMemory()),
        );
        addTearDown(repo.close);
        repo.setPreference('tab.order', '["month","week"]');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repositoryProvider.overrideWithValue(repo)],
            child: const TrackStudyApp(),
          ),
        );
        await tester.pumpAndSettle();
        final previous = find.byTooltip('Previous month');
        final next = find.byTooltip('Next month');
        final label = find.byKey(const ValueKey('month-label'));
        final today = find.byKey(const ValueKey('month-today'));
        final now = LocalDate.month(DateTime.now(), 0);
        expect(tester.widget<Text>(label).data, DateFormat.yMMMM().format(now));
        expect(
          tester.getRect(previous).right,
          lessThanOrEqualTo(tester.getRect(label).left),
        );
        expect(
          tester.getRect(label).right,
          lessThanOrEqualTo(tester.getRect(next).left),
        );
        expect(
          tester.getRect(next).left - tester.getRect(label).right,
          lessThan(12),
        );
        expect(
          tester.getRect(next).right,
          lessThanOrEqualTo(tester.getRect(today).left),
        );
        await tester.tap(previous);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(label).data,
          DateFormat.yMMMM().format(LocalDate.month(now, -1)),
        );
        await tester.tap(next);
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(label).data,
          DateFormat.yMMMM().format(LocalDate.month(now, 1)),
        );
        await tester.tap(today);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(label).data, DateFormat.yMMMM().format(now));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(
        width < 600 ? TargetPlatform.android : TargetPlatform.windows,
      ),
    );
  }
}
