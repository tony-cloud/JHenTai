import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/downloader/j_downloader.dart';
import 'package:jhentai/downloader/src/download/content_length_retry_policy.dart';
import 'package:jhentai/downloader/src/isolate/main_isolate_manager.dart';
import 'package:jhentai/downloader/src/model/download_chunk.dart';
import 'package:jhentai/downloader/src/model/download_progress.dart';
import 'package:jhentai/service/path_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  late HttpServer server;
  late Future<void> Function(HttpRequest) handler;
  final List<JDownloadTask> tasks = [];
  final Uint8List payload = Uint8List.fromList(List.generate(32768, (i) => i % 251));

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('archive-downloader-test-');
    pathService
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
  });
  tearDownAll(() async => directory.delete(recursive: true));
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        await request.response.close().catchError((_) => request.response);
      }
    });
  });
  tearDown(() async {
    for (final task in tasks) {
      await task.dispose();
    }
    tasks.clear();
    await server.close(force: true);
  });

  Future<void> serveArchive(HttpRequest request) async {
    if (request.method == 'HEAD') {
      request.response.contentLength = payload.length;
    } else {
      final String range = request.headers.value('range')!;
      expect(range, matches(RegExp(r'^\d+-\d+$')));
      final parts = range.split('-').map(int.parse).toList();
      request.response.statusCode = HttpStatus.partialContent;
      request.response.contentLength = parts[1] - parts[0] + 1;
      request.response.add(payload.sublist(parts[0], parts[1] + 1));
    }
    await request.response.close();
  }

  JDownloadTask task(
      {int workers = 3,
      ContentLengthRetryPolicy policy = const ContentLengthRetryPolicy(),
      void Function()? onDone,
      void Function(JDownloadException)? onError}) {
    final result = JDownloadTask.newTask(
      url: 'http://127.0.0.1:${server.port}/archive.zip',
      savePath: '${directory.path}/archive-${DateTime.now().microsecondsSinceEpoch}.zip',
      isolateCount: workers,
      contentLengthRetryPolicy: policy,
      onDone: onDone,
      onError: onError,
    );
    tasks.add(result);
    return result;
  }

  test('idle workers are actually terminated', () async {
    final ready = Completer<void>();
    final worker = MainIsolateManager(enableDoh: false, dohEndpoint: null)
      ..registerOnReady(ready.complete);
    await worker.initIsolate();
    await ready.future.timeout(const Duration(seconds: 5));
    expect(worker.free, isTrue);
    expect(worker.ready, isTrue);
    await worker.killIsolate().timeout(const Duration(seconds: 5));
    expect(worker.ready, isFalse);
    await worker.killIsolate();
  });

  test('missing content length waits and succeeds without losing bytes', () async {
    int heads = 0;
    handler = (request) async {
      if (request.method == 'HEAD' && ++heads < 3) {
        request.response.statusCode = HttpStatus.accepted;
        request.response.headers.chunkedTransferEncoding = true;
        await request.response.close();
      } else {
        await serveArchive(request);
      }
    };
    final done = Completer<void>();
    final download = task(
        policy:
            const ContentLengthRetryPolicy(maxAttempts: 4, delay: Duration(milliseconds: 15)),
        onDone: done.complete,
        onError: done.completeError);
    await download.start();
    await done.future.timeout(const Duration(seconds: 10));
    expect(heads, 3);
    expect(download.status, TaskStatus.completed);
    expect(download.activeIsolateCount, 0);
    expect(await File(download.savePath).readAsBytes(), payload);
  });

  test('pause cancels a long preparation wait and resume starts fresh', () async {
    final firstHead = Completer<void>();
    int heads = 0;
    bool ready = false;
    handler = (request) async {
      if (ready) {
        await serveArchive(request);
        return;
      }
      heads++;
      request.response.headers.chunkedTransferEncoding = true;
      await request.response.close();
      if (!firstHead.isCompleted) {
        firstHead.complete();
      }
    };
    final done = Completer<void>();
    final download = task(
        policy: const ContentLengthRetryPolicy(maxAttempts: 4, delay: Duration(minutes: 3)),
        onDone: done.complete,
        onError: done.completeError);
    final starting = download.start();
    final failedStart = expectLater(starting, throwsA(anything));
    await firstHead.future;
    await download.pause().timeout(const Duration(seconds: 2));
    await failedStart;
    expect(download.status, TaskStatus.paused);
    expect(download.activeIsolateCount, 0);
    expect(heads, 1);
    ready = true;
    await download.start();
    await done.future.timeout(const Duration(seconds: 10));
    expect(await File(download.savePath).readAsBytes(), payload);
  });

  test('repeated worker HTTP failures release all workers before retry', () async {
    bool fail = true;
    Completer<void> finished = Completer<void>();
    handler = (request) async {
      if (request.method != 'HEAD' && fail) {
        request.response.statusCode = HttpStatus.tooManyRequests;
        await request.response.close();
      } else {
        await serveArchive(request);
      }
    };
    final download = task(
        onDone: () => finished.complete(),
        onError: (error) {
          if (!finished.isCompleted) {
            finished.completeError(error);
          }
        });
    for (int attempt = 0; attempt < 4; attempt++) {
      final failure = expectLater(finished.future, throwsA(isA<JDownloadException>()));
      await download.start();
      await failure.timeout(const Duration(seconds: 10));
      expect(download.status, TaskStatus.failed);
      expect(download.activeIsolateCount, 0);
      finished = Completer<void>();
    }
    fail = false;
    await download.start();
    await finished.future.timeout(const Duration(seconds: 10));
    expect(download.status, TaskStatus.completed);
    expect(await File(download.savePath).readAsBytes(), payload);
  });

  test('pausing active transfers releases workers and preserves resumable bytes', () async {
    final firstBytes = Completer<void>();
    final releaseResponses = Completer<void>();
    handler = (request) async {
      if (request.method == 'HEAD') {
        await serveArchive(request);
        return;
      }
      final range = request.headers.value('range')!.split('-').map(int.parse).toList();
      request.response.bufferOutput = false;
      request.response.statusCode = HttpStatus.partialContent;
      request.response.contentLength = range[1] - range[0] + 1;
      request.response.add(payload.sublist(range[0], range[0] + 1024));
      await request.response.flush();
      await releaseResponses.future;
      await request.response.close();
    };
    final done = Completer<void>();
    final download = JDownloadTask.newTask(
      url: 'http://127.0.0.1:${server.port}/archive.zip',
      savePath: '${directory.path}/paused.zip',
      isolateCount: 3,
      onProgress: (current, total) {
        if (current > 0 && !firstBytes.isCompleted) {
          firstBytes.complete();
        }
      },
      onDone: done.complete,
      onError: done.completeError,
    );
    tasks.add(download);
    await download.start();
    await firstBytes.future.timeout(const Duration(seconds: 5));
    await download.pause().timeout(const Duration(seconds: 2));
    releaseResponses.complete();
    expect(download.activeIsolateCount, 0);
    expect(download.status, TaskStatus.paused);
    expect(download.currentBytes, greaterThan(0));
    handler = serveArchive;
    await download.start();
    await done.future.timeout(const Duration(seconds: 10));
    expect(await File(download.savePath).readAsBytes(), payload);
  });

  test('resumes an existing archive with the legacy Range header on the wire', () async {
    // Use a raw socket to cover both the Range value and its capitalization.
    // A server ignoring the header returns the whole file (200), not a range.
    final rangeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final requestedRanges = <String>[];
    final remainingRanges = {
      '10240-16383': (start: 10240, end: 16384),
      '20480-24575': (start: 20480, end: 24576),
      '24576-32767': (start: 24576, end: 32768),
    };
    rangeServer.listen((socket) {
      sockets.add(socket);
      final lines = <String>[];
      socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) async {
          if (line.isNotEmpty) {
            lines.add(line);
            return;
          }
          final rangeHeader = lines.firstWhere(
            (line) => line.startsWith('Range: '),
            orElse: () => '',
          );
          final range = rangeHeader.isEmpty ? '' : rangeHeader.substring('Range: '.length);
          requestedRanges.add(range);
          final bounds = remainingRanges[range];
          final body = bounds == null ? payload : payload.sublist(bounds.start, bounds.end);
          socket.add(
              ascii.encode('HTTP/1.1 ${bounds == null ? '200 OK' : '206 Partial Content'}\r\n'
                  'Content-Length: ${body.length}\r\n'
                  'Connection: close\r\n\r\n'));
          socket.add(body);
          await socket.flush();
          await socket.close();
        },
        onError: (_) {},
      );
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await rangeServer.close();
    });

    final url = 'http://127.0.0.1:${rangeServer.port}/existing.zip';
    final savePath = '${directory.path}/existing.zip';
    final chunks = [
      DownloadTrunk(size: 8192, downloadedBytes: 8192),
      DownloadTrunk(size: 8192, downloadedBytes: 2048),
      DownloadTrunk(size: 8192, downloadedBytes: 4096),
      DownloadTrunk(size: 8192),
    ];
    final metadata = DownloadProgress(
      url: url,
      savePath: savePath,
      totalBytes: payload.length,
      chunks: chunks,
    ).toBuffer;
    const metadataSize = 16 * 1024;
    final partialFile = Uint8List(metadataSize + payload.length)
      ..setRange(0, metadata.length, metadata);
    int offset = 0;
    for (final chunk in chunks) {
      partialFile.setRange(metadataSize + offset,
          metadataSize + offset + chunk.downloadedBytes, payload, offset);
      offset += chunk.size;
    }
    await File('$savePath.jdtemp').writeAsBytes(partialFile);

    final done = Completer<void>();
    final download = JDownloadTask.newTask(
      url: url,
      savePath: savePath,
      isolateCount: 3,
      onDone: done.complete,
      onError: done.completeError,
    );
    tasks.add(download);
    expect(download.currentBytes, 8192 + 2048 + 4096);
    // Register the listener before starting so an early worker failure is caught.
    final completed = expectLater(done.future, completes);
    await download.start();
    await completed.timeout(const Duration(seconds: 10));
    expect(requestedRanges, unorderedEquals(remainingRanges.keys));
    expect(download.status, TaskStatus.completed);
    expect(download.activeIsolateCount, 0);
    expect(await File(savePath).readAsBytes(), payload);
    expect(await File('$savePath.jdtemp').exists(), isFalse);
  });

  test('preparation attempts are bounded and size determines delay', () async {
    int heads = 0;
    handler = (request) async {
      heads++;
      request.response.headers.chunkedTransferEncoding = true;
      await request.response.close();
    };
    final download = task(
        policy:
            const ContentLengthRetryPolicy(maxAttempts: 3, delay: Duration(milliseconds: 1)));
    await expectLater(
        download.start(),
        throwsA(isA<JDownloadException>().having(
            (e) => e.type, 'type', JDownloadExceptionType.noContentLengthHeaderFound)));
    expect(heads, 3);
    expect(download.activeIsolateCount, 0);
    expect(ContentLengthRetryPolicy.forArchiveSize(1024).delay, const Duration(seconds: 30));
    expect(ContentLengthRetryPolicy.forArchiveSize(1024 * 1024 * 1024).delay,
        const Duration(seconds: 64));
    expect(ContentLengthRetryPolicy.forArchiveSize(50 * 1024 * 1024 * 1024).delay,
        const Duration(seconds: 180));
  });
}
