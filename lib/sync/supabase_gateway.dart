import 'package:supabase_flutter/supabase_flutter.dart';
import 'sync_gateway.dart';

class SupabaseSyncGateway implements SyncGateway, ConflictArchiveGateway {
  final SupabaseClient client;
  SupabaseSyncGateway(this.client);
  @override
  Future<bool> archiveEntryCopy(
    SyncRow entry,
    int version,
    String writer,
  ) async =>
      await client
              .rpc(
                'trackstudy_archive_entry_copy',
                params: {
                  'p_entry': entry,
                  'p_version': version,
                  'p_writer': writer,
                },
              )
              .timeout(const Duration(seconds: 25))
          as bool;
  @override
  Future<Map<String, List<SyncRow>>> pull(String accountId) async {
    final result = <String, List<SyncRow>>{};
    for (final table in syncTables) {
      final rows = <SyncRow>[];
      for (var offset = 0; ; offset += 500) {
        final page = await client
            .from(table)
            // Resolve new columns during the initial pull, even on empty
            // tables, so an older server cannot silently discard new fields.
            .select(switch (table) {
              'journal' => '*,sync_history,answer,answered_at',
              'schedule_blocks' => '*,sync_history,description',
              _ => '*,sync_history',
            })
            .eq('user_id', accountId)
            .order('id')
            .range(offset, offset + 499)
            .timeout(const Duration(seconds: 25));
        rows.addAll(page);
        if (page.length < 500) break;
      }
      result[table] = rows;
    }
    return result;
  }

  @override
  Future<SyncRow> merge(String table, SyncRow row) async =>
      Map<String, dynamic>.from(
        await client
                .rpc(
                  'trackstudy_merge',
                  params: {'p_table': table, 'p_row': row},
                )
                .timeout(const Duration(seconds: 25))
            as Map,
      );
}
