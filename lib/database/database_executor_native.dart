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

    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }

    sqlite3.tempDirectory = pathService.tempDir.path;

    return NativeDatabase(
      file,
      setup: (database) {
        database.execute('PRAGMA busy_timeout = 1000');
        database.execute('PRAGMA journal_mode = WAL');
      },
    );
  });
}
