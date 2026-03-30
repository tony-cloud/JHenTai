import 'package:drift/drift.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/gallery_url.dart';

class GalleryParentCacheDao {
  static Future<GalleryParentCacheData?> selectByChildGid(int childGid) {
    return (appDb.select(appDb.galleryParentCache)
          ..where((table) => table.childGid.equals(childGid)))
        .getSingleOrNull();
  }

  static Future<List<GalleryParentCacheData>> selectByChildGids(List<int> childGids) {
    if (childGids.isEmpty) {
      return Future.value(const <GalleryParentCacheData>[]);
    }

    return (appDb.select(appDb.galleryParentCache)
          ..where((table) => table.childGid.isIn(childGids)))
        .get();
  }

  static Future<void> upsertParentGallery(
    int childGid,
    GalleryUrl? parentGalleryUrl,
  ) {
    final String now = DateTime.now().toString();

    return appDb.into(appDb.galleryParentCache).insertOnConflictUpdate(
          GalleryParentCacheCompanion.insert(
            childGid: Value(childGid),
            parentGid: Value(parentGalleryUrl?.gid),
            parentToken: Value(parentGalleryUrl?.token),
            parentGalleryUrl: Value(parentGalleryUrl?.url),
            cacheTime: now,
          ),
        );
  }

  static Future<void> batchUpsertParentGallery(Map<int, GalleryUrl?> parentGalleryMap) {
    if (parentGalleryMap.isEmpty) {
      return Future.value();
    }

    final String now = DateTime.now().toString();

    return appDb.batch((batch) {
      for (final MapEntry<int, GalleryUrl?> entry in parentGalleryMap.entries) {
        final GalleryUrl? parentGalleryUrl = entry.value;
        batch.insert(
          appDb.galleryParentCache,
          GalleryParentCacheCompanion.insert(
            childGid: Value(entry.key),
            parentGid: Value(parentGalleryUrl?.gid),
            parentToken: Value(parentGalleryUrl?.token),
            parentGalleryUrl: Value(parentGalleryUrl?.url),
            cacheTime: now,
          ),
          onConflict: DoUpdate((_) => GalleryParentCacheCompanion(
                parentGid: Value(parentGalleryUrl?.gid),
                parentToken: Value(parentGalleryUrl?.token),
                parentGalleryUrl: Value(parentGalleryUrl?.url),
                cacheTime: Value(now),
              )),
        );
      }
    });
  }

  static Future<int> deleteAll() {
    return appDb.delete(appDb.galleryParentCache).go();
  }
}
