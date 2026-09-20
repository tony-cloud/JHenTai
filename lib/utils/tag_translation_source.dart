import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html;

typedef TranslationFetch = Future<List<int>> Function(String url);

class TagTranslationSource {
  static const releaseUrl =
      'https://api.github.com/repos/EhTagTranslation/Database/releases/latest';
  static const fallbackUrls = [
    'https://raw.githubusercontent.com/EhTagTranslation/DatabaseReleases/master/db.html.json',
    'https://fastly.jsdelivr.net/gh/EhTagTranslation/DatabaseReleases@master/db.html.json',
  ];

  /// Select by format rather than pinning one release filename. HTML retains
  /// descriptions/links; text JSON is usable when no HTML asset is published.
  static List<String> releaseAssetUrls(dynamic release) {
    if (release is! Map || release['assets'] is! List) {
      return [];
    }
    final assets = (release['assets'] as List).whereType<Map>().where((asset) {
      final String name = '${asset['name']}'.toLowerCase();
      final Uri? uri = Uri.tryParse('${asset['browser_download_url']}');
      return RegExp(r'(^|[._-])(html|text)([._-].*)?\.json(\.gz)?$').hasMatch(name) &&
          uri?.scheme == 'https' &&
          uri?.host == 'github.com';
    }).toList();
    int rank(Map asset) {
      final String name = '${asset['name']}'.toLowerCase();
      return (name.contains('html') ? 0 : 2) + (name.endsWith('.gz') ? 0 : 1);
    }

    assets.sort((a, b) => rank(a).compareTo(rank(b)));
    return assets.map((asset) => asset['browser_download_url'] as String).toList();
  }

  static Future<TranslationDatabase> fetch(TranslationFetch fetchBytes) async {
    final List<String> urls = [];
    try {
      urls.addAll(releaseAssetUrls(jsonDecode(utf8.decode(await fetchBytes(releaseUrl)))));
    } catch (_) {
      // GitHub API outages/rate limits must not block mirror downloads.
    }
    urls.addAll(fallbackUrls);
    Object? lastError;
    for (final String url in urls.toSet()) {
      try {
        return decode(await fetchBytes(url));
      } catch (error) {
        lastError = error;
      }
    }
    throw FormatException('No usable tag translation database: $lastError');
  }

  static TranslationDatabase decode(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = gzip.decode(bytes);
    }
    final dynamic data = jsonDecode(utf8.decode(bytes));
    if (data is! Map || data['head'] is! Map || data['data'] is! List) {
      throw const FormatException('Invalid tag translation database');
    }
    final dynamic committer = data['head']['committer'];
    if (committer is! Map || committer['when'] is! String) {
      throw const FormatException('Missing translation timestamp');
    }
    final List<TranslationTag> tags = [];
    for (final dynamic namespace in data['data']) {
      if (namespace is! Map ||
          namespace['namespace'] is! String ||
          namespace['data'] is! Map) {
        throw const FormatException('Invalid translation namespace');
      }
      for (final entry in (namespace['data'] as Map).entries) {
        final dynamic tag = entry.value;
        if (entry.key is! String || tag is! Map || tag['name'] is! String) {
          throw const FormatException('Invalid translation tag');
        }
        final String name = tag['name'];
        tags.add(TranslationTag(
            namespace['namespace'],
            entry.key,
            html.parseFragment(name).text ?? name,
            name,
            tag['intro'] as String? ?? '',
            tag['links'] as String? ?? ''));
      }
    }
    if (tags.isEmpty) {
      throw const FormatException('Empty tag translation database');
    }
    return TranslationDatabase(committer['when'], tags);
  }
}

class TranslationDatabase {
  final String timestamp;
  final List<TranslationTag> tags;
  const TranslationDatabase(this.timestamp, this.tags);
}

class TranslationTag {
  final String namespace, key, name, fullName, intro, links;
  const TranslationTag(
      this.namespace, this.key, this.name, this.fullName, this.intro, this.links);
}
