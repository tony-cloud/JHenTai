import 'dart:io';

import 'package:dio/dio.dart';

class DownloadFileValidationResult {
  const DownloadFileValidationResult({
    required this.isValid,
    required this.actualBytes,
    this.expectedBytes,
    this.error,
  });

  final bool isValid;
  final int actualBytes;
  final int? expectedBytes;
  final Object? error;
}

Future<DownloadFileValidationResult> validateDownloadedFile(
  File file, {
  int? expectedBytes,
}) async {
  try {
    if (!await file.exists()) {
      return DownloadFileValidationResult(
        isValid: false,
        actualBytes: 0,
        expectedBytes: expectedBytes,
      );
    }

    final int actualBytes = await file.length();
    final bool matchesExpectedLength = expectedBytes == null ||
        expectedBytes <= 0 ||
        actualBytes == expectedBytes;
    return DownloadFileValidationResult(
      isValid: actualBytes > 0 && matchesExpectedLength,
      actualBytes: actualBytes,
      expectedBytes: expectedBytes,
    );
  } on FileSystemException catch (error) {
    return DownloadFileValidationResult(
      isValid: false,
      actualBytes: 0,
      expectedBytes: expectedBytes,
      error: error,
    );
  }
}

int? expectedDownloadedFileLength(Headers headers) {
  final String? contentEncoding =
      headers.value(Headers.contentEncodingHeader)?.trim();
  if (contentEncoding != null &&
      contentEncoding.isNotEmpty &&
      contentEncoding.toLowerCase() != 'identity') {
    return null;
  }

  final int? contentLength = int.tryParse(
    headers.value(Headers.contentLengthHeader)?.trim() ?? '',
  );
  return contentLength != null && contentLength > 0 ? contentLength : null;
}

bool isStorageWriteFailure(Object? error) {
  final Object? rootError = unwrapDioError(error);
  return rootError is FileSystemException || isNoSpaceLeftOnDevice(rootError);
}

bool isNoSpaceLeftOnDevice(Object? error) {
  final Object? rootError = unwrapDioError(error);
  if (rootError is FileSystemException && rootError.osError?.errorCode == 28) {
    return true;
  }

  final String message = rootError?.toString().toLowerCase() ?? '';
  return message.contains('no space left on device') ||
      message.contains('errno = 28') ||
      message.contains('error code = 28');
}

Object? unwrapDioError(Object? error) {
  Object? current = error;
  final Set<Object> visited = <Object>{};
  while (current is DioException &&
      current.error != null &&
      visited.add(current)) {
    current = current.error;
  }
  return current;
}
