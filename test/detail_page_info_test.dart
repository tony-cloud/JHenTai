import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/model/detail_page_info.dart';
import 'package:jhentai/model/gallery_thumbnail.dart';

void main() {
  group('DetailPageInfo.thumbnailsCountPerPage', () {
    test('keeps 100-thumbnail paid-user pages at the 896 boundary', () {
      final DetailPageInfo info = DetailPageInfo(
        imageNoFrom: 800,
        imageNoTo: 895,
        imageCount: 896,
        currentPageNo: 9,
        pageCount: 9,
        thumbnails: _thumbnails(96),
      );

      expect(info.thumbnailsCountPerPage, 100);
    });

    test('derives the configured count from a partial last page', () {
      final DetailPageInfo info = DetailPageInfo(
        imageNoFrom: 1000,
        imageNoTo: 1033,
        imageCount: 1034,
        currentPageNo: 26,
        pageCount: 26,
        thumbnails: _thumbnails(34),
      );

      expect(info.thumbnailsCountPerPage, 40);
    });
  });
}

List<GalleryThumbnail> _thumbnails(int count) {
  return List<GalleryThumbnail>.generate(
    count,
    (int index) => GalleryThumbnail(
      href: 'https://e-hentai.org/s/hash/$index',
      isLarge: false,
      thumbUrl: 'https://example.com/$index.jpg',
    ),
  );
}
