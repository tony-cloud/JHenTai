import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/downloaded_gallery_cleanup.dart';
import 'package:jhentai/service/downloaded_gallery_cleanup_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';

void main() {
  group('normalizeEnglishGalleryTitle', () {
    test('removes language markers while preserving other edition markers', () {
      expect(
        normalizeEnglishGalleryTitle('[Circle] Same Book [English] [Digital]'),
        '[circle] same book [digital]',
      );
      expect(
        normalizeEnglishGalleryTitle(
            '[Circle] Same Book [Chinese translated] [Digital]'),
        '[circle] same book [digital]',
      );
    });

    test('normalizes case and whitespace', () {
      expect(
        normalizeEnglishGalleryTitle('  [Circle]   SAME Book [Japanese]  '),
        '[circle] same book',
      );
    });

    test('does not remove unrelated bracketed tags', () {
      expect(
        normalizeEnglishGalleryTitle('[Circle] Same Book [Full Color]'),
        '[circle] same book [full color]',
      );
    });
  });

  test('groups only same English titles and orders newer gids first', () {
    final List<DownloadedGalleryDuplicateGroup> groups =
        groupDownloadedGalleriesByNormalizedEnglishTitle(
      <DownloadedGalleryCleanupCandidate>[
        _candidate(1, '[Circle] Same Book [English]'),
        _candidate(3, '[Circle] Same Book [Korean]'),
        _candidate(2, '[Circle] Another Book [English]'),
      ],
    );

    expect(groups, hasLength(1));
    expect(groups.single.normalizedTitle, '[circle] same book');
    expect(
      groups.single.candidates.map((candidate) => candidate.gallery.gid),
      <int>[3, 1],
    );
    expect(groups.single.candidates.first.sizeBytes, 3000);
    expect(groups.single.candidates.first.downloadedImageCount, 3);
  });
}

DownloadedGalleryCleanupCandidate _candidate(int gid, String englishTitle) {
  return DownloadedGalleryCleanupCandidate(
    gallery: GalleryDownloadedData(
      gid: gid,
      token: 'token-$gid',
      title: englishTitle,
      category: 'Manga',
      pageCount: 10,
      galleryUrl: 'https://e-hentai.org/g/$gid/token-$gid/',
      uploader: 'uploader',
      publishTime: '2026-01-01T00:00:00Z',
      downloadStatusIndex: DownloadStatus.downloaded.index,
      insertTime: '2026-01-01T00:00:00Z',
      downloadOriginalImage: false,
      priority: 0,
      sortOrder: 0,
      groupName: 'default',
      tags: 'language:english',
    ),
    englishTitle: englishTitle,
    sizeBytes: gid * 1000,
    downloadedImageCount: gid,
  );
}
