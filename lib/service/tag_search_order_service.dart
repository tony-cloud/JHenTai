import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/dao/tag_count_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/rpc_request.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/preference_setting.dart';
import 'package:jhentai/setting/rpc_setting.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';
import 'package:path/path.dart';
import 'package:retry/retry.dart';

import 'package:jhentai/utils/byte_util.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/tag_count_source.dart';

TagSearchOrderOptimizationService tagSearchOrderOptimizationService =
    TagSearchOrderOptimizationService();

class TagSearchOrderOptimizationService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  late final String savePath;

  static const String releaseUrl =
      'https://github.com/mokurin000/e-hentai-tag-count/releases/latest';

  Rx<LoadingState> loadingState = LoadingState.idle.obs;
  RxnString version = RxnString(null);
  RxString downloadProgress = RxString('0 MB');

  bool get isReady =>
      preferenceSetting.enableTagZHSearchOrderOptimization.isTrue &&
      (loadingState.value == LoadingState.success || version.value != null);

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..add(localConfigService);

  @override
  Future<void> doInitBean() async {
    savePath = join(pathService.getVisibleDir().path, 'tid_count_tag.csv.gz');

    localConfigService
        .read(configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState)
        .then((value) =>
            loadingState.value = LoadingState.values[value != null ? int.parse(value) : 0]);

    localConfigService
        .read(configKey: ConfigEnum.tagSearchOrderOptimizationServiceVersion)
        .then((value) => version.value = value);
  }

  @override
  Future<void> doAfterBeanReady() async {
    if (isReady) {
      fetchDataFromGithub();
    }
  }

  Future<void> fetchDataFromGithub() async {
    if (preferenceSetting.enableTagZHSearchOrderOptimization.isFalse) {
      return;
    }
    if (loadingState.value == LoadingState.loading) {
      return;
    }

    log.info('Fetch tag order optimization data from github');

    loadingState.value = LoadingState.loading;
    downloadProgress.value = '0 KB';

    try {
      final release = await retry(
        () async => TagCountSource.parseRelease(await _fetchBytes(TagCountSource.releaseUrl)),
        maxAttempts: 3,
      );
      if (release.version != version.value) {
        List<TagCountEntry>? entries;
        Object? lastError;
        for (final url in release.assetUrls) {
          try {
            entries = await compute(
                TagCountSource.decode,
                await retry(
                  () => _fetchBytes(url),
                  maxAttempts: 3,
                ));
            break;
          } catch (error) {
            lastError = error;
          }
        }
        if (entries == null) {
          throw FormatException('No usable tag count asset: $lastError');
        }
        // Validate the complete payload before replacing the working database.
        await TagCountDao.replaceTagCount(entries
            .map((entry) => TagCountData(namespaceWithKey: entry.tag, count: entry.count))
            .toList());
        version.value = release.version;
        await localConfigService.write(
            configKey: ConfigEnum.tagSearchOrderOptimizationServiceVersion,
            value: release.version);
      }
      loadingState.value = LoadingState.success;
      log.info('Tag order optimization data ready, version: ${version.value}');
    } catch (error, stack) {
      log.error('Update tag order optimization data failed', error, stack);
      loadingState.value = LoadingState.error;
    } finally {
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      final file = File(savePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<List<int>> _fetchBytes(String url) async {
    if (rpcSetting.enableRpcMode.isTrue) {
      final result = await rpcRequest.requestSystemFetchUrl(url: url, expectBinary: true);
      final bytes = _parseRpcBinary(result['data']);
      downloadProgress.value = byte2String(bytes.length.toDouble());
      return bytes;
    }
    await ehRequest.download(
      url: url,
      path: savePath,
      receiveTimeout: 10 * 60 * 1000,
      onReceiveProgress: (count, total) =>
          downloadProgress.value = byte2String(count.toDouble()),
    );
    return File(savePath).readAsBytes();
  }

  List<int> _parseRpcBinary(dynamic data) {
    if (data is List<int>) {
      return data;
    }

    if (data is List) {
      return data.map((e) => e is int ? e : int.parse(e.toString())).toList();
    }

    return <int>[];
  }

  Future<List<TagCountData>> batchSelectTagCount(List<String> namespaceWithKeys) {
    if (namespaceWithKeys.isEmpty) {
      return Future.value([]);
    }
    return TagCountDao.batchSelectTagCount(namespaceWithKeys);
  }
}
