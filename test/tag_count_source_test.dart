import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/utils/tag_count_source.dart';

void main() {
  test('discovers renamed CSV assets from the latest release', () {
    final release = TagCountSource.parseRelease(utf8.encode(jsonEncode({
      'tag_name': 'v2026.09.20',
      'assets': [
        {'name': 'readme.txt', 'browser_download_url': 'https://github.com/readme.txt'},
        {'name': 'tag-count-v2.csv.gz', 'browser_download_url': 'https://github.com/count.gz'},
      ],
    })));
    expect(release.version, 'v2026.09.20');
    expect(release.assetUrls, ['https://github.com/count.gz']);
  });

  test('reads current headered gzip CSV and filters low counts', () {
    final entries = TagCountSource.decode(gzip
        .encode(utf8.encode('tag_name,len\ngroup:anime tec,1\ncharacter:coco bandicoot,1171\n'
            'artist:someone,5\n,11\n001,9\n')));
    expect(entries, [
      (tag: 'character:coco bandicoot', count: 1171),
      (tag: 'artist:someone', count: 5),
      (tag: '001', count: 9),
    ]);
  });

  test('reads legacy headered and headerless CSV without changing tag punctuation', () {
    for (final header in ['', 'tid,count,tag\r\n']) {
      expect(
          TagCountSource.decode(utf8.encode('${header}1,123,"artist:one, two"\r\n'
              '2,9,"group:someone\'s group"\r\n')),
          [
            (tag: 'artist:one, two', count: 123),
            (tag: "group:someone's group", count: 9),
          ]);
    }
  });

  test('rejects broken payloads before database replacement', () {
    for (final csv in [
      '<html>error</html>',
      'tag_name,len\n',
      'tag_name,len\nartist:test,NaN\n',
      'tag_name,len\nartist:test,5\nartist:test,6\n',
      'tag_name,len\nartist:test,5,extra\n',
    ]) {
      expect(() => TagCountSource.decode(utf8.encode(csv)), throwsFormatException);
    }
  });
}
