import 'sync_gateway.dart';
import 'sync_store.dart';

class SyncEngine {
  final SyncStore store;
  final SyncGateway gateway;
  final Future<void> Function() backup;
  SyncEngine(this.store, this.gateway, {required this.backup});

  Future<void> synchronize(
    String account,
    String project,
    bool Function() active,
  ) async {
    void guard() {
      if (!active()) throw SyncCancelled();
    }

    guard();
    store.bind(account, project, guard: guard);
    if (store.meta('first_backup').isEmpty) {
      await backup();
      store.database.transaction(() {
        guard();
        store.setMeta('first_backup', DateTime.now().toUtc().toIso8601String());
      });
    }
    final remote = await gateway.pull(account);
    store.apply(
      remote,
      account,
      bootstrap: store.meta('initial_sync').isEmpty,
      guard: guard,
      markInitialSync: true,
    );
    for (final table in syncTables) {
      // Read children after parents so reconciled goal IDs reach every upload.
      for (final row in store.pendingRows(table)) {
        guard();
        final response = await gateway.merge(table, row);
        store.apply(
          {
            table: [response],
          },
          account,
          guard: guard,
        );
      }
    }
    store.database.transaction(() {
      guard();
      store.setMeta('last_sync', DateTime.now().toUtc().toIso8601String());
    });
  }
}
