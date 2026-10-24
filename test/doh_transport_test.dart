import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/downloader/src/isolate/main_isolate_manager.dart';
import 'package:jhentai/downloader/src/model/proxy_config.dart';
import 'package:jhentai/network/doh_resolver.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/socks_proxy.dart';

void main() {
  test('bracketed IPv6 endpoint resolves over certificate-pinned HTTPS', () async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/doh/server-cert.pem')
      ..usePrivateKey('test/fixtures/doh/server-key.pem');
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv6, 0, context, v6Only: true);
    addTearDown(() => server.close(force: true));
    int requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.uri.queryParameters['name'], 'example.com');
      expect(request.uri.queryParameters['type'], '1');
      expect(request.uri.queryParameters['token'], 'keep');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'Status': 0,
        'Answer': [
          {'type': 1, 'TTL': 60, 'data': '192.0.2.1'}
        ],
      }));
      await request.response.close();
    });
    final certificate = await File('test/fixtures/doh/server-cert.pem').readAsString();
    final dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final client = createProxyHttpClient(context: SecurityContext(withTrustedRoots: false));
        client.findProxy = (_) => 'DIRECT';
        client.badCertificateCallback =
            (cert, host, _) => host == '::1' && cert.pem.trim() == certificate.trim();
        return client;
      });
    addTearDown(() => dio.close(force: true));
    final resolver = DohResolver(dio: dio, autoEndpoints: []);
    final endpoint = 'https://[::1]:${server.port}/dns-query?token=keep';
    for (int index = 0; index < 2; index++) {
      final result =
          await resolver.lookup('example.com', endpoint: endpoint, type: InternetAddressType.IPv4);
      expect(result.single.address, '192.0.2.1');
    }
    expect(requests, 1);
  });

  test('download isolate receives Auto list and uses failover DNS to fetch bytes', () async {
    final directory = await Directory.systemTemp.createTemp('doh-worker-');
    final previousLogDir = log.logDirPath;
    log.logDirPath = directory.path;
    addTearDown(() async {
      await log.clear();
      log.logDirPath = previousLogDir;
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => dns.close(force: true));
    final attempted = <String>[];
    dns.listen((request) async {
      attempted.add(request.uri.path);
      if (request.uri.path == '/unavailable') {
        request.response.statusCode = 503;
      } else {
        expect(request.uri.queryParameters['name'], 'archive.auto.test');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'Status': 0,
          'Answer': request.uri.queryParameters['type'] == '1'
              ? [
                  {'type': 1, 'TTL': 60, 'data': '127.0.0.1'}
                ]
              : [],
        }));
      }
      await request.response.close();
    });
    final archive = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => archive.close(force: true));
    archive.listen((request) async {
      expect(request.headers.host, 'archive.auto.test');
      request.response.statusCode = HttpStatus.partialContent;
      request.response.contentLength = 4;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final ready = Completer<void>();
    final done = Completer<void>();
    final worker = MainIsolateManager(
      proxyConfig: ProxyConfig(type: ProxyType.direct, address: ''),
      enableDoh: true,
      dohEndpoint: DohResolver.autoEndpoint,
      autoDohEndpoints: [
        'http://127.0.0.1:${dns.port}/unavailable',
        'http://127.0.0.1:${dns.port}/working',
      ],
    )
      ..registerOnReady(ready.complete)
      ..registerOnDone(done.complete)
      ..registerOnError(done.completeError);
    addTearDown(worker.killIsolate);
    await worker.initIsolate();
    await ready.future.timeout(const Duration(seconds: 5));
    final path = '${directory.path}/archive.bin';
    worker.beginDownload(
      'http://archive.auto.test:${archive.port}/archive.bin',
      path,
      (start: 0, end: 4),
      0,
      connectionTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      timeoutRetryTimes: 0,
    );
    await done.future.timeout(const Duration(seconds: 10));
    expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
    expect(attempted, ['/unavailable', '/unavailable', '/working', '/working']);
  });
  test('running download worker applies IPv4-only policy and skips IPv6 DoH endpoint', () async {
    final directory = await Directory.systemTemp.createTemp('doh-ipv4-worker-');
    final previousLogDir = log.logDirPath;
    log.logDirPath = directory.path;
    addTearDown(() async {
      await log.clear();
      log.logDirPath = previousLogDir;
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ipv6Dns = await HttpServer.bind(InternetAddress.loopbackIPv6, 0, v6Only: true);
    final archive = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await dns.close(force: true);
      await ipv6Dns.close(force: true);
      await archive.close(force: true);
    });
    int ipv6Queries = 0;
    ipv6Dns.listen((request) async {
      ipv6Queries++;
      request.response.statusCode = 503;
      await request.response.close();
    });
    final types = <String?>[];
    dns.listen((request) async {
      types.add(request.uri.queryParameters['type']);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'Status': 0,
        'Answer': [
          {'type': 1, 'TTL': 60, 'data': '127.0.0.1'}
        ],
      }));
      await request.response.close();
    });
    archive.listen((request) async {
      request.response.statusCode = 206;
      request.response.add([9, 8]);
      await request.response.close();
    });
    final ready = Completer<void>();
    final done = Completer<void>();
    final worker = MainIsolateManager(
      proxyConfig: ProxyConfig(type: ProxyType.direct, address: ''),
      enableDoh: true,
      enableIPv6: true,
      dohEndpoint: DohResolver.autoEndpoint,
      autoDohEndpoints: [
        'http://[::1]:${ipv6Dns.port}/dns-query',
        'http://127.0.0.1:${dns.port}/dns-query',
      ],
    )
      ..registerOnReady(ready.complete)
      ..registerOnDone(done.complete)
      ..registerOnError(done.completeError);
    addTearDown(worker.killIsolate);
    await worker.initIsolate();
    await ready.future.timeout(const Duration(seconds: 5));
    MainIsolateManager.updateIPv6Policy(false);
    final path = '${directory.path}/ipv4.bin';
    worker.beginDownload(
      'http://archive.ipv4.test:${archive.port}/archive.bin',
      path,
      (start: 0, end: 2),
      0,
      connectionTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      timeoutRetryTimes: 0,
    );
    await done.future.timeout(const Duration(seconds: 10));
    expect(await File(path).readAsBytes(), [9, 8]);
    expect(types, ['1']);
    expect(ipv6Queries, 0);
  });
}
