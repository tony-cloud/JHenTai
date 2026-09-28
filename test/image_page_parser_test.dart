import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/consts/eh_consts.dart';
import 'package:jhentai/exception/eh_parse_exception.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

void main() {
  final invalidPage = isA<EHParseException>()
      .having((e) => e.type.name, 'type', 'invalidImagePage')
      .having((e) => e.message, 'message', 'parsePageFailed')
      .having((e) => e.shouldPauseAllDownloadTasks, 'pauses other galleries',
          false);

  for (final response in <Object>[
    {'error': 'Key expired'},
    '{"error":"Key expired"}',
    '<html>Temporary server error</html>',
    '<div id="pane_images"></div>',
    '<img id="img">',
  ]) {
    test('missing image is a recoverable parse failure: $response', () {
      expect(() => EHSpiderParser.imagePage2GalleryImage(Headers(), response),
          throwsA(invalidPage));
      expect(
          () => EHSpiderParser.imagePage2OriginalGalleryImage(
              Headers(), response),
          throwsA(invalidPage));
    });
  }

  test('malformed MPV imagelist enters the same recovery path', () {
    expect(
      () => EHSpiderParser.mpvPage2MpvKeyAndImageKeys(
          Headers(), 'var mpvkey = "key"; var imagelist = [{broken}];'),
      throwsA(invalidPage),
    );
  });

  test('normal HTML images and image-limit errors keep their behavior', () {
    final image = EHSpiderParser.imagePage2GalleryImage(
        Headers(), '<img id="img" src="https://example.test/image.jpg">');
    expect(image.url, 'https://example.test/image.jpg');
    expect(
      () => EHSpiderParser.imagePage2GalleryImage(
          Headers(), '<img id="img" src="${EHConsts.EH509ImageUrl}">'),
      throwsA(isA<EHParseException>()
          .having((e) => e.type, 'type', EHParseExceptionType.exceedLimit)
          .having((e) => e.shouldPauseAllDownloadTasks, 'pauses all galleries',
              true)),
    );
  });
}
