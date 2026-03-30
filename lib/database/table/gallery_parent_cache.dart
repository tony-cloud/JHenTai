import 'package:drift/drift.dart';

@TableIndex(name: 'gpc_idx_cache_time', columns: {#cacheTime})
class GalleryParentCache extends Table {
  @override
  String? get tableName => 'gallery_parent_cache';

  IntColumn get childGid => integer()();

  IntColumn get parentGid => integer().nullable()();

  TextColumn get parentToken => text().nullable()();

  TextColumn get parentGalleryUrl => text().nullable()();

  TextColumn get cacheTime => text()();

  @override
  Set<Column<Object>>? get primaryKey => {childGid};
}
