import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/pages/setting/adblock/advanced_qr_downloaded_filter.dart';
import 'package:jhentai/service/gallery_download_service.dart';

void main() {
  group('matchesDownloadedGalleryForAdvancedQrBlock', () {
    test('matches all selected filters across uploader and tags', () {
      final GalleryDownloadedData gallery = _gallery(
        uploader: 'qq3870990',
        tags: 'other:external ads,language:chinese',
      );

      expect(
        matchesDownloadedGalleryForAdvancedQrBlock(
          gallery,
          <String>['uploader:qq3870990', 'other:external ads'],
        ),
        isTrue,
      );
    });

    test('does not match when one selected filter is absent', () {
      final GalleryDownloadedData gallery = _gallery(
        uploader: 'qq3870990',
        tags: 'language:chinese',
      );

      expect(
        matchesDownloadedGalleryForAdvancedQrBlock(
          gallery,
          <String>['uploader:qq3870990', 'other:external ads'],
        ),
        isFalse,
      );
    });

    test('handles a single namespaced tag filter', () {
      final GalleryDownloadedData gallery = _gallery(
        tags: 'other:external ads',
      );

      expect(
        matchesDownloadedGalleryForAdvancedQrBlock(
          gallery,
          <String>['other:external ads'],
        ),
        isTrue,
      );
    });
  });

  group('filterDownloadedGalleriesForAdvancedQrBlock', () {
    test('keeps only completed downloads that match every filter', () {
      final List<GalleryDownloadedData> matches = filterDownloadedGalleriesForAdvancedQrBlock(
        <GalleryDownloadedData>[
          _gallery(gid: 1, uploader: 'qq3870990', tags: 'other:external ads'),
          _gallery(
            gid: 2,
            uploader: 'qq3870990',
            tags: 'other:external ads',
            status: DownloadStatus.downloading,
          ),
          _gallery(gid: 3, uploader: 'someone_else', tags: 'other:external ads'),
        ],
        <String>['uploader:qq3870990', 'other:external ads'],
      );

      expect(matches.map((GalleryDownloadedData gallery) => gallery.gid), <int>[1]);
    });
  });
}

GalleryDownloadedData _gallery({
  int gid = 1,
  String title = 'Downloaded gallery',
  String? uploader,
  String tags = '',
  DownloadStatus status = DownloadStatus.downloaded,
}) {
  return GalleryDownloadedData(
    gid: gid,
    token: 'token',
    title: title,
    category: 'Misc',
    pageCount: 1,
    galleryUrl: 'https://e-hentai.org/g/$gid/token/',
    uploader: uploader,
    publishTime: '2026-01-01T00:00:00Z',
    downloadStatusIndex: status.index,
    insertTime: '2026-01-01T00:00:00Z',
    downloadOriginalImage: false,
    priority: 0,
    sortOrder: 0,
    groupName: 'default',
    tags: tags,
  );
}
