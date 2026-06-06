import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:jhentai/service/gallery_update_queue_service.dart';
import 'package:jhentai/utils/route_util.dart';

bool _isShowingGalleryUpdateStatusDialog = false;

Future<void> showGalleryUpdateStatusDialog() async {
  if (_isShowingGalleryUpdateStatusDialog) {
    return;
  }

  _isShowingGalleryUpdateStatusDialog = true;
  try {
    await Get.dialog(const EHGalleryUpdateStatusDialog());
  } finally {
    _isShowingGalleryUpdateStatusDialog = false;
  }
}

class EHGalleryUpdateStatusDialog extends StatelessWidget {
  const EHGalleryUpdateStatusDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<GalleryUpdateQueueService>(
      init: galleryUpdateQueueService,
      autoRemove: false,
      builder: (service) {
        final double? progressValue = service.totalCount <= 0
            ? null
            : (service.processedCount / service.totalCount).clamp(0.0, 1.0).toDouble();
        final String progress = service.totalCount <= 0
            ? service.processedCount.toString()
            : '${service.processedCount}/${service.totalCount}';

        return AlertDialog(
          title: Text('updateGallery'.tr),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(service.operationLabel),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progressValue),
              const SizedBox(height: 8),
              Text(progress),
              const SizedBox(height: 8),
              Text('${'downloadAndUpdateQueued'.tr}: ${service.startedCount}'),
              Text('${'updateGallerySummarySkipped'.tr}: ${service.skippedCount}'),
              Text('${'updateGallerySummaryFailed'.tr}: ${service.failedCount}'),
            ],
          ),
          actions: [
            TextButton(onPressed: backRoute, child: Text('OK'.tr)),
            TextButton(
              onPressed: service.abortRequested || !service.isHandlingUpdateGallery
                  ? null
                  : () {
                      service.requestAbort();
                      backRoute();
                    },
              child: Text('stop'.tr),
            ),
          ],
          actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
        );
      },
    );
  }
}
