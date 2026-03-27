import 'dart:collection';

import 'package:get/get.dart';
import 'package:jhentai/pages/download/filter/download_filter.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/utils/convert_util.dart';

import 'package:jhentai/database/database.dart';

DownloadFilterService downloadFilterService = DownloadFilterService();

class DownloadFilterService extends GetxController {
  DownloadFilterService();

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

  String _stripSurroundingQuotes(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<Set<int>> _collectCandidates(
      DownloadFilter filter, List<GalleryDownloadedData> gallerys) async {
    if (gallerys.isEmpty) {
      return <int>{};
    }

    final Map<String, TagData> translatedTagMap = await _prepareTranslationMap(gallerys);
    final Set<int> matched = <int>{};
    final List<String> keywordTokens = _tokenizeKeywords(filter.keyword.trim())
        .map(_normalizeSearchToken)
        .where((token) => token.isNotEmpty)
        .toList();

    for (final GalleryDownloadedData gallery in gallerys) {
      final _SearchIndex index = _buildSearchIndex(gallery, translatedTagMap);
      if (!_matchesKeywordTokens(index, keywordTokens)) {
        continue;
      }
      if (!_matchesTagFilters(index, filter.includeTags)) {
        continue;
      }
      matched.add(gallery.gid);
    }

    return matched;
  }

  void _clearIndex() {}

  _SearchIndex _buildSearchIndex(
    GalleryDownloadedData gallery,
    Map<String, TagData> translatedTagMap,
  ) {
    final Set<String> rawTags = <String>{};
    final Set<String> translatedTags = <String>{};

    for (final TagData tag in tagDataString2TagDataList(gallery.tags)) {
      final String rawTag = '${tag.namespace}:${tag.key}'.toLowerCase();
      rawTags.add(rawTag);

      final TagData? translated = translatedTagMap['${tag.namespace}:${tag.key}'];
      translatedTags.add(
          '${translated?.translatedNamespace ?? tag.namespace}:${translated?.tagName ?? tag.key}'
              .toLowerCase());
    }

    final String uploader = (gallery.uploader ?? '').trim().toLowerCase();

    final String searchText = [
      gallery.title,
      gallery.uploader ?? '',
      rawTags.join(' '),
      translatedTags.join(' '),
    ].join(' ').toLowerCase();

    return _SearchIndex(
      searchText: searchText,
      uploader: uploader,
      rawTags: rawTags,
      translatedTags: translatedTags,
    );
  }

  bool _matchesKeywordTokens(_SearchIndex index, List<String> tokens) {
    for (final String token in tokens) {
      if (!index.searchText.contains(token)) {
        return false;
      }
    }

    return true;
  }

  bool _matchesTagFilters(_SearchIndex index, Iterable<String> includeTags) {
    for (final String rawTag in includeTags) {
      String tag = rawTag.trim();
      if (tag.isEmpty) {
        continue;
      }

      bool negative = false;
      if (tag.startsWith('-')) {
        negative = true;
        tag = tag.substring(1).trimLeft();
      } else if (tag.startsWith('~')) {
        tag = tag.substring(1).trimLeft();
      }

      if (tag.isEmpty) {
        continue;
      }

      bool hit = false;
      final int colonIndex = tag.indexOf(':');
      if (colonIndex > 0) {
        final String namespace = tag.substring(0, colonIndex).trim().toLowerCase();
        final String key = _normalizeSearchToken(tag.substring(colonIndex + 1));

        if (namespace == 'uploader') {
          hit = key.isNotEmpty && index.uploader.contains(key);
        } else {
          final String namespaced = '$namespace:$key';
          hit = index.rawTags.contains(namespaced) ||
              index.translatedTags.contains(namespaced) ||
              index.searchText.contains(namespaced);
        }
      } else {
        final String token = _normalizeSearchToken(tag);
        hit = token.isNotEmpty && index.searchText.contains(token);
      }

      if (negative && hit) {
        return false;
      }
      if (!negative && !hit) {
        return false;
      }
    }

    return true;
  }

  String _normalizeSearchToken(String token) {
    String value = token.trim().toLowerCase();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
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

  List<String> _tokenizeKeywords(String text) {
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

class _SearchIndex {
  const _SearchIndex({
    required this.searchText,
    required this.uploader,
    required this.rawTags,
    required this.translatedTags,
  });

  final String searchText;
  final String uploader;
  final Set<String> rawTags;
  final Set<String> translatedTags;
}
