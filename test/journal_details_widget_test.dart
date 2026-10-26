import 'package:flutter/material.dart';
import 'support/navigation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/presentation/app.dart';
import 'package:trackstudy/presentation/journal.dart';
import 'package:trackstudy/presentation/schedule.dart';
import 'journal_details_test.dart' show memory, thought, lesson;

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('journal overview answer add/edit/cancel/clear on $platform', (
      tester,
    ) async {
      final repo = memory();
      addTearDown(repo.close);
      final blank = thought(question: ''), entry = thought();
      repo.saveJournal(blank);
      repo.saveJournal(entry);
      tester.view.physicalSize = Size(
        platform == TargetPlatform.android ? 360 : 1100,
        850,
      );
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
      await selectTab(tester, StudyTab.journal);
      await tester.pumpAndSettle();
      expect(find.byType(JournalSection), findsNWidgets(5));
      expect(find.byKey(ValueKey('answer-${blank.id}')), findsNothing);
      final action = find.byKey(ValueKey('answer-${entry.id}'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(JournalAnswerEditor),
          matching: find.text(entry.question),
        ),
        findsOneWidget,
      );
      if (platform == TargetPlatform.android) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.widgetWithText(TextField, 'Answer'),
        'Because Y optimizes embeddings.',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('Because Y optimizes embeddings.'), findsOneWidget);
      expect(find.text('Edit answer'), findsOneWidget);
      expect(repo.journal('').first.question, entry.question);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Answer'),
        'Cancelled',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.journal('').first.answer, 'Because Y optimizes embeddings.');
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Answer'),
        'Better explanation',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Better explanation'), findsOneWidget);
      await tester.ensureVisible(find.text('Edit').first);
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Learned'),
        'Revised learned',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.journal('').first.answer, 'Better explanation');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear answer'));
      await tester.pumpAndSettle();
      expect(repo.journal('').first.answer, isNull);
      expect(find.text('ANSWER'), findsNothing);
      expect(find.text('Answer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(platform));
    testWidgets(
      'schedule description editor and short/long cards on $platform',
      (tester) async {
        final repo = memory();
        addTearDown(repo.close);
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 360 : 1100,
          850,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repositoryProvider.overrideWithValue(repo)],
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const ScheduleEditor(weekday: 1),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Title'),
          'IAES (L)',
        );
        if (platform == TargetPlatform.android) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pumpAndSettle();
        }
        final input = find.widgetWithText(TextField, 'Description (optional)');
        await tester.ensureVisible(input);
        await tester.enterText(input, 'V0.04');
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        tester.view.resetViewInsets();
        expect(repo.schedule(1).single.description, 'V0.04');
        final original = repo.schedule(1).single;
        final empty = lesson();
        repo.saveSchedule(empty);
        for (final duration in [1, 10, 30, 45, 90]) {
          repo.saveSchedule(
            ScheduleBlock(
              id: const Uuid().v4(),
              title: 'Short or long',
              weekday: 1,
              startMinute: 600,
              endMinute: 600 + duration,
              description: 'Long classroom description ' * 40,
            ),
          );
        }
        for (final scale in [1.0, 1.5]) {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [repositoryProvider.overrideWithValue(repo)],
              child: MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    size: tester.view.physicalSize,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    body: ScheduleScreen(
                      active: true,
                      clock: () => DateTime(2026, 9, 28, 9, 15),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'text scale $scale');
          expect(find.byKey(ValueKey('description-${empty.id}')), findsNothing);
          if (scale == 1) {
            expect(
              find.byKey(ValueKey('description-${original.id}')),
              findsOneWidget,
            );
          }
        }
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
