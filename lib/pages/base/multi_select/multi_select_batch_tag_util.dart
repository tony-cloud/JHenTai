import 'package:dio/dio.dart';
import 'package:get/get.dart';

import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/widget/eh_add_tag_dialog.dart';

class BatchTagTarget {
  const BatchTagTarget({
    required this.gid,
    required this.token,
    required this.galleryUrl,
  });

  final int gid;
  final String token;
  final String galleryUrl;
}

class BatchTagResult {
  const BatchTagResult({
    required this.successCount,
    required this.failedCount,
    this.firstErrorMessage,
  });

  final int successCount;
  final int failedCount;
  final String? firstErrorMessage;
}

Future<String?> showBatchAddTagDialog() async {
  final String? tag = await Get.dialog(EHAddTagDialog());
  final String? trimmedTag = tag?.trim();

  if (trimmedTag == null || trimmedTag.isEmpty) {
    return null;
  }

  return trimmedTag;
}

Future<BatchTagResult> addTagToTargets(
  List<BatchTagTarget> targets, {
  required String tag,
}) async {
  final int? apiuid = userSetting.ipbMemberId.value;

  if (apiuid == null || targets.isEmpty) {
    return BatchTagResult(
      successCount: 0,
      failedCount: targets.length,
      firstErrorMessage: 'needLoginToOperate'.tr,
    );
  }

  int successCount = 0;
  int failedCount = 0;
  String? firstErrorMessage;
  final Map<int, String> apikeysByGid = <int, String>{};

  for (final BatchTagTarget target in targets) {
    try {
      final String apikey = apikeysByGid[target.gid] ??=
          (await ehRequest.requestDetailPage<({GalleryDetail galleryDetails, String apikey})>(
        galleryUrl: target.galleryUrl,
        parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        useCacheIfAvailable: true,
      ))
              .apikey;

      final String? errMsg = await ehRequest.voteTag(
        target.gid,
        target.token,
        apiuid,
        apikey,
        tag,
        true,
        parser: EHSpiderParser.voteTagResponse2ErrorMessage,
      );

      if (errMsg == null || errMsg.isEmpty) {
        successCount++;
      } else {
        failedCount++;
        firstErrorMessage ??= errMsg;
      }
    } on DioException catch (e) {
      log.error('addTagFailed'.tr, e.error);
      failedCount++;
      firstErrorMessage ??= e.errorMsg;
    } on EHSiteException catch (e) {
      log.error('addTagFailed'.tr, e.message);
      failedCount++;
      firstErrorMessage ??= e.message;
    } catch (e, s) {
      log.error('addTagFailed'.tr, e, s);
      failedCount++;
      firstErrorMessage ??= e.toString();
    }
  }

  return BatchTagResult(
    successCount: successCount,
    failedCount: failedCount,
    firstErrorMessage: firstErrorMessage,
  );
}
