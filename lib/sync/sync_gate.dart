import 'package:sqlite3/sqlite3.dart';
import 'sync_gateway.dart';

class SyncBusy implements Exception {}

/// A separate SQLite writer lock covers the whole pass and session lifecycle
/// without holding a write transaction on the study database
class SyncGate {
  final String path;
  const SyncGate(this.path);

  Future<T> run<T>(
    Future<T> Function() action, {
    required Duration wait,
    required bool Function() active,
  }) async {
    final elapsed = Stopwatch()..start();
    final db = sqlite3.open(path);
    try {
      while (true) {
        if (!active()) throw SyncCancelled();
        try {
          db.execute('BEGIN IMMEDIATE');
          break;
        } on SqliteException catch (error) {
          if (error.resultCode != SqlError.SQLITE_BUSY &&
              error.resultCode != SqlError.SQLITE_LOCKED) {
            rethrow;
          }
          if (elapsed.elapsed >= wait) throw SyncBusy();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return await action();
    } finally {
      // Closing rolls back the empty transaction and releases the lock
      db.close();
    }
  }
}
