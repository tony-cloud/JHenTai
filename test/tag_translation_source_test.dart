import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/utils/tag_translation_source.dart';

Map<String, Object> payload({String name = '<span>翻译 &amp; 标签</span>'}) => {
      'head': {
        'committer': {'when': '2026-09-21T00:00:00Z'}
      },
      'data': [
        {
          'namespace': 'female',
          'data': {
            'sample': {'name': name, 'intro': 'description', 'links': ''}
          }
        }
      ],
    };

void main() {
  test('discovers renamed HTML assets and prefers gzip', () {
    final urls = TagTranslationSource.releaseAssetUrls({
      'assets': [
        {'name': 'db.raw.json', 'browser_download_url': 'https://github.com/example/raw'},
        {'name': 'db.html.js', 'browser_download_url': 'https://github.com/example/script'},
        {'name': 'db.html.v2.json', 'browser_download_url': 'https://github.com/example/json'},
        {
          'name': 'db-2026.html.json.gz',
          'browser_download_url': 'https://github.com/example/gzip'
        },
        {'name': 'db.text.json', 'browser_download_url': 'https://github.com/example/text'},
      ]
    });
    expect(urls, [
      'https://github.com/example/gzip',
      'https://github.com/example/json',
      'https://github.com/example/text'
    ]);
  });

  test('decodes gzip and extracts HTML entities or plain names', () {
    final database =
        TagTranslationSource.decode(gzip.encode(utf8.encode(jsonEncode(payload()))));
    expect(database.timestamp, '2026-09-21T00:00:00Z');
    expect(database.tags.single.name, '翻译 & 标签');
    final plain = TagTranslationSource.decode(utf8.encode(jsonEncode(payload(name: '纯文本'))));
    expect(plain.tags.single.name, '纯文本');
  });

  test('API failures fall back to mirrors and reject bad payloads', () async {
    final calls = <String>[];
    final database = await TagTranslationSource.fetch((url) async {
      calls.add(url);
      if (url == TagTranslationSource.releaseUrl) {
        throw const HttpException('rate limited');
      }
      if (url == TagTranslationSource.fallbackUrls.first) {
        return utf8.encode('<html>unavailable</html>');
      }
      return utf8.encode(jsonEncode(payload()));
    });
    expect(calls, [TagTranslationSource.releaseUrl, ...TagTranslationSource.fallbackUrls]);
    expect(database.tags.single.key, 'sample');
  });

  test('release asset succeeds without fetching any mirror', () async {
    const url =
        'https://github.com/EhTagTranslation/Database/releases/download/v1/db.html.v1.json.gz';
    final calls = <String>[];
    final database = await TagTranslationSource.fetch((requested) async {
      calls.add(requested);
      if (requested == TagTranslationSource.releaseUrl) {
        return utf8.encode(jsonEncode({
          'assets': [
            {'name': 'db.html.v1.json.gz', 'browser_download_url': url}
          ]
        }));
      }
      return gzip.encode(utf8.encode(jsonEncode(payload())));
    });
    expect(calls, [TagTranslationSource.releaseUrl, url]);
    expect(database.tags, hasLength(1));
  });

  test('empty or malformed databases cannot replace the old tags', () {
    for (final value in [
      <String, Object>{},
      {
        'head': {
          'committer': {'when': 'today'}
        },
        'data': []
      },
      {'head': {}, 'data': []}
    ]) {
      expect(() => TagTranslationSource.decode(utf8.encode(jsonEncode(value))),
          throwsFormatException);
    }
  });
}
