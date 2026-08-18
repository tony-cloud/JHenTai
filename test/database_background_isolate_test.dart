import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/database/database_executor_native.dart';
import 'package:jhentai/service/path_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native database work does not block the UI isolate event loop',
    () async {
      final Directory tempDirectory =
          await Directory.systemTemp.createTemp('jhentai-background-db-');
      pathService
        ..tempDir = tempDirectory
        ..appDocDir = tempDirectory
        ..appSupportDir = tempDirectory
        ..systemDownloadDir = tempDirectory;
      final AppDb database = AppDb.forTesting(
        createNativeQueryExecutor(
          File('${tempDirectory.path}/test.sqlite'),
          tempDirectory: tempDirectory.path,
        ),
      );
      addTearDown(() async {
        await database.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await database.customSelect('SELECT 1').getSingle();

      int eventLoopTicks = 0;
      final Timer timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => eventLoopTicks++,
      );
      addTearDown(timer.cancel);

      await database.customSelect('''
        WITH RECURSIVE counter(value) AS (
          SELECT 0
          UNION ALL
          SELECT value + 1 FROM counter WHERE value < 5000000
        )
        SELECT sum(value) AS total FROM counter
      ''').getSingle();
      timer.cancel();

      expect(eventLoopTicks, greaterThan(0));
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
