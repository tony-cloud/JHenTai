import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:path/path.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

QueryExecutor createAppQueryExecutor() {
  return LazyDatabase(() async {
    final File file = File(join(pathService.getVisibleDir().path, 'db.sqlite'));
    final String tempDirectory = pathService.tempDir.path;

    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }

    return createNativeQueryExecutor(
      file,
      tempDirectory: tempDirectory,
    );
  });
}

/// Opens SQLite on a worker isolate so database operations cannot stall Flutter
/// frame rendering. This also makes large gallery/image transactions responsive.
QueryExecutor createNativeQueryExecutor(
  File file, {
  required String tempDirectory,
}) {
  sqlite3.tempDirectory = tempDirectory;

  return NativeDatabase.createInBackground(
    file,
    isolateSetup: () {
      sqlite3.tempDirectory = tempDirectory;
    },
    setup: (database) {
      database.execute('PRAGMA busy_timeout = 1000');
      database.execute('PRAGMA journal_mode = WAL');
    },
  );
}
