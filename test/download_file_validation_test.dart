import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/utils/download_file_validation.dart';

void main() {
  test('rejects a non-empty file shorter than the response content length',
      () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('jhentai-download-validation-');
    addTearDown(() => tempDir.delete(recursive: true));
    final File file = File('${tempDir.path}/image.jpg');
    await file.writeAsBytes(<int>[1, 2, 3]);

    final DownloadFileValidationResult result = await validateDownloadedFile(
      file,
      expectedBytes: 5,
    );

    expect(result.isValid, isFalse);
    expect(result.actualBytes, 3);
    expect(result.expectedBytes, 5);
  });

  test('accepts a non-empty file with the complete response length', () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('jhentai-download-validation-');
    addTearDown(() => tempDir.delete(recursive: true));
    final File file = File('${tempDir.path}/image.jpg');
    await file.writeAsBytes(<int>[1, 2, 3]);

    final DownloadFileValidationResult result = await validateDownloadedFile(
      file,
      expectedBytes: 3,
    );

    expect(result.isValid, isTrue);
  });

  test('detects ENOSPC wrapped by DioException', () {
    final FileSystemException fileError = FileSystemException(
      'write failed',
      '/downloads/image.jpg',
      const OSError('No space left on device', 28),
    );
    final DioException dioError = DioException(
      requestOptions: RequestOptions(path: 'https://example.test/image.jpg'),
      error: fileError,
    );

    expect(isStorageWriteFailure(dioError), isTrue);
    expect(isNoSpaceLeftOnDevice(dioError), isTrue);
  });

  test('does not enforce compressed response content length', () {
    final Headers headers = Headers.fromMap(<String, List<String>>{
      Headers.contentLengthHeader: <String>['100'],
      Headers.contentEncodingHeader: <String>['gzip'],
    });

    expect(expectedDownloadedFileLength(headers), isNull);
  });

  test('uses uncompressed response content length for commit validation', () {
    final Headers headers = Headers.fromMap(<String, List<String>>{
      Headers.contentLengthHeader: <String>['100'],
    });

    expect(expectedDownloadedFileLength(headers), 100);
  });
}
