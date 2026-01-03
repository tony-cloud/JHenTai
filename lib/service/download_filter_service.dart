import 'dart:collection';

import 'package:get/get.dart';
import 'package:jhentai/pages/download/filter/download_filter.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_simple/sqlite3_simple.dart';

import 'package:jhentai/database/database.dart';

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

  Future<List<TagAutoCompletionMatch>> buildUploaderSuggestions(String rawQuery) async {
    String searchTerm = rawQuery.trim();
    if (searchTerm.isEmpty) {
      return <TagAutoCompletionMatch>[];
    }

    String? operator;
    if (searchTerm.startsWith('-') || searchTerm.startsWith('~')) {
      operator = searchTerm[0];
      searchTerm = searchTerm.substring(1).trimLeft();
    }

    String keyword = searchTerm;

    final int colonIndex = searchTerm.indexOf(':');
    if (colonIndex != -1) {
      final String namespace = searchTerm.substring(0, colonIndex).trim();
      if (namespace.isNotEmpty && namespace.toLowerCase() != 'uploader') {
        return <TagAutoCompletionMatch>[];
      }
      keyword = searchTerm.substring(colonIndex + 1).trimLeft();
    }

    keyword = _stripSurroundingQuotes(keyword);

    final Set<String> uploaders = <String>{};
    for (final GalleryDownloadedData gallery in galleryDownloadService.gallerys) {
      final String? uploader = gallery.uploader;
      if (uploader != null && uploader.isNotEmpty) {
        uploaders.add(uploader);
      }
    }

    if (uploaders.isEmpty) {
      return <TagAutoCompletionMatch>[];
    }

    final String lowerKeyword = keyword.toLowerCase();
    final Iterable<String> matchedUploaders = keyword.isEmpty
        ? uploaders
        : uploaders.where((String uploader) => uploader.toLowerCase().contains(lowerKeyword));

    final int matchStart = rawQuery.length - searchTerm.length;

    return matchedUploaders.take(50).map((String uploader) {
      final int keyMatchStart =
          lowerKeyword.isEmpty ? 0 : uploader.toLowerCase().indexOf(lowerKeyword);
      final ({int start, int end})? keyMatch =
          keyMatchStart == -1 ? null : (start: keyMatchStart, end: keyMatchStart + keyword.length);

      return (
        searchText: rawQuery,
        matchStart: matchStart,
        matchEnd: rawQuery.length,
        tagData: TagData(namespace: 'uploader', key: uploader),
        operator: operator,
        namespaceMatch: null,
        translatedNamespaceMatch: null,
        keyMatch: keyMatch,
        tagNameMatch: null,
        score: 0.0,
      );
    }).toList();
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

  String _stripSurroundingQuotes(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
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

      final String? uploader = gallery.uploader?.trim();
      if (uploader != null && uploader.isNotEmpty) {
        rawTags.addAll(<String>['uploader:$uploader', uploader]);
        translatedTags.addAll(<String>['uploader:$uploader', uploader]);
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
      tokens.addAll(_tokenizeKeywords(filter.keyword.trim()));
    }

    for (final String tag in filter.includeTags) {
      tokens.addAll(_buildTagTokens(tag));
    }

    if (tokens.isEmpty) {
      return '';
    }

    // The simple_query() helper already combines terms with AND semantics, so we
    // only need to provide the raw tokens separated by whitespace. Supplying
    // explicit AND operators breaks matching when multiple tags are present.
    return tokens.join(' ');
  }

  List<String> _tokenizeKeywords(String text) {
    return text.split(RegExp(r'\s+')).where((String token) => token.isNotEmpty).toList();
  }

  List<String> _buildTagTokens(String raw) {
    String text = raw.trim();
    if (text.isEmpty) {
      return const <String>[];
    }

    String prefix = '';
    if (text.startsWith('-') || text.startsWith('~')) {
      prefix = text[0];
      text = text.substring(1).trimLeft();
      if (text.isEmpty) {
        return const <String>[];
      }
    }

    final int colonIndex = text.indexOf(':');
    if (colonIndex > 0) {
      final String namespace = text.substring(0, colonIndex).trim();
      final String value = text.substring(colonIndex + 1).trim();
      final String normalizedValue = _normalizeTagValue(value);

      if (namespace.toLowerCase() == 'uploader') {
        // Prefer column-scoped query, but also add a plain token fallback to
        // match when the simple_query helper ignores column syntax.
        return <String>[
          '$prefix$namespace:$normalizedValue',
          if (normalizedValue.isNotEmpty) '$prefix$normalizedValue',
        ];
      }

      return <String>['$prefix$namespace:$normalizedValue'];
    }

    return <String>['$prefix${_normalizeQueryValue(text)}'];
  }

  String _normalizeTagValue(String value) {
    String trimmed = value.trim();
    if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
      trimmed = trimmed.substring(1, trimmed.length - 1);
    }
    return _escapeQuotes(trimmed);
  }

  String _normalizeQueryValue(String value) {
    String trimmed = value.trim();
    if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
      trimmed = trimmed.substring(1, trimmed.length - 1);
    }
    return _quoteIfNeeded(trimmed);
  }

  String _quoteIfNeeded(String value) {
    if (value.isEmpty) {
      return '""';
    }

    final String escaped = _escapeQuotes(value);
    if (escaped.contains(RegExp(r'\s')) || escaped != value) {
      return '"$escaped"';
    }

    return escaped;
  }

  String _escapeQuotes(String value) {
    return value.replaceAll('"', '""');
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
