import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/network/eh_cookie_manager.dart';
import 'package:jhentai/service/doh_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/utils/domain_fronting_util.dart';
import 'package:jhentai/utils/socks_proxy.dart';

class _DohService extends DohService {
  final List<String> hosts = [];
  List<InternetAddress> addresses = [InternetAddress('192.0.2.10')];
  Completer<List<InternetAddress>>? pending;

  @override
  Future<List<InternetAddress>> lookup(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    hosts.add(host);
    if (pending != null) {
      return pending!.future;
    }
    return addresses;
  }
}

class _ConfigService extends LocalConfigService {
  String? storedCookies;

  @override
  Future<int> write({
    required ConfigEnum configKey,
    String subConfigKey = '',
    required String value,
  }) async {
    storedCookies = value;
    return 1;
  }
}

void main() {
  final previousSettings = networkSetting;
  final previousDoh = dohService;
  late _DohService resolver;

  setUp(() {
    networkSetting = NetworkSetting();
    resolver = _DohService();
    dohService = resolver;
  });

  tearDown(() {
    networkSetting = previousSettings;
    dohService = previousDoh;
  });

  for (final fronting in [false, true]) {
    for (final doh in [false, true]) {
      test('thumbnail routing with domain fronting=$fronting, DoH=$doh', () async {
        networkSetting.enableDomainFronting.value = fronting;
        networkSetting.enableDnsOverHttps.value = doh;
        const url = 'https://ehgt.org/t/thumbnail.jpg?size=small';

        final result = await DomainFrontingUtil.build(url);

        expect(result.applied, fronting);
        if (!fronting) {
          expect(result.url, url);
          expect(result.headers, isNull);
          expect(resolver.hosts, isEmpty);
        } else {
          expect(result.headers, {'host': 'ehgt.org'});
          expect(Uri.parse(result.url).path, '/t/thumbnail.jpg');
          expect(Uri.parse(result.url).query, 'size=small');
          if (doh) {
            expect(result.ip, '192.0.2.10');
            expect(resolver.hosts, ['ehgt.org']);
            expect(NetworkSetting.host2IPs['ehgt.org'], isNot(contains(result.ip)));
            expect(DomainFrontingUtil.isFrontingIP(result.ip!), isTrue);
            expect(DomainFrontingUtil.isFrontingIP('192.0.2.250'), isFalse);
          } else {
            expect(NetworkSetting.host2IPs['ehgt.org'], contains(result.ip));
            expect(resolver.hosts, isEmpty);
          }
        }
      });
    }
  }

  test('all fronted domains use DNS replies and accept refreshed addresses', () async {
    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    for (final host in NetworkSetting.host2IPs.keys) {
      expect((await DomainFrontingUtil.build('https://$host/path')).ip, '192.0.2.10');
    }
    resolver.addresses = [InternetAddress('192.0.2.11')];
    expect((await DomainFrontingUtil.build('https://ehgt.org/path')).ip, '192.0.2.11');
    expect(resolver.hosts, [...NetworkSetting.host2IPs.keys, 'ehgt.org']);
    expect(DomainFrontingUtil.isFrontingIP('192.0.2.10'), isTrue,
        reason: 'Existing image requests must remain valid after DNS refresh.');
  });

  test('fronted requests preserve query, site identity and login cookies', () async {
    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    final original = RequestOptions(
      baseUrl: 'https://e-hentai.org',
      path: '/g/1/token?existing=a%2Fb',
      queryParameters: {'search': 'a b', 'page': 2},
      headers: {'custom': 'value'},
      extra: {'cacheKey': 'original'},
    );
    final fronted = await DomainFrontingUtil.buildRequest(original);
    expect(fronted.uri.host, '192.0.2.10');
    expect(fronted.uri.queryParameters, original.uri.queryParameters);
    expect(fronted.headers['custom'], 'value');
    expect(fronted.headers['host'], 'e-hentai.org');
    expect(fronted.extra['cacheKey'], 'original');
    expect(DomainFrontingUtil.requestHost(fronted), 'e-hentai.org');
    expect(DomainFrontingUtil.requestHost(original), 'e-hentai.org');

    final config = _ConfigService();
    final cookies = EHCookieManager(config);
    cookies.onResponse(
      Response(
        requestOptions: fronted,
        headers: Headers.fromMap({
          'set-cookie': ['ipb_member_id=123; Path=/']
        }),
      ),
      ResponseInterceptorHandler(),
    );
    expect(cookies.cookies.any((cookie) => cookie.name == 'ipb_member_id' && cookie.value == '123'),
        isTrue);
    expect(config.storedCookies, contains('ipb_member_id=123'));
  });

  test('concurrent thumbnails share an in-flight lookup', () async {
    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    resolver.pending = Completer<List<InternetAddress>>();
    final first = DomainFrontingUtil.build('https://ehgt.org/one.jpg');
    final second = DomainFrontingUtil.build('https://ehgt.org/two.jpg');
    expect(resolver.hosts, ['ehgt.org']);
    resolver.pending!.complete([InternetAddress('192.0.2.12')]);
    expect((await first).ip, '192.0.2.12');
    expect((await second).ip, '192.0.2.12');
  });

  test('empty or failed resolution never falls back to the stored host list', () async {
    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    resolver.addresses = [];
    await expectLater(
        DomainFrontingUtil.build('https://ehgt.org/a'), throwsA(isA<SocketException>()));
    resolver.pending = Completer<List<InternetAddress>>();
    final failed = DomainFrontingUtil.build('https://ehgt.org/a');
    resolver.pending!.completeError(const SocketException('DNS unavailable'));
    await expectLater(failed, throwsA(isA<SocketException>()));
    resolver.pending = null;
    resolver.addresses = [InternetAddress('192.0.2.13')];
    expect((await DomainFrontingUtil.build('https://ehgt.org/a')).ip, '192.0.2.13');
  });

  test('unmapped domains are untouched and IPv6 preserves URL components', () async {
    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    const other = 'https://example.com/image.jpg';
    expect((await DomainFrontingUtil.build(other)).url, other);
    expect(resolver.hosts, isEmpty);
    resolver.addresses = [InternetAddress('2001:db8::1')];
    final result = await DomainFrontingUtil.build('https://ehgt.org:8443/a%20b?q=ehgt.org#image');
    expect(result.url, 'https://[2001:db8::1]:8443/a%20b?q=ehgt.org#image');
    expect(result.headers, {'host': 'ehgt.org'});
  });

  test('real DoH reply drives a fronted HTTPS image connection', () async {
    final previousHttpOverrides = HttpOverrides.current;
    final previousIOOverrides = IOOverrides.current;
    final previousLogDir = log.logDirPath;
    final directory = await Directory.systemTemp.createTemp('jhentai-fronting-');
    log.logDirPath = directory.path;
    addTearDown(() async {
      HttpOverrides.global = previousHttpOverrides;
      IOOverrides.global = previousIOOverrides;
      await log.clear();
      log.logDirPath = previousLogDir;
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final dns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => dns.close(force: true));
    final queries = <String>[];
    dns.listen((request) async {
      queries.add('${request.uri.queryParameters['name']}:${request.uri.queryParameters['type']}');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'Status': 0,
        'Answer': request.uri.queryParameters['type'] == '1'
            ? [
                {'type': 1, 'TTL': 60, 'data': '127.0.0.1'}
              ]
            : [],
      }));
      await request.response.close();
    });

    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/domain_fronting/server-cert.pem')
      ..usePrivateKey('test/fixtures/domain_fronting/server-key.pem');
    final images = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => images.close(force: true));
    final receivedHost = Completer<String?>();
    images.listen((request) async {
      receivedHost.complete(request.headers.value(HttpHeaders.hostHeader));
      request.response.write('thumbnail');
      await request.response.close();
    });

    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    networkSetting.proxyType.value = JProxyType.direct;
    networkSetting.dnsOverHttpsEndpoint.value = 'http://127.0.0.1:${dns.port}/dns-query';
    dohService = DohService();
    await dohService.doInitBean();
    SocksProxy.initProxy(
      lookup: dohService.lookup,
      findProxy: (_) => 'DIRECT',
      onCreate: (client) =>
          client.badCertificateCallback = (_, host, __) => DomainFrontingUtil.isFrontingIP(host),
    );

    final result = await DomainFrontingUtil.build('https://ehgt.org:${images.port}/thumbnail.jpg');
    expect(result.ip, '127.0.0.1');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(Uri.parse(result.url));
    result.headers!.forEach(request.headers.set);
    final response = await request.close();
    expect(await utf8.decodeStream(response), 'thumbnail');
    expect(await receivedHost.future, 'ehgt.org');
    expect(queries, ['ehgt.org:1', 'ehgt.org:28']);
    await DomainFrontingUtil.build('https://ehgt.org/another.jpg');
    expect(queries, hasLength(2), reason: 'The next image should reuse the DoH TTL cache.');
  });
}
