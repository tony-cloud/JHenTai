import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';

typedef TagCountEntry = ({String tag, int count});

class TagCountRelease {
  final String version;
  final List<String> assetUrls;

  const TagCountRelease(this.version, this.assetUrls);
}

class TagCountSource {
  static const releaseUrl =
      'https://api.github.com/repos/mokurin000/e-hentai-tag-count/releases/latest';

  static TagCountRelease parseRelease(List<int> bytes) {
    final dynamic release = jsonDecode(utf8.decode(bytes));
    if (release is! Map || release['tag_name'] is! String || release['assets'] is! List) {
      throw const FormatException('Invalid tag count release');
    }
    final assets = (release['assets'] as List).whereType<Map>().where((asset) {
      final name = '${asset['name']}'.toLowerCase();
      final uri = Uri.tryParse('${asset['browser_download_url']}');
      return name.contains('tag') &&
          name.contains('count') &&
          RegExp(r'\.csv(\.gz)?$').hasMatch(name) &&
          uri?.scheme == 'https' &&
          uri?.host == 'github.com';
    }).toList();
    int rank(Map asset) => '${asset['name']}'.contains('tagname_count') ? 0 : 1;
    assets.sort((a, b) => rank(a).compareTo(rank(b)));
    if (assets.isEmpty) {
      throw const FormatException('No tag count CSV in release');
    }
    return TagCountRelease(release['tag_name'],
        assets.map((asset) => asset['browser_download_url'] as String).toList());
  }

  static List<TagCountEntry> decode(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = gzip.decode(bytes);
    }
    final rows =
        const CsvToListConverter(eol: '\n', allowInvalid: false, shouldParseNumbers: false)
            .convert(utf8.decode(bytes).replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n'))
            .where((row) => row.any((value) => value.toString().trim().isNotEmpty))
            .toList();
    if (rows.isEmpty) {
      throw const FormatException('Empty tag count CSV');
    }
    final header = rows.first.map((value) => value.toString().trim().toLowerCase()).toList();
    int tagIndex = header.indexOf('tag_name');
    int countIndex = header.indexOf('len');
    int firstDataRow = 1;
    if (tagIndex < 0 || countIndex < 0) {
      // Older releases contain tid,count,tag, sometimes without a header.
      tagIndex = 2;
      countIndex = 1;
      if (header.length != 3) {
        throw const FormatException('Unknown tag count CSV columns');
      }
      if (int.tryParse(header[0]) != null && int.tryParse(header[1]) != null) {
        firstDataRow = 0;
      } else if (header[1] != 'count' || !['tag', 'tag_name'].contains(header[2])) {
        throw const FormatException('Unknown tag count CSV header');
      }
    }
    final result = <TagCountEntry>[];
    final seen = <String>{};
    for (final row in rows.skip(firstDataRow)) {
      if (row.length != header.length) {
        throw const FormatException('Invalid tag count CSV row');
      }
      final tag = row[tagIndex].toString().trim();
      final count = int.tryParse(row[countIndex].toString());
      if (count == null || count < 0) {
        throw const FormatException('Invalid tag count');
      }
      // The upstream export includes an unnamed tag; it cannot be searched.
      if (tag.isEmpty) {
        continue;
      }
      if (!seen.add(tag)) {
        throw const FormatException('Invalid or duplicate tag count');
      }
      if (count >= 5) {
        result.add((tag: tag, count: count));
      }
    }
    if (result.isEmpty) {
      throw const FormatException('No usable tag counts');
    }
    return result;
  }
}
