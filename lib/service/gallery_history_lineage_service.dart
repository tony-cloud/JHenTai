import 'dart:async';

import 'package:jhentai/database/dao/gallery_parent_cache_dao.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

GalleryHistoryLineageService galleryHistoryLineageService = GalleryHistoryLineageService();

class GalleryHistoryLineageService {
  final Map<int, GalleryDetail> _detailCache = <int, GalleryDetail>{};

  DateTime? _lastMetadataRequestAt;

  GalleryDetail? getCachedDetail(GalleryUrl galleryUrl) {
    return _detailCache[galleryUrl.gid];
  }

  void cacheDetail(GalleryDetail detail) {
    _detailCache[detail.galleryUrl.gid] = detail;
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
