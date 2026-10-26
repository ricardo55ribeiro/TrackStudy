import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/android_navigation.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/monthly.dart';
import 'package:trackstudy/presentation/settings.dart';
import 'support/android_drawer_acceptance.dart';
import 'support/navigation.dart';

void main() {
  late LocalStudyRepository repo;
  setUp(() {
    repo = LocalStudyRepository(StudyDatabase(sqlite3.openInMemory()));
  });
  tearDown(() => repo.close());

  Future<void> launch(WidgetTester tester, {double width = 360}) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: const TrackStudyApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android drawer selection, highlight, Back and outside dismissal',
    (tester) async {
      await launch(tester);
      await exerciseAndroidDrawer(tester);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android preserves saved order, visibility, startup and Settings selection',
    (tester) async {
      repo.setPreference(
        'tab.order',
        '["month","schedule","week","journal","review"]',
      );
      repo.setPreference('tab.week', 'false');
      repo.setPreference('tab.review', 'false');
      await launch(tester);
      final c = ProviderScope.containerOf(
        tester.element(find.byType(StudyShell)),
      ).read(studyProvider);
      final title = find.byKey(const ValueKey('android-tab-title'));
      expect(find.byType(MonthlyScreen), findsOneWidget);
      expect(tester.widget<Text>(title).data, 'Monthly View');
      await openNavigation(tester);
      expect(
        tester
            .widgetList<AndroidTabItem>(find.byType(AndroidTabItem))
            .map((e) => e.title),
        ['Monthly View', 'Daily Schedule', 'Research Journal'],
      );
      await tester.tap(find.byKey(const ValueKey('tab-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(title).data, 'Monthly View');
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Monthly View'));
      c.reorderTab(3, 0);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(title).data, 'Research Journal');
      await openNavigation(tester);
      expect(
        tester
            .widgetList<AndroidTabItem>(find.byType(AndroidTabItem))
            .map((e) => e.title),
        ['Research Journal', 'Daily Schedule'],
      );
      expect(
        tester
            .widget<AndroidTabItem>(find.byKey(const ValueKey('tab-journal')))
            .selected,
        isTrue,
      );
      c.setTabVisible(StudyTab.month, true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<AndroidTabItem>(find.byType(AndroidTabItem))
            .map((e) => e.title),
        ['Research Journal', 'Monthly View', 'Daily Schedule'],
      );
      await tester.pumpWidget(const SizedBox());
      await launch(tester);
      expect(tester.widget<Text>(title).data, 'Research Journal');
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final width in [320.0, 1100.0]) {
    testWidgets('Windows retains horizontal navigation at width $width', (
      tester,
    ) async {
      await launch(tester, width: width);
      expect(find.byType(AndroidNavigationBar), findsNothing);
      expect(find.byType(Drawer), findsNothing);
      expect(find.byTooltip('Open navigation menu'), findsNothing);
      final tabs = find.byWidgetPredicate(
        (w) => w is TextButton && w.key.toString().contains('tab-'),
      );
      expect(tabs, findsNWidgets(5));
      expect(find.byTooltip('Settings'), findsOneWidget);
      final rowY = tester.getTopLeft(tabs.first).dy;
      for (final element in tabs.evaluate()) {
        expect(tester.getTopLeft(find.byWidget(element.widget)).dy, rowY);
      }
      await selectTab(tester, StudyTab.month);
      await tester.pumpAndSettle();
      expect(find.byType(MonthlyScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Android long titles, keyboard and scroll at $brightness scale $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          const longTitle =
              'Research Journal with an exceptionally long future tab title that needs truncation';
          final scaffold = GlobalKey<ScaffoldState>();
          var settings = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: brightness,
                platform: TargetPlatform.android,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                key: scaffold,
                drawer: AndroidTabDrawer(
                  children: [
                    for (var i = 0; i < 20; i++)
                      AndroidTabItem(
                        key: ValueKey('long-$i'),
                        title: '$i $longTitle',
                        selected: i == 0,
                        onTap: () => scaffold.currentState!.closeDrawer(),
                      ),
                  ],
                ),
                body: SafeArea(
                  child: AndroidNavigationBar(
                    title: longTitle,
                    onOpenDrawer: () => scaffold.currentState!.openDrawer(),
                    onSettings: () => settings = true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final title = tester.widget<Text>(
            find.byKey(const ValueKey('android-tab-title')),
          );
          expect(title.maxLines, 1);
          expect(title.overflow, TextOverflow.ellipsis);
          final gear = find.byTooltip('Settings');
          final menu = find.byTooltip('Open navigation menu');
          expect(tester.getRect(gear).right, lessThanOrEqualTo(320));
          expect(tester.getSize(gear).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
          await tester.tap(gear);
          expect(settings, isTrue);
          await openNavigation(tester);
          expect(tester.getSize(find.byType(Drawer)).width, closeTo(272, 0.1));
          final itemTitle = tester.widget<Text>(find.text('0 $longTitle'));
          expect(itemTitle.maxLines, 2);
          expect(itemTitle.overflow, TextOverflow.ellipsis);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('long-19')),
            250,
            scrollable: find.descendant(
              of: find.byType(Drawer),
              matching: find.byType(Scrollable),
            ),
            maxScrolls: 40,
          );
          await tester.tap(find.byKey(const ValueKey('long-19')));
          await tester.pumpAndSettle();
          expect(scaffold.currentState!.isDrawerOpen, isFalse);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}
