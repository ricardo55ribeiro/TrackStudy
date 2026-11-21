import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'local_repository.dart';

Future<String> installationDatabasePath() async {
  final support = await getApplicationSupportDirectory();
  return p.join(support.path, 'TrackStudy', 'trackstudy.sqlite');
}

Future<void> backupBeforeFirstSync(LocalStudyRepository repository) async {
  final file = File(
    '${repository.location}.before-first-sync-${DateTime.now().millisecondsSinceEpoch}.json',
  );
  final db = repository.db;
  db.execute('BEGIN');
  final String json;
  try {
    json = repository.exportJson();
  } finally {
    db.execute('ROLLBACK');
  }
  await file.writeAsString(json, flush: true);
}
