import 'package:jhentai/database/database.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/utils/convert_util.dart';

List<GalleryDownloadedData> filterDownloadedGalleriesForAdvancedQrBlock(
  Iterable<GalleryDownloadedData> galleries,
  Iterable<String> filters,
) {
  return galleries
      .where(
        (GalleryDownloadedData gallery) =>
            gallery.downloadStatusIndex == DownloadStatus.downloaded.index,
      )
      .where(
        (GalleryDownloadedData gallery) =>
            matchesDownloadedGalleryForAdvancedQrBlock(gallery, filters),
      )
      .toList();
}

bool matchesDownloadedGalleryForAdvancedQrBlock(
  GalleryDownloadedData gallery,
  Iterable<String> filters,
) {
  final _AdvancedQrDownloadedGalleryIndex index =
      _AdvancedQrDownloadedGalleryIndex.fromGallery(gallery);
  bool hasFilter = false;

  for (final String rawFilter in filters) {
    final _AdvancedQrDownloadedFilter? filter = _AdvancedQrDownloadedFilter.parse(rawFilter);
    if (filter == null) {
      continue;
    }

    hasFilter = true;
    final bool hit = filter.matches(index);
    if (filter.negative) {
      if (hit) {
        return false;
      }
      continue;
    }
    if (!hit) {
      return false;
    }
  }

  return hasFilter;
}

class _AdvancedQrDownloadedFilter {
  const _AdvancedQrDownloadedFilter({
    required this.negative,
    required this.value,
    this.namespace,
  });

  final bool negative;
  final String? namespace;
  final String value;

  static _AdvancedQrDownloadedFilter? parse(String rawFilter) {
    String filter = rawFilter.trim();
    if (filter.isEmpty) {
      return null;
    }

    bool negative = false;
    if (filter.startsWith('-') || filter.startsWith('~')) {
      negative = filter.startsWith('-');
      filter = filter.substring(1).trimLeft();
    }

    if (filter.isEmpty) {
      return null;
    }

    final int colonIndex = filter.indexOf(':');
    if (colonIndex > 0 && colonIndex < filter.length - 1) {
      final String namespace = _normalizeFilterValue(
        filter.substring(0, colonIndex),
      );
      final String value = _normalizeFilterValue(
        filter.substring(colonIndex + 1),
      );
      if (namespace.isEmpty || value.isEmpty) {
        return null;
      }
      return _AdvancedQrDownloadedFilter(
        negative: negative,
        namespace: namespace,
        value: value,
      );
    }

    final String value = _normalizeFilterValue(filter);
    if (value.isEmpty) {
      return null;
    }
    return _AdvancedQrDownloadedFilter(negative: negative, value: value);
  }

  bool matches(_AdvancedQrDownloadedGalleryIndex index) {
    final String? filterNamespace = namespace;
    if (filterNamespace == null) {
      return index.searchText.contains(value);
    }

    if (filterNamespace == 'uploader') {
      return index.uploader.contains(value);
    }

    final String namespaced = '$filterNamespace:$value';
    return index.rawTags.contains(namespaced) || index.searchText.contains(namespaced);
  }
}

class _AdvancedQrDownloadedGalleryIndex {
  const _AdvancedQrDownloadedGalleryIndex({
    required this.searchText,
    required this.uploader,
    required this.rawTags,
  });

  final String searchText;
  final String uploader;
  final Set<String> rawTags;

  factory _AdvancedQrDownloadedGalleryIndex.fromGallery(
    GalleryDownloadedData gallery,
  ) {
    final Set<String> rawTags = <String>{};
    for (final TagData tag in tagDataString2TagDataList(gallery.tags)) {
      final String namespace = tag.namespace.trim().toLowerCase();
      final String key = tag.key.trim().toLowerCase();
      if (namespace.isEmpty || key.isEmpty) {
        continue;
      }
      rawTags.add('$namespace:$key');
    }

    final String uploader = (gallery.uploader ?? '').trim().toLowerCase();
    final String searchText = <String>[
      gallery.title,
      uploader,
      rawTags.join(' '),
    ].join(' ').toLowerCase();

    return _AdvancedQrDownloadedGalleryIndex(
      searchText: searchText,
      uploader: uploader,
      rawTags: rawTags,
    );
  }
}

String _normalizeFilterValue(String value) {
  String normalized = value.trim().toLowerCase();
  if (normalized.length >= 2 && normalized.startsWith('"') && normalized.endsWith('"')) {
    normalized = normalized.substring(1, normalized.length - 1).trim();
  }
  return normalized;
}
