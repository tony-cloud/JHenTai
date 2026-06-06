import 'dart:async';

import 'package:jhentai/database/dao/gallery_parent_cache_dao.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_history_entry.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

GalleryHistoryLineageService galleryHistoryLineageService = GalleryHistoryLineageService();

typedef GalleryHistoryDetailFetcher = Future<GalleryDetail?> Function(
  GalleryUrl galleryUrl, {
  bool useCacheIfAvailable,
});

class GalleryHistoryChain {
  final GalleryDetail firstDetail;
  final List<GalleryHistoryEntry> entries;
  final GalleryUrl latestGalleryUrl;

  GalleryHistoryChain({
    required this.firstDetail,
    required this.entries,
    required this.latestGalleryUrl,
  });

  factory GalleryHistoryChain.fromFirstDetail(
    GalleryDetail firstDetail, {
    GalleryUrl? latestGalleryUrl,
  }) {
    final List<GalleryHistoryEntry> entries = <GalleryHistoryEntry>[
      (
        galleryUrl: firstDetail.galleryUrl,
        title: _formatDetailTitle(firstDetail),
        updateTime: firstDetail.publishTime,
      ),
      ...?firstDetail.childrenGallerys,
    ];

    return GalleryHistoryChain(
      firstDetail: firstDetail,
      entries: entries,
      latestGalleryUrl:
          latestGalleryUrl ?? firstDetail.newVersionGalleryUrl ?? firstDetail.galleryUrl,
    );
  }

  int indexOfGid(int gid) {
    return entries.indexWhere((entry) => entry.galleryUrl.gid == gid);
  }

  bool containsGid(int gid) {
    return indexOfGid(gid) != -1;
  }

  List<GalleryHistoryEntry> entriesBeforeGid(int gid) {
    final int index = indexOfGid(gid);
    if (index <= 0) {
      return const <GalleryHistoryEntry>[];
    }

    return entries.sublist(0, index);
  }

  List<GalleryHistoryEntry> entriesAfterGid(int gid) {
    final int index = indexOfGid(gid);
    if (index == -1 || index + 1 >= entries.length) {
      return const <GalleryHistoryEntry>[];
    }

    return entries.sublist(index + 1);
  }

  static String _formatDetailTitle(GalleryDetail detail) {
    final String? japaneseTitle = detail.japaneseTitle;
    if (japaneseTitle != null && japaneseTitle.isNotEmpty) {
      return japaneseTitle;
    }

    return detail.rawTitle;
  }
}

class GalleryHistoryLineageService {
  final Map<int, GalleryDetail> _detailCache = <int, GalleryDetail>{};
  final Map<int, GalleryMetadata> _metadataCache = <int, GalleryMetadata>{};

  DateTime? _lastMetadataRequestAt;

  GalleryDetail? getCachedDetail(GalleryUrl galleryUrl) {
    return _detailCache[galleryUrl.gid];
  }

  void cacheDetail(GalleryDetail detail) {
    _detailCache[detail.galleryUrl.gid] = detail;
  }

  GalleryMetadata? getCachedMetadata(GalleryUrl galleryUrl) {
    return _metadataCache[galleryUrl.gid];
  }

  void cacheMetadata(GalleryMetadata metadata) {
    _metadataCache[metadata.galleryUrl.gid] = metadata;
  }

  Future<GalleryMetadata?> getGalleryMetadata({
    required GalleryUrl galleryUrl,
    bool useCache = true,
    bool allowOnline = true,
    Duration minRequestInterval = const Duration(milliseconds: 1250),
  }) async {
    if (useCache) {
      final GalleryMetadata? cachedMetadata = getCachedMetadata(galleryUrl);
      if (cachedMetadata != null) {
        return cachedMetadata;
      }
    }

    if (!allowOnline) {
      return null;
    }

    await _waitForMetadataRateLimit(minRequestInterval);

    try {
      final GalleryMetadata? metadata = await ehRequest.requestGalleryMetadata<GalleryMetadata?>(
        gid: galleryUrl.gid,
        token: galleryUrl.token,
        parser: EHSpiderParser.galleryMetadataJson2GalleryMetadata,
      );

      if (metadata != null) {
        cacheMetadata(metadata);
        await GalleryParentCacheDao.upsertParentGallery(
          metadata.galleryUrl.gid,
          metadata.parentGalleryUrl,
        );
      }

      return metadata;
    } catch (e, s) {
      log.warning('Fetch gallery metadata failed, gid:${galleryUrl.gid}', e, true);
      log.error('Fetch gallery metadata failed', e, s);
      return null;
    }
  }

  Future<GalleryHistoryChain?> getHistoryChainFromFirstGallery({
    required GalleryDetail baseDetail,
    required GalleryHistoryDetailFetcher fetchDetail,
    bool useCache = true,
    bool allowOnline = true,
    Duration minRequestInterval = const Duration(milliseconds: 1250),
  }) async {
    final GalleryMetadata? metadata = await getGalleryMetadata(
      galleryUrl: baseDetail.galleryUrl,
      useCache: useCache,
      allowOnline: allowOnline,
      minRequestInterval: minRequestInterval,
    );

    final GalleryUrl? firstGalleryUrl = metadata?.firstGalleryUrl;
    final GalleryUrl? latestGalleryUrl = metadata?.currentGalleryUrl;

    GalleryDetail? firstDetail;
    if (firstGalleryUrl != null && firstGalleryUrl.gid != baseDetail.galleryUrl.gid) {
      firstDetail = await fetchDetail(
        firstGalleryUrl,
        useCacheIfAvailable: useCache,
      );
    } else if (firstGalleryUrl == null && baseDetail.parentGalleryUrl != null) {
      return null;
    } else {
      firstDetail = baseDetail;
    }

    if (firstDetail == null) {
      return null;
    }

    cacheDetail(firstDetail);
    return GalleryHistoryChain.fromFirstDetail(
      firstDetail,
      latestGalleryUrl: latestGalleryUrl,
    );
  }

  Future<int> clearParentGalleryCache() {
    return GalleryParentCacheDao.deleteAll();
  }

  Future<GalleryUrl?> getParentGallery({
    required GalleryUrl galleryUrl,
    String? oldVersionGalleryUrl,
    bool useCache = true,
    bool allowOnline = true,
    Duration minRequestInterval = const Duration(milliseconds: 1250),
  }) async {
    final Map<int, GalleryUrl?> result = await getParentGalleryMapByChildGids(
      galleryUrls: <GalleryUrl>[galleryUrl],
      oldVersionGalleryUrlsByGid: <int, String?>{
        galleryUrl.gid: oldVersionGalleryUrl,
      },
      useCache: useCache,
      allowOnline: allowOnline,
      minRequestInterval: minRequestInterval,
      batchSize: 1,
    );

    return result[galleryUrl.gid];
  }

  Future<Map<int, GalleryUrl?>> getParentGalleryMapByChildGids({
    required List<GalleryUrl> galleryUrls,
    Map<int, String?>? oldVersionGalleryUrlsByGid,
    bool useCache = true,
    bool allowOnline = true,
    Duration minRequestInterval = const Duration(milliseconds: 1250),
    int batchSize = 25,
  }) async {
    if (galleryUrls.isEmpty) {
      return const <int, GalleryUrl?>{};
    }

    final Map<int, GalleryUrl> childUrlByGid = <int, GalleryUrl>{
      for (final GalleryUrl url in galleryUrls) url.gid: url,
    };
    final Map<int, GalleryUrl?> parentByChild = <int, GalleryUrl?>{};

    if (oldVersionGalleryUrlsByGid != null && oldVersionGalleryUrlsByGid.isNotEmpty) {
      for (final MapEntry<int, String?> entry in oldVersionGalleryUrlsByGid.entries) {
        final GalleryUrl? oldVersion = GalleryUrl.tryParse(entry.value ?? '');
        if (oldVersion == null) {
          continue;
        }

        parentByChild[entry.key] = oldVersion;
      }
    }

    if (useCache) {
      final List<int> childGids = childUrlByGid.keys.toList();
      final cacheRows = await GalleryParentCacheDao.selectByChildGids(childGids);

      for (final row in cacheRows) {
        parentByChild[row.childGid] = _parseCacheRowParent(
          childUrlByGid[row.childGid],
          row.parentGid,
          row.parentToken,
          row.parentGalleryUrl,
        );
      }
    }

    final List<int> unresolved =
        childUrlByGid.keys.where((gid) => !parentByChild.containsKey(gid)).toList(growable: false);

    if (!allowOnline || unresolved.isEmpty) {
      return parentByChild;
    }

    for (int offset = 0; offset < unresolved.length; offset += batchSize) {
      final List<int> batchGids = unresolved.skip(offset).take(batchSize).toList(growable: false);
      final List<GalleryUrl> batchGalleryUrls = batchGids
          .map((gid) => childUrlByGid[gid])
          .whereType<GalleryUrl>()
          .toList(growable: false);

      if (batchGalleryUrls.isEmpty) {
        continue;
      }

      final Map<int, GalleryUrl?> batchParentMap = <int, GalleryUrl?>{
        for (final galleryUrl in batchGalleryUrls) galleryUrl.gid: null,
      };
      bool requestSucceeded = false;

      await _waitForMetadataRateLimit(minRequestInterval);

      try {
        final List<GalleryMetadata> metadatas =
            await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: batchGalleryUrls
              .map((galleryUrl) => (
                    gid: galleryUrl.gid,
                    token: galleryUrl.token,
                  ))
              .toList(growable: false),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        );

        for (final GalleryMetadata metadata in metadatas) {
          cacheMetadata(metadata);
          batchParentMap[metadata.galleryUrl.gid] = metadata.parentGalleryUrl;
        }
        requestSucceeded = true;
      } catch (e, s) {
        log.warning(
          'Fetch parent gallery metadata failed, gids:$batchGids',
          e,
          true,
        );
        log.error('Fetch parent gallery metadata failed', e, s);
      }

      if (!requestSucceeded) {
        continue;
      }

      parentByChild.addAll(batchParentMap);
      await GalleryParentCacheDao.batchUpsertParentGallery(batchParentMap);
    }

    return parentByChild;
  }

  GalleryUrl? _parseCacheRowParent(
    GalleryUrl? childGalleryUrl,
    int? parentGid,
    String? parentToken,
    String? parentGalleryUrl,
  ) {
    final GalleryUrl? parsedUrl = GalleryUrl.tryParse(parentGalleryUrl ?? '');
    if (parsedUrl != null) {
      return parsedUrl;
    }

    if (parentGid == null || parentGid <= 0) {
      return null;
    }

    if (parentToken == null || parentToken.length != 10) {
      return null;
    }

    return GalleryUrl(
      isEH: childGalleryUrl?.isEH ?? true,
      gid: parentGid,
      token: parentToken,
    );
  }

  Future<void> _waitForMetadataRateLimit(Duration minRequestInterval) async {
    if (minRequestInterval <= Duration.zero) {
      _lastMetadataRequestAt = DateTime.now();
      return;
    }

    final DateTime now = DateTime.now();
    final DateTime? last = _lastMetadataRequestAt;
    if (last != null) {
      final Duration elapsed = now.difference(last);
      if (elapsed < minRequestInterval) {
        await Future.delayed(minRequestInterval - elapsed);
      }
    }

    _lastMetadataRequestAt = DateTime.now();
  }
}
