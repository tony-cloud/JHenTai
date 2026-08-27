import 'package:jhentai/database/database.dart';

enum DownloadedGalleryCleanupAction {
  keep,
  delete,
  deleteAndUnfavorite,
}

class DownloadedGalleryCleanupCandidate {
  const DownloadedGalleryCleanupCandidate({
    required this.gallery,
    required this.englishTitle,
    required this.sizeBytes,
    required this.downloadedImageCount,
  });

  final GalleryDownloadedData gallery;
  final String englishTitle;
  final int sizeBytes;
  final int downloadedImageCount;
}

class DownloadedGalleryDuplicateGroup {
  const DownloadedGalleryDuplicateGroup({
    required this.normalizedTitle,
    required this.candidates,
  });

  final String normalizedTitle;
  final List<DownloadedGalleryCleanupCandidate> candidates;
}

class DownloadedGalleryCleanupResult {
  const DownloadedGalleryCleanupResult({
    required this.deleted,
    required this.unfavorited,
    required this.failedGids,
  });

  final int deleted;
  final int unfavorited;
  final Set<int> failedGids;
}
