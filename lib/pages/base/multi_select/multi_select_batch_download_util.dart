import 'package:jhentai/service/gallery_download_service.dart';

enum BatchGalleryDownloadAction {
  update,
  download,
  skip,
}

BatchGalleryDownloadAction decideBatchGalleryDownloadAction({
  required bool hasGalleryRecord,
  required DownloadStatus? galleryStatus,
  required bool hasArchiveRecord,
}) {
  if (hasGalleryRecord) {
    return galleryStatus == DownloadStatus.downloaded
        ? BatchGalleryDownloadAction.update
        : BatchGalleryDownloadAction.skip;
  }

  if (hasArchiveRecord) {
    return BatchGalleryDownloadAction.skip;
  }

  return BatchGalleryDownloadAction.download;
}
