import 'dart:async';

import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database.dart';

class GalleryImageDao {
  static Future<List<ImageData>> selectImages() {
    return appDb.select(appDb.image).get();
  }

  static Future<List<ImageData>> selectImagesByGalleryId(int gid) {
    return (appDb.select(appDb.image)
          ..where((tbl) => tbl.gid.equals(gid))
          ..orderBy([(image) => OrderingTerm(expression: image.serialNo)]))
        .get();
  }

  static Future<int> insertImage(ImageData image) {
    return appDb.into(appDb.image).insert(image);
  }

  static Future<int> updateImage(ImageCompanion image) async {
    if (!image.gid.present || !image.serialNo.present) {
      throw ArgumentError('gid and serialNo must be provided when updating an image');
    }

    const int maxRetries = 3;
    int attempt = 0;

    while (true) {
      try {
        return await (appDb.update(appDb.image)
              ..where((tbl) =>
                  tbl.gid.equals(image.gid.value) & tbl.serialNo.equals(image.serialNo.value)))
            .write(image);
      } on SqliteException catch (e) {
        if (e.resultCode == SqlError.SQLITE_BUSY && attempt < maxRetries) {
          attempt++;
          await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
          continue;
        }
        rethrow;
      }
    }
  }

  static Future<int> resetImageUrl(int gid, int imageIndex) {
    return (appDb.update(appDb.image)
          ..where((tbl) => tbl.gid.equals(gid) & tbl.serialNo.equals(imageIndex)))
        .write(const ImageCompanion(url: Value.absent()));
  }

  static Future<int> deleteImage(int gid, int serialNo) {
    return (appDb.delete(appDb.image)
          ..where((tbl) => tbl.gid.equals(gid) & tbl.serialNo.equals(serialNo)))
        .go();
  }

  static Future<int> deleteImagesWithGid(int gid) {
    return (appDb.delete(appDb.image)..where((tbl) => tbl.gid.equals(gid))).go();
  }
}
