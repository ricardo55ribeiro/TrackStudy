import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:trackstudy/sync/supabase_gateway.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'journal_details_test.dart' show memory, thought, lesson;
import 'support/sync_fakes.dart' show account, project;

void main() {
  for (final missingTable in [
    'journal',
    'schedule_blocks',
    'todo_topics',
    'todo_tasks',
  ]) {
    test(
      'missing 005 $missingTable columns prevents uploads and retains local edits',
      () async {
        final repo = memory();
        addTearDown(repo.close);
        final entry = thought();
        final topic = repo.addTodoTopic('Safe offline');
        repo.addTodoTask(topic, 'Keep this task');
        repo.saveJournal(entry);
        repo.answerJournal(
          entry.id,
          'Keep this answer',
          question: entry.question,
        );
        repo.saveSchedule(lesson(description: 'Keep this room'));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requests = <String>[];
        server.listen((request) async {
          requests.add(request.method);
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path.endsWith('/$missingTable')) {
            final select = request.uri.queryParameters['select']!;
            expect(
              select,
              contains(
                missingTable == 'journal'
                    ? 'answered_at'
                    : missingTable == 'schedule_blocks'
                    ? 'description'
                    : 'sync_history',
              ),
            );
            request.response.statusCode = 400;
            request.response.write(
              jsonEncode({'code': '42703', 'message': 'column does not exist'}),
            );
          } else {
            request.response.write('[]');
          }
          await request.response.close();
        });
        final client = SupabaseClient(
          'http://127.0.0.1:${server.port}',
          'fixture-key',
        );
        addTearDown(client.dispose);
        final store = SyncStore(repo.database);
        final pending = store.pending;
        await expectLater(
          SyncEngine(
            store,
            SupabaseSyncGateway(client),
            backup: () async {},
          ).synchronize(account, project, () => true),
          throwsA(isA<PostgrestException>()),
        );
        expect(requests, everyElement('GET'));
        expect(store.pending, pending);
        expect(repo.journal('').single.answer, 'Keep this answer');
        expect(repo.schedule(1).single.description, 'Keep this room');
        expect(repo.todoTasks(topic).single.text, 'Keep this task');
      },
    );
  }
}
