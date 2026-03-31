import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_batch_download_util.dart';
import 'package:jhentai/service/gallery_download_service.dart';

void main() {
  group('decideBatchGalleryDownloadAction', () {
    test('returns update for completed local gallery download', () {
      expect(
        decideBatchGalleryDownloadAction(
          hasGalleryRecord: true,
          galleryStatus: DownloadStatus.downloaded,
          hasArchiveRecord: false,
        ),
        BatchGalleryDownloadAction.update,
      );
    });

    test('returns skip for incomplete local gallery download', () {
      expect(
        decideBatchGalleryDownloadAction(
          hasGalleryRecord: true,
          galleryStatus: DownloadStatus.downloading,
          hasArchiveRecord: false,
        ),
        BatchGalleryDownloadAction.skip,
      );
    });

    test('returns skip when archive has already been downloaded', () {
      expect(
        decideBatchGalleryDownloadAction(
          hasGalleryRecord: false,
          galleryStatus: null,
          hasArchiveRecord: true,
        ),
        BatchGalleryDownloadAction.skip,
      );
    });

    test('returns download for never downloaded gallery', () {
      expect(
        decideBatchGalleryDownloadAction(
          hasGalleryRecord: false,
          galleryStatus: null,
          hasArchiveRecord: false,
        ),
        BatchGalleryDownloadAction.download,
      );
    });
  });
}
