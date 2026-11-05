import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:trackstudy/domain/week.dart';
import 'package:trackstudy/domain/planning.dart';
import 'package:trackstudy/sync/supabase_gateway.dart';
import 'package:trackstudy/sync/sync_engine.dart';
import 'package:trackstudy/sync/sync_store.dart';
import 'journal_details_test.dart' show memory, thought, lesson;
import 'support/sync_fakes.dart' show account, project;

void main() {
  for (final missingTable in [
    'category_states',
    'journal',
    'schedule_blocks',
    'academic_events',
    'todo_topics',
    'todo_tasks',
  ]) {
    test(
      'missing $missingTable schema prevents uploads and retains local edits',
      () async {
        final repo = memory();
        addTearDown(repo.close);
        final week = Week.containing(DateTime.now());
        final bar = repo.loadWeek(week, current: week).first;
        repo.setCategoryStatus(
          bar.categoryId,
          current: week,
          active: false,
          archived: true,
        );
        final entry = thought();
        final topic = repo.addTodoTopic('Safe offline');
        repo.addTodoTask(topic, 'Keep this task');
        repo.saveJournal(entry);
        repo.answerJournal(
          entry.id,
          'Keep this answer',
          question: entry.question,
        );
        repo.saveSchedule(
          ScheduleBlock(
            id: lesson().id,
            title: 'Keep this block',
            weekday: 1,
            startMinute: 510,
            endMinute: 600,
            description: 'Keep this room',
            colour: ScheduleColour.black,
          ),
        );
        repo.saveAcademicEvent(
          AcademicEvent(
            id: lesson().id,
            title: 'Keep event',
            date: '2026-11-05',
            type: AcademicType.exam,
            colour: ScheduleColour.black,
          ),
        );
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
                    : [
                        'schedule_blocks',
                        'academic_events',
                      ].contains(missingTable)
                    ? 'colour'
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
        expect(store.pendingRows('category_states'), isNotEmpty);
        expect(
          repo.categories().firstWhere((c) => c.id == bar.categoryId).archived,
          isTrue,
        );
        expect(repo.journal('').single.answer, 'Keep this answer');
        expect(repo.schedule(1).single.description, 'Keep this room');
        expect(repo.schedule(1).single.colour, ScheduleColour.black);
        expect(repo.todoTasks(topic).single.text, 'Keep this task');
        expect(
          repo.academicEvents(DateTime(2026, 11)).single.colour,
          ScheduleColour.black,
        );
      },
    );
  }
}
