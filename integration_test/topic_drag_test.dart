import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/data/database.dart';
import 'package:trackstudy/data/local_repository.dart';
import 'package:trackstudy/presentation/app.dart';
import '../test/support/topic_reordering.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native topic and task dragging stay independent', (
    tester,
  ) async {
    final repository = LocalStudyRepository(
      StudyDatabase(sqlite3.openInMemory()),
    );
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const TrackStudyApp(),
        ),
      );
      await tester.pumpAndSettle();
      await exerciseTopicReordering(tester, touch: Platform.isAndroid);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    } finally {
      repository.close();
    }
  });
}
