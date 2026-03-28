import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/dao/tag_count_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/rpc_request.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/preference_setting.dart';
import 'package:jhentai/setting/rpc_setting.dart';
import 'package:jhentai/utils/archive_util.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';
import 'package:path/path.dart';
import 'package:retry/retry.dart';

import 'package:jhentai/utils/byte_util.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/toast_util.dart';

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
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..add(localConfigService);

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

    /// get latest tag
    String tag;
    try {
      tag = await retry(
        () async {
          if (rpcSetting.enableRpcMode.isTrue) {
            final Map<String, dynamic> result = await rpcRequest.requestSystemFetchUrl(
              url: releaseUrl,
              method: 'GET',
              headers: <String, String>{
                HttpHeaders.acceptHeader: '*/*',
              },
            );

            return EHSpiderParser.latestReleaseResponse2Tag(
              _parseRpcHeaders(result['headers']),
              result['data'],
            );
          }

          return ehRequest.get(
            url: releaseUrl,
            options: Options(followRedirects: false, validateStatus: (status) => status == 302),
            parser: EHSpiderParser.latestReleaseResponse2Tag,
          );
        },
        maxAttempts: 5,
        onRetry: (error) =>
            log.warning('Fetch tag order optimization data from github failed, retry.'),
      );
    } on DioException catch (e) {
      log.error('Fetch tag order optimization data from github failed after 5 times', e.errorMsg);
      loadingState.value = LoadingState.error;
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      return;
    }

    if (tag == version.value) {
      log.info('Tag order optimization data is up to date, tag: $tag');
      loadingState.value = LoadingState.success;
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      return;
    }

    /// download tag count metadata
    try {
      await retry(
        () async {
          final String downloadUrl =
              'https://github.com/mokurin000/e-hentai-tag-count/releases/download/$tag/tid_count_tag.csv.gz';

          if (rpcSetting.enableRpcMode.isTrue) {
            final Map<String, dynamic> result = await rpcRequest.requestSystemFetchUrl(
              url: downloadUrl,
              expectBinary: true,
            );
            final List<int> bytes = _parseRpcBinary(result['data']);
            if (bytes.isEmpty) {
              throw Exception('RPC returned empty tag order payload');
            }
            await File(savePath).writeAsBytes(bytes, flush: true);
            downloadProgress.value = byte2String(bytes.length.toDouble());
            return;
          }

          await ehRequest.download(
            url: downloadUrl,
            path: savePath,
            receiveTimeout: 10 * 60 * 1000,
            onReceiveProgress: (count, total) =>
                downloadProgress.value = byte2String(count.toDouble()),
          );
        },
        maxAttempts: 5,
        onRetry: (error) => log.warning('Download tag order optimization data failed, retry.'),
      );
    } on Exception catch (e) {
      log.error('Download tag translation data failed after 5 times', e.toString());
      loadingState.value = LoadingState.error;
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      return;
    }

    log.info('Fetch tag order optimization data from github success');

    List<int> bytes = await extractGZipArchive(savePath);
    if (bytes.isEmpty) {
      log.error('Extract tag order optimization data failed');
      toast('internalError'.tr);
      loadingState.value = LoadingState.error;
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      return;
    }

    List<List<dynamic>> rows;
    try {
      rows = await compute(
        (List<int> bytes) async {
          String csv = utf8.decode(bytes);
          return const CsvToListConverter(eol: '\n', textDelimiter: '\'', allowInvalid: false)
              .convert(csv);
        },
        bytes,
      );
    } on Exception catch (e) {
      log.error('Parse tag order optimization data failed', e);
      toast('internalError'.tr);
      loadingState.value = LoadingState.error;
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      return;
    }

    if (rows.length < 2) {
      log.error('Parse tag order optimization data failed, rows length: ${rows.length}');
      toast('internalError'.tr);
      loadingState.value = LoadingState.error;
      await localConfigService.write(
          configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
          value: loadingState.value.index.toString());
      return;
    }

    List<TagCountData> tagCountData = rows
        .where((row) => row[1] >= 5)
        .map((row) =>
            TagCountData(namespaceWithKey: (row[2] as String).replaceAll('"', ''), count: row[1]))
        .toList();
    version.value = null;
    await TagCountDao.replaceTagCount(tagCountData);
    version.value = tag;

    loadingState.value = LoadingState.success;

    await localConfigService.write(
        configKey: ConfigEnum.tagSearchOrderOptimizationServiceLoadingState,
        value: loadingState.value.index.toString());
    await localConfigService.write(
        configKey: ConfigEnum.tagSearchOrderOptimizationServiceVersion, value: tag);

    File(savePath).delete().ignore();
    log.info('Refresh tag order optimization data success');
  }

  Headers _parseRpcHeaders(dynamic headers) {
    if (headers is! Map) {
      return Headers();
    }

    final Map<String, List<String>> parsed = <String, List<String>>{};
    headers.forEach((key, value) {
      final String normalizedKey = key.toString();

      if (value is List) {
        parsed[normalizedKey] = value.map((e) => e.toString()).toList();
        return;
      }

      if (value == null) {
        return;
      }

      parsed[normalizedKey] = <String>[value.toString()];
    });

    return Headers.fromMap(parsed);
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
