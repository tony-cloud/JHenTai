import 'dart:collection';

import 'package:get/get.dart';
import 'package:jhentai/pages/download/filter/download_filter.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_simple/sqlite3_simple.dart';

import '../database/database.dart';

DownloadFilterService downloadFilterService = DownloadFilterService();

class DownloadFilterService extends GetxController {
  DownloadFilterService() {
    _ensureExtensionLoaded();
    _db = sqlite3.openInMemory();
    _createSchema();
  }

  late final Database _db;

  DownloadFilter _currentFilter = const DownloadFilter();

  Set<int>? _candidateGids;
  int? _lastIndexedFingerprint;
  Future<void>? _pendingRefresh;

  bool get hasActiveFilter => !_currentFilter.isDefault;

  DownloadFilter get currentFilter => _currentFilter;

  Future<void> applyFilter(DownloadFilter filter) async {
    _currentFilter = filter;
    _pendingRefresh = null;
    if (!filter.hasTextQuery) {
      _candidateGids = null;
      _lastIndexedFingerprint = null;
      _clearIndex();
      update();
      return;
    }

    final List<GalleryDownloadedData> gallerys =
        List<GalleryDownloadedData>.from(galleryDownloadService.gallerys);
    final int fingerprint = _buildFingerprint(gallerys);
    final Set<int> matched = await _collectCandidates(filter, gallerys);
    if (_currentFilter != filter) {
      return;
    }
    _candidateGids = matched;
    _lastIndexedFingerprint = fingerprint;
    update();
  }

  void refreshIndexIfNeeded() {
    if (!_currentFilter.hasTextQuery) {
      return;
    }
    final List<GalleryDownloadedData> gallerys =
        List<GalleryDownloadedData>.from(galleryDownloadService.gallerys);
    final int fingerprint = _buildFingerprint(gallerys);
    if (_lastIndexedFingerprint == fingerprint || _pendingRefresh != null) {
      return;
    }

    final DownloadFilter snapshot = _currentFilter;
    _pendingRefresh = _rebuildCandidates(gallerys, fingerprint, snapshot);
  }

  Future<void> _rebuildCandidates(
    List<GalleryDownloadedData> gallerys,
    int fingerprint,
    DownloadFilter snapshot,
  ) async {
    try {
      final Set<int> matched = await _collectCandidates(snapshot, gallerys);
      if (_currentFilter != snapshot) {
        return;
      }
      _candidateGids = matched;
      _lastIndexedFingerprint = fingerprint;
      update();
    } finally {
      _pendingRefresh = null;
    }
  }

  List<GalleryDownloadedData> filterGalleries(List<GalleryDownloadedData> sources) {
    if (!hasActiveFilter) {
      return sources;
    }

    final List<GalleryDownloadedData> results = [];
    final Set<int>? candidates = _candidateGids;
    final Set<String> selectedGroups = _currentFilter.selectedGroups;

    for (final GalleryDownloadedData gallery in sources) {
      final GalleryDownloadInfo? info = galleryDownloadService.galleryDownloadInfos[gallery.gid];
      if (info == null) {
        continue;
      }

      if (candidates != null && !candidates.contains(gallery.gid)) {
        continue;
      }

      if (selectedGroups.isNotEmpty && !selectedGroups.contains(info.group)) {
        continue;
      }

      final DownloadStatus status = info.downloadProgress.downloadStatus;
      if (_currentFilter.completion == DownloadCompletionFilter.finished &&
          status != DownloadStatus.downloaded) {
        continue;
      }
      if (_currentFilter.completion == DownloadCompletionFilter.unfinished &&
          status == DownloadStatus.downloaded) {
        continue;
      }

      results.add(gallery);
    }

    return results;
  }

  Set<String> visibleGroups(Iterable<GalleryDownloadedData> gallerys) {
    final Set<String> groups = <String>{};
    for (final GalleryDownloadedData gallery in gallerys) {
      final GalleryDownloadInfo? info = galleryDownloadService.galleryDownloadInfos[gallery.gid];
      if (info != null) {
        groups.add(info.group);
      }
    }
    return groups;
  }

  void reset() {
    _currentFilter = const DownloadFilter();
    _candidateGids = null;
    _lastIndexedFingerprint = null;
    _pendingRefresh = null;
    _clearIndex();
    update();
  }

  @override
  void onClose() {
    _db.dispose();
    super.onClose();
  }

  static bool _extensionLoaded = false;

  void _ensureExtensionLoaded() {
    if (_extensionLoaded) {
      return;
    }
    sqlite3.loadSimpleExtension();
    _extensionLoaded = true;
  }

  void _createSchema() {
    _db.execute('DROP TABLE IF EXISTS download_index');
    _db.execute(
        'CREATE VIRTUAL TABLE download_index USING fts5(title, uploader, raw_tags, translated_tags, tokenize = "simple")');
  }

  Future<Set<int>> _collectCandidates(
      DownloadFilter filter, List<GalleryDownloadedData> gallerys) async {
    _clearIndex();

    if (gallerys.isEmpty) {
      return <int>{};
    }

    final Map<String, TagData> translatedTagMap = await _prepareTranslationMap(gallerys);

    final PreparedStatement insertStmt = _db.prepare(
      'INSERT INTO download_index(rowid, title, uploader, raw_tags, translated_tags) VALUES (?, ?, ?, ?, ?)',
    );

    for (final GalleryDownloadedData gallery in gallerys) {
      final List<TagData> tags = tagDataString2TagDataList(gallery.tags);
      final List<String> rawTags = <String>[];
      final List<String> translatedTags = <String>[];

      for (final TagData tag in tags) {
        final String key = '${tag.namespace}:${tag.key}';
        rawTags.add(key);
        final TagData? translated = translatedTagMap[key];
        translatedTags.add(
          '${translated?.translatedNamespace ?? tag.namespace}:${translated?.tagName ?? tag.key}',
        );
      }

      insertStmt.execute([
        gallery.gid,
        gallery.title,
        gallery.uploader ?? '',
        rawTags.join(' '),
        translatedTags.join(' '),
      ]);
    }

    insertStmt.dispose();

    final String query = _buildMatchQuery(filter);
    if (query.isEmpty) {
      return gallerys.map((GalleryDownloadedData gallery) => gallery.gid).toSet();
    }
    final PreparedStatement selectStmt = _db.prepare(
      'SELECT rowid FROM download_index WHERE download_index MATCH simple_query(?)',
    );
    final ResultSet resultSet = selectStmt.select([query]);

    final Set<int> matched = <int>{};
    for (final Row row in resultSet) {
      matched.add(row['rowid'] as int);
    }

    selectStmt.dispose();

    return matched;
  }

  void _clearIndex() {
    _db.execute('DELETE FROM download_index');
  }

  Future<Map<String, TagData>> _prepareTranslationMap(List<GalleryDownloadedData> gallerys) async {
    if (tagTranslationService.isReady == false) {
      return <String, TagData>{};
    }

    final LinkedHashMap<String, TagData> uniqueTags = LinkedHashMap<String, TagData>();
    for (final GalleryDownloadedData gallery in gallerys) {
      for (final TagData tag in tagDataString2TagDataList(gallery.tags)) {
        uniqueTags.putIfAbsent('${tag.namespace}:${tag.key}', () => tag);
      }
    }

    if (uniqueTags.isEmpty) {
      return <String, TagData>{};
    }

    final List<TagData> translated =
        await tagTranslationService.translateTagDatasIfNeeded(uniqueTags.values.toList());

    final Map<String, TagData> map = <String, TagData>{};
    for (final TagData tag in translated) {
      map['${tag.namespace}:${tag.key}'] = tag;
    }

    return map;
  }

  String _buildMatchQuery(DownloadFilter filter) {
    final List<String> tokens = <String>[];

    if (filter.keyword.trim().isNotEmpty) {
      tokens.addAll(_tokenize(filter.keyword.trim()));
    }

    for (final String tag in filter.includeTags) {
      final String trimmed = tag.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      tokens.addAll(_tokenize(trimmed));
    }

    if (tokens.isEmpty) {
      return '';
    }

    // The simple_query() helper already combines terms with AND semantics, so we
    // only need to provide the raw tokens separated by whitespace. Supplying
    // explicit AND operators breaks matching when multiple tags are present.
    return tokens.join(' ');
  }

  List<String> _tokenize(String text) {
    return text.split(RegExp(r'\s+')).where((String token) => token.isNotEmpty).toList();
  }

  int _buildFingerprint(List<GalleryDownloadedData> gallerys) {
    int hash = gallerys.length;
    for (final GalleryDownloadedData gallery in gallerys) {
      hash = 0x1fffffff & (hash + gallery.gid.hashCode);
      hash = 0x1fffffff & (hash + gallery.title.hashCode);
      hash = 0x1fffffff & (hash + (gallery.uploader?.hashCode ?? 0));
      hash = 0x1fffffff & (hash + gallery.tags.hashCode);
      hash = 0x1fffffff & (hash + gallery.downloadStatusIndex.hashCode);
    }
    return hash;
  }
}
