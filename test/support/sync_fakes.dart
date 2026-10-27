import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackstudy/sync/auth_service.dart';
import 'package:trackstudy/sync/sync_gateway.dart';
import 'package:trackstudy/sync/sync_history.dart';

const account = '11111111-1111-4111-8111-111111111111';
const primaryAccount = account;
const other = '22222222-2222-4222-8222-222222222222';
const project = 'https://example.supabase.co';
SyncRow clone(SyncRow row) => jsonDecode(jsonEncode(row)) as SyncRow;

class FakeCloud implements SyncGateway {
  final tables = {for (final table in syncTables) table: <String, SyncRow>{}};
  bool offline = false;
  String? loseResponseFor;
  void Function(String, SyncRow)? duringUpload;
  Future<void> Function()? duringPull;
  int calls = 0;
  final conflicts = <SyncRow>[];
  @override
  Future<Map<String, List<SyncRow>>> pull(String accountId) async {
    calls++;
    if (offline) throw const SocketException('offline');
    await duringPull?.call();
    return {
      for (final table in syncTables)
        table: tables[table]!.values
            .where((r) => r['user_id'] == accountId)
            .map(clone)
            .toList(),
    };
  }

  @override
  Future<SyncRow> merge(String table, SyncRow row) async {
    calls++;
    if (offline) throw const SocketException('offline');
    final incoming = clone(row)..['user_id'] = account;
    if (table == 'todo_tasks') {
      final parent = tables['todo_topics']![incoming['topic_id']];
      if (parent == null) throw StateError('Missing topic');
      incoming['deleted_at'] ??= parent['deleted_at'];
    }
    if (table == 'weekly_goals' || table == 'reviews') {
      final existing = tables[table]!.values
          .where(
            (r) =>
                r['week_start'] == row['week_start'] &&
                (table != 'weekly_goals' ||
                    r['category_id'] == row['category_id']),
          )
          .firstOrNull;
      if (existing != null) incoming['id'] = existing['id'];
    }
    final id = incoming['id'] as String;
    final existing = tables[table]![id];
    final ih = historyOf(incoming);
    final eh = existing == null ? <String, int>{} : historyOf(existing);
    final incomingCovers = coversHistory(ih, eh);
    final existingCovers = coversHistory(eh, ih);
    var winner =
        existing == null ||
        (incomingCovers && !existingCovers) ||
        (incomingCovers == existingCovers &&
            ((incoming['sync_version'] as int) >
                    (existing['sync_version'] as int) ||
                (incoming['sync_version'] == existing['sync_version'] &&
                    (incoming['sync_writer'] as String).compareTo(
                          existing['sync_writer'] as String,
                        ) >
                        0)));
    if (existing != null &&
        table.startsWith('todo_') &&
        (incoming['deleted_at'] != null) != (existing['deleted_at'] != null)) {
      winner = incoming['deleted_at'] != null;
    }
    if (existing != null &&
        !incomingCovers &&
        !existingCovers &&
        !sameSyncContent(incoming, existing)) {
      conflicts.add(clone(winner ? existing : incoming));
    }
    incoming['sync_history'] = mergeHistory(ih, eh);
    if (winner) {
      if (table == 'entries') {
        expectSync(
          tables['weekly_goals']!.containsKey(incoming['goal_id']),
          isTrue,
        );
      }
      tables[table]![id] = incoming;
    } else {
      existing!['sync_history'] = incoming['sync_history'];
    }
    duringUpload?.call(table, row);
    if (loseResponseFor == table) {
      loseResponseFor = null;
      throw const SocketException('response lost after server commit');
    }
    return clone(tables[table]![id]!);
  }
}

class FakeAuth implements SyncAuth {
  SyncAccount? user;
  bool reject = false;
  final events = StreamController<SyncAccount?>.broadcast();
  @override
  SyncAccount? get account => user;
  @override
  Stream<SyncAccount?> get changes => events.stream;
  @override
  Future<void> signIn(String email, String password) async {
    if (reject) throw StateError('invalid credentials');
    user = SyncAccount(accountIdFor(email), email);
    events.add(user);
  }

  String accountIdFor(String email) =>
      email == 'other@example.com' ? other : primaryAccount;
  @override
  Future<void> signOut() async {
    user = null;
    events.add(null);
  }
}

class ArchiveCloud extends FakeCloud implements ConflictArchiveGateway {
  bool verified = false;
  int archiveRequests = 0;
  @override
  Future<bool> archiveEntryCopy(
    SyncRow entry,
    int version,
    String writer,
  ) async {
    archiveRequests++;
    return verified;
  }
}
