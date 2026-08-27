import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/downloaded_gallery_cleanup.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

DownloadedGalleryCleanupService downloadedGalleryCleanupService =
    DownloadedGalleryCleanupService();

class DownloadedGalleryCleanupService {
  static const int _metadataBatchSize = 25;

  Future<List<DownloadedGalleryDuplicateGroup>> findDuplicateGroups() async {
    await galleryDownloadService.completed;

    final List<GalleryDownloadedData> galleries =
        galleryDownloadService.gallerys
            .where(
              (gallery) =>
                  galleryDownloadService.galleryDownloadInfos[gallery.gid]
                      ?.downloadProgress.downloadStatus ==
                  DownloadStatus.downloaded,
            )
            .toList(growable: false);
    if (galleries.length < 2) {
      return const <DownloadedGalleryDuplicateGroup>[];
    }

    final List<Object> results = await Future.wait<Object>(<Future<Object>>[
      _fetchEnglishTitles(galleries),
      galleryDownloadService.getGalleryStorageStats(
        galleries.map((gallery) => gallery.gid).toList(growable: false),
      ),
    ]);
    final Map<int, String> englishTitles = results[0] as Map<int, String>;
    final Map<int, ({int sizeBytes, int imageCount})> stats =
        results[1] as Map<int, ({int sizeBytes, int imageCount})>;

    final List<DownloadedGalleryCleanupCandidate> candidates =
        galleries.map((gallery) {
      final ({int sizeBytes, int imageCount}) galleryStats =
          stats[gallery.gid] ?? (sizeBytes: 0, imageCount: 0);
      return DownloadedGalleryCleanupCandidate(
        gallery: gallery,
        englishTitle: englishTitles[gallery.gid] ?? gallery.title,
        sizeBytes: galleryStats.sizeBytes,
        downloadedImageCount: galleryStats.imageCount,
      );
    }).toList(growable: false);

    return groupDownloadedGalleriesByNormalizedEnglishTitle(candidates);
  }

  Future<DownloadedGalleryCleanupResult> applyActions(
    Map<DownloadedGalleryCleanupCandidate, DownloadedGalleryCleanupAction>
        actions,
  ) async {
    int deleted = 0;
    int unfavorited = 0;
    final Set<int> failedGids = <int>{};

    for (final MapEntry<DownloadedGalleryCleanupCandidate,
        DownloadedGalleryCleanupAction> entry in actions.entries) {
      if (entry.value == DownloadedGalleryCleanupAction.keep) {
        continue;
      }

      final GalleryDownloadedData gallery = entry.key.gallery;
      try {
        if (entry.value == DownloadedGalleryCleanupAction.deleteAndUnfavorite) {
          // Unfavorite first so a network error leaves the downloaded gallery
          // available for a retry from this review page.
          await ehRequest.requestRemoveFavorite(gallery.gid, gallery.token);
          unfavorited++;
        }

        final GalleryDownloadedData? current = galleryDownloadService.gallerys
            .cast<GalleryDownloadedData?>()
            .firstWhere(
              (candidate) => candidate?.gid == gallery.gid,
              orElse: () => null,
            );
        if (current == null) {
          continue;
        }

        await galleryDownloadService.deleteGallery(current);
        deleted++;
      } catch (error, stackTrace) {
        failedGids.add(gallery.gid);
        log.error(
          'Apply downloaded duplicate cleanup action failed, gid:${gallery.gid}',
          error,
          stackTrace,
        );
      }
    }

    return DownloadedGalleryCleanupResult(
      deleted: deleted,
      unfavorited: unfavorited,
      failedGids: failedGids,
    );
  }

  Future<Map<int, String>> _fetchEnglishTitles(
    List<GalleryDownloadedData> galleries,
  ) async {
    final Map<int, String> result = <int, String>{
      for (final GalleryDownloadedData gallery in galleries)
        gallery.gid: gallery.title,
    };

    for (int offset = 0;
        offset < galleries.length;
        offset += _metadataBatchSize) {
      final List<GalleryDownloadedData> batch = galleries
          .skip(offset)
          .take(_metadataBatchSize)
          .toList(growable: false);
      try {
        final List<GalleryMetadata> metadatas =
            await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: batch
              .map((gallery) => (gid: gallery.gid, token: gallery.token))
              .toList(growable: false),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        );
        for (final GalleryMetadata metadata in metadatas) {
          result[metadata.galleryUrl.gid] = metadata.title;
        }
      } catch (error, stackTrace) {
        log.warning(
          'Fetch English titles for duplicate gallery review batch failed; retry individually',
          error,
          true,
        );
        log.debug(stackTrace);

        for (final GalleryDownloadedData gallery in batch) {
          try {
            final GalleryMetadata metadata =
                await ehRequest.requestGalleryMetadata<GalleryMetadata>(
              gid: gallery.gid,
              token: gallery.token,
              parser: EHSpiderParser.galleryMetadataJson2GalleryMetadata,
            );
            result[gallery.gid] = metadata.title;
          } catch (error, stackTrace) {
            log.warning(
              'Fetch English title for duplicate gallery review failed, gid:${gallery.gid}; use stored title',
              error,
              true,
            );
            log.debug(stackTrace);
          }
        }
      }
    }

    return result;
  }
}

List<DownloadedGalleryDuplicateGroup>
    groupDownloadedGalleriesByNormalizedEnglishTitle(
  Iterable<DownloadedGalleryCleanupCandidate> candidates,
) {
  final Map<String, List<DownloadedGalleryCleanupCandidate>> byTitle =
      <String, List<DownloadedGalleryCleanupCandidate>>{};

  for (final DownloadedGalleryCleanupCandidate candidate in candidates) {
    final String normalized =
        normalizeEnglishGalleryTitle(candidate.englishTitle);
    if (normalized.isEmpty) {
      continue;
    }
    byTitle
        .putIfAbsent(normalized, () => <DownloadedGalleryCleanupCandidate>[])
        .add(candidate);
  }

  final List<DownloadedGalleryDuplicateGroup> groups =
      byTitle.entries.where((entry) => entry.value.length > 1).map((entry) {
    entry.value.sort((a, b) => b.gallery.gid.compareTo(a.gallery.gid));
    return DownloadedGalleryDuplicateGroup(
      normalizedTitle: entry.key,
      candidates:
          List<DownloadedGalleryCleanupCandidate>.unmodifiable(entry.value),
    );
  }).toList(growable: false)
        ..sort((a, b) => a.normalizedTitle.compareTo(b.normalizedTitle));

  return groups;
}

String normalizeEnglishGalleryTitle(String title) {
  return englishGalleryTitleWithoutLanguageTag(title).toLowerCase();
}

String englishGalleryTitleWithoutLanguageTag(String title) {
  const String languageNames =
      'english|chinese|japanese|korean|spanish|russian|french|portuguese|german|italian|polish|thai|vietnamese|dutch|hungarian|czech|arabic|indonesian|swedish|turkish|ukrainian|danish|finnish|norwegian';
  final RegExp languageMarker = RegExp(
    '\\[\\s*(?:$languageNames)(?:\\s+(?:translated|translation))?\\s*\\]',
    caseSensitive: false,
  );

  return title
      .replaceAll(languageMarker, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
