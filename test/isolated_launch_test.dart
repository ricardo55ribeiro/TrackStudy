import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/main.dart' as app;
import 'package:trackstudy/application/study_controller.dart';
import 'package:trackstudy/application/sync_controller.dart';
import 'package:trackstudy/presentation/app.dart';

void main() {
  testWidgets(
    'isolated launch never initializes cloud auth or reads saved sessions',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'trackstudy-isolated-',
      );
      var credentialCalls = 0;
      const secureStorage = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      const background = MethodChannel('dev.trackstudy/background');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secureStorage,
        (_) async {
          credentialCalls++;
          return null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        background,
        (_) async => null,
      );
      await tester.runAsync(() => app.main(['--data-dir=${directory.path}']));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StudyShell)),
      );
      final repository = container.read(repositoryProvider);
      expect(
        repository.location,
        '${directory.path}${Platform.pathSeparator}trackstudy.sqlite',
      );
      expect(container.read(syncProvider).configured, isFalse);
      expect(container.read(syncProvider).canSignIn, isFalse);
      expect(credentialCalls, 0);
      await tester.pumpWidget(const SizedBox());
      repository.close();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secureStorage,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        background,
        null,
      );
      directory.deleteSync(recursive: true);
    },
  );
}
