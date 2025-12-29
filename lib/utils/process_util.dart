import 'dart:io';

import 'package:get/get.dart';
import 'package:jhentai/utils/string_uril.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:path/path.dart';

import 'package:jhentai/setting/read_setting.dart';
import 'package:jhentai/service/log.dart';

Future<void> openThirdPartyViewer(String dirPath) async {
  String viewerPath = readSetting.thirdPartyViewerPath.value!;

  try {
    final ProcessResult result = await Process.run(
      basename(viewerPath),
      [dirPath],
      workingDirectory: dirname(viewerPath),
      runInShell: true,
    );

    if (!isEmptyOrNull(result.stderr)) {
      toast('internalError'.tr + result.stderr);
      log.error(result.stderr);
      log.uploadError(
        Exception('Process Error'),
        extraInfos: {
          'viewerPath': viewerPath,
          'dirPath': dirPath,
          'exitCode': result.exitCode,
          'stderr': result.stderr,
        },
      );
    }
  } on Object catch (e) {
    toast('internalError'.tr + e.toString());
    log.error(e);
    log.uploadError(
      e,
      extraInfos: {'viewerPath': viewerPath, 'dirPath': dirPath},
    );
  }
}
