import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/network/doh_resolver.dart';
import 'package:jhentai/utils/dns_lookup.dart';
import 'package:jhentai/utils/socks_proxy.dart';

const _first = 'https://first.test/dns-query';
const _second = 'https://second.test/dns-query';
const _third = 'https://third.test/dns-query';

void main() {
  late DateTime now;
  late _Adapter adapter;
  late Dio dio;
  late DohResolver resolver;

  setUp(() {
    now = DateTime.utc(2026);
    adapter = _Adapter();
    dio = Dio()..httpClientAdapter = adapter;
    resolver = DohResolver(
        dio: dio, autoEndpoints: [_first, _second, _third], now: () => now);
  });

  tearDown(() => dio.close(force: true));

  Future<List<InternetAddress>> lookup(String host,
          {String endpoint = DohResolver.autoEndpoint,
          InternetAddressType type = InternetAddressType.IPv4}) =>
      resolver.lookup(host, endpoint: endpoint, type: type);

  test(
      'Auto tries in order, caches replies, and reuses the first usable server',
      () async {
    adapter.handler = (options) => options.uri.host == 'first.test'
        ? _failure()
        : _json([_answer('192.0.2.2')]);
    expect(_ips(await lookup('one.test')), ['192.0.2.2']);
    expect(_ips(await lookup('one.test')), ['192.0.2.2']);
    await lookup('two.test');
    expect(adapter.providers, ['first.test', 'second.test', 'second.test']);
    expect(
        adapter.requests.map((request) => request.uri.queryParameters['name']),
        ['one.test', 'one.test', 'two.test']);
  });

  test(
      'selection expires at its original TTL even when later domains have longer TTLs',
      () async {
    adapter.handler = (options) {
      if (options.uri.host == 'first.test' && now == DateTime.utc(2026)) {
        return _failure();
      }
      final int ttl =
          options.uri.queryParameters['name'] == 'one.test' ? 10 : 100;
      return _json([_answer('192.0.2.2', ttl: ttl)]);
    };
    await lookup('one.test');
    now = now.add(const Duration(seconds: 5));
    await lookup('two.test');
    now = now.add(const Duration(seconds: 5));
    await lookup('three.test');
    expect(adapter.providers,
        ['first.test', 'second.test', 'second.test', 'first.test']);
  });

  test('a shorter reply TTL shortens the selected server lease', () async {
    adapter.handler = (options) {
      if (options.uri.host == 'first.test' && now == DateTime.utc(2026)) {
        return _failure();
      }
      return _json([
        _answer('192.0.2.2',
            ttl: options.uri.queryParameters['name'] == 'two.test' ? 2 : 60)
      ]);
    };
    await lookup('one.test');
    now = now.add(const Duration(seconds: 1));
    await lookup('two.test');
    now = now.add(const Duration(seconds: 2));
    await lookup('three.test');
    expect(adapter.providers,
        ['first.test', 'second.test', 'second.test', 'first.test']);
  });

  test('DNS cache uses minimum TTL across records and families', () async {
    adapter.handler = (options) => _json(
        options.uri.queryParameters['type'] == '1'
            ? [_answer('192.0.2.1', ttl: 10), _answer('192.0.2.2', ttl: 30)]
            : [_answer('2001:db8::1', ttl: 5)]);
    expect(
        _ips(await lookup('one.test',
            endpoint: _first, type: InternetAddressType.any)),
        ['192.0.2.1', '192.0.2.2', '2001:db8::1']);
    now = now.add(const Duration(seconds: 4));
    await lookup('one.test', endpoint: _first, type: InternetAddressType.any);
    expect(adapter.requests, hasLength(2));
    now = now.add(const Duration(seconds: 1));
    await lookup('one.test', endpoint: _first, type: InternetAddressType.any);
    expect(adapter.requests, hasLength(4));
  });

  test('TTL zero disables reply cache and server selection reuse', () async {
    adapter.handler = (options) => options.uri.host == 'first.test'
        ? _failure()
        : _json([_answer('192.0.2.2', ttl: 0)]);
    await lookup('one.test');
    await lookup('one.test');
    expect(adapter.providers,
        ['first.test', 'second.test', 'first.test', 'second.test']);
  });

  test(
      'missing TTL defaults to five minutes while explicit long TTL is preserved',
      () async {
    adapter.handler = (options) => _json([
          _answer('192.0.2.1',
              ttl: options.uri.queryParameters['name'] == 'missing.test'
                  ? null
                  : 600)
        ]);
    await lookup('missing.test', endpoint: _first);
    await lookup('long.test', endpoint: _first);
    now = now.add(const Duration(minutes: 5));
    await lookup('missing.test', endpoint: _first);
    await lookup('long.test', endpoint: _first);
    expect(adapter.requests, hasLength(3));
  });

  test('cache keys distinguish endpoint selection and address type', () async {
    adapter.handler = (options) => _json([
          _answer(options.uri.queryParameters['type'] == '28'
              ? '2001:db8::1'
              : '192.0.2.1')
        ]);
    await lookup('one.test', endpoint: _first);
    await lookup('one.test', endpoint: _second);
    await lookup('one.test', endpoint: _first, type: InternetAddressType.IPv6);
    await lookup('one.test');
    await lookup('ONE.TEST', endpoint: _first);
    expect(adapter.requests, hasLength(4));
  });

  test('simultaneous identical lookups share one in-flight query', () async {
    final pending = Completer<ResponseBody>();
    final observed = Completer<void>();
    adapter.handler = (_) {
      if (!observed.isCompleted) {
        observed.complete();
      }
      return pending.future;
    };
    final first = lookup('one.test');
    final second = lookup('one.test');
    try {
      await observed.future;
      expect(adapter.requests, hasLength(1));
    } finally {
      pending.complete(_json([_answer('192.0.2.1')]));
      await Future.wait([first, second]);
    }
    expect(await first, await second);
    expect(adapter.requests, hasLength(1));
  });

  test('different domains coalesce discovery then use the selected server',
      () async {
    final pending = Completer<ResponseBody>();
    final observed = Completer<void>();
    adapter.handler = (options) {
      if (options.uri.host == 'first.test') {
        if (!observed.isCompleted) {
          observed.complete();
        }
        return pending.future;
      }
      return _json([_answer('192.0.2.2')]);
    };
    final first = lookup('one.test');
    final second = lookup('two.test');
    final third = lookup('three.test');
    try {
      await observed.future;
      expect(adapter.providers, ['first.test']);
    } finally {
      pending.complete(_failure());
      await Future.wait([first, second, third]);
    }
    expect(adapter.providers,
        ['first.test', 'second.test', 'second.test', 'second.test']);
  });

  test(
      'selected-server failure restarts order and skips the just-failed server',
      () async {
    adapter.handler = (options) {
      final String? host = options.uri.queryParameters['name'];
      return (host == 'one.test' && options.uri.host == 'first.test') ||
              (host == 'two.test' && options.uri.host == 'second.test')
          ? _failure()
          : _json([_answer('192.0.2.1')]);
    };
    await lookup('one.test');
    await lookup('two.test');
    expect(adapter.providers,
        ['first.test', 'second.test', 'second.test', 'first.test']);
  });

  test('explicit endpoints do not fail over and exhausted Auto throws',
      () async {
    adapter.handler = (_) => _failure();
    await expectLater(
        lookup('one.test', endpoint: _second), throwsA(isA<SocketException>()));
    expect(adapter.providers, ['second.test']);
    await expectLater(lookup('two.test'), throwsA(isA<SocketException>()));
    expect(adapter.providers,
        ['second.test', 'first.test', 'second.test', 'third.test']);
  });

  test('bracketed IPv6 endpoints retain authority and custom query parameters',
      () async {
    adapter.handler = (_) => _json([_answer('192.0.2.1')]);
    await lookup('one.test',
        endpoint:
            'https://[2001:db8::1]:8443/resolve?token=a%2Fb&tag=one&tag=two&type=old');
    final request = adapter.requests.single;
    expect(request.uri.toString(),
        startsWith('https://[2001:db8::1]:8443/resolve?'));
    expect(request.uri.queryParameters['token'], 'a/b');
    expect(request.uri.queryParametersAll['tag'], ['one', 'two']);
    expect(request.uri.queryParameters['type'], '1');
    expect(request.headers['accept'], 'application/dns-json');
  });

  for (final failedType in ['1', '28']) {
    test('a failed type $failedType does not discard the other family',
        () async {
      adapter.handler = (options) => options.uri.queryParameters['type'] ==
              failedType
          ? _failure()
          : _json([_answer(failedType == '1' ? '2001:db8::1' : '192.0.2.1')]);
      expect(_ips(await lookup('one.test', type: InternetAddressType.any)),
          [failedType == '1' ? '2001:db8::1' : '192.0.2.1']);
      expect(adapter.providers, ['first.test', 'first.test']);
    });
  }

  test('an empty family response does not reduce the usable family TTL',
      () async {
    adapter.handler = (options) => _json(
        options.uri.queryParameters['type'] == '1'
            ? [_answer('192.0.2.1', ttl: 60)]
            : []);
    await lookup('one.test', type: InternetAddressType.any);
    now = now.add(const Duration(seconds: 30));
    await lookup('one.test', type: InternetAddressType.any);
    expect(adapter.requests, hasLength(2));
  });

  test('relevant CNAME TTL bounds cache and unrelated answers are ignored',
      () async {
    adapter.handler = (_) => _json([
          _answer('192.0.2.99', ttl: 0, name: 'unrelated.test.'),
          _answer('192.0.2.1', ttl: 60, name: 'alias.test.'),
          {'name': 'one.test.', 'type': 5, 'TTL': 2, 'data': 'alias.test.'},
        ]);
    expect(_ips(await lookup('one.test', endpoint: _first)), ['192.0.2.1']);
    now = now.add(const Duration(seconds: 1));
    await lookup('one.test', endpoint: _first);
    expect(adapter.requests, hasLength(1));
    now = now.add(const Duration(seconds: 1));
    await lookup('one.test', endpoint: _first);
    expect(adapter.requests, hasLength(2));
  });

  test(
      'clear invalidates cache, selection, and late replies from an older generation',
      () async {
    final pending = Completer<ResponseBody>();
    final observed = Completer<void>();
    bool oldRequest = true;
    adapter.handler = (options) {
      if (oldRequest) {
        oldRequest = false;
        observed.complete();
        return pending.future;
      }
      return options.uri.host == 'first.test'
          ? _failure()
          : _json([_answer('192.0.2.2')]);
    };
    final old = lookup('one.test');
    try {
      await observed.future;
      resolver.clear();
      expect(_ips(await lookup('one.test')), ['192.0.2.2']);
    } finally {
      pending.complete(_json([_answer('192.0.2.1')]));
      await old;
    }
    expect(_ips(await old), ['192.0.2.1']);
    expect(_ips(await lookup('one.test')), ['192.0.2.2']);
    await lookup('two.test');
    expect(adapter.providers,
        ['first.test', 'first.test', 'second.test', 'second.test']);
  });

  for (final status in [400, 404, 405, 406, 415, 200]) {
    test('JSON rejection $status retries wire and remembers the protocol',
        () async {
      adapter.handler = (options) =>
          options.headers['accept'] == 'application/dns-json'
              ? ResponseBody.fromString('DNS wire format required', status,
                  headers: {
                      Headers.contentTypeHeader: ['text/plain']
                    })
              : _wire(options);
      expect(_ips(await lookup('one.test', endpoint: _first)), ['192.0.2.8']);
      await lookup('two.test', endpoint: _first);
      expect(adapter.requests.map((request) => request.headers['accept']), [
        'application/dns-json',
        'application/dns-message',
        'application/dns-message'
      ]);
      final Uri wireUri = adapter.requests[1].uri;
      expect(wireUri.queryParameters.keys, ['dns']);
      expect(wireUri.queryParameters['dns'], isNot(contains('=')));
      resolver.clear();
      await lookup('three.test', endpoint: _first);
      expect(adapter.requests[3].headers['accept'], 'application/dns-json');
    });
  }

  test('unsupported wire endpoint cleanly fails over to the next JSON endpoint',
      () async {
    adapter.handler = (options) => options.uri.host == 'first.test'
        ? ResponseBody.fromString('unsupported', 415)
        : _json([_answer('192.0.2.2')]);
    expect(_ips(await lookup('one.test')), ['192.0.2.2']);
    expect(adapter.providers, ['first.test', 'first.test', 'second.test']);
  });

  for (final wire in [false, true]) {
    test('HTTP Age reduces ${wire ? 'wire' : 'JSON'} cache lifetime', () async {
      adapter.handler = (options) {
        if (!wire) {
          return _json([_answer('192.0.2.1')], age: 58);
        }
        return options.headers['accept'] == 'application/dns-json'
            ? ResponseBody.fromString('wire required', 415)
            : _wire(options, age: 58);
      };
      await lookup('one.test', endpoint: _first);
      final int initial = adapter.requests.length;
      now = now.add(const Duration(seconds: 1));
      await lookup('one.test', endpoint: _first);
      expect(adapter.requests, hasLength(initial));
      now = now.add(const Duration(seconds: 1));
      await lookup('one.test', endpoint: _first);
      expect(adapter.requests, hasLength(initial + 1));
    });
  }

  test('an already aged-out reply is not cached', () async {
    adapter.handler = (_) => _json([_answer('192.0.2.1')], age: 120);
    await lookup('one.test', endpoint: _first);
    await lookup('one.test', endpoint: _first);
    expect(adapter.requests, hasLength(2));
  });

  test('clear prevents a late wire response from restoring protocol preference',
      () async {
    final pending = Completer<ResponseBody>();
    final observed = Completer<RequestOptions>();
    adapter.handler = (options) {
      if (options.headers['accept'] == 'application/dns-json') {
        return ResponseBody.fromString('wire required', 415);
      }
      observed.complete(options);
      return pending.future;
    };
    final old = lookup('one.test', endpoint: _first);
    final wireRequest = await observed.future;
    try {
      resolver.clear();
      adapter.handler = (_) => _json([_answer('192.0.2.2')]);
      await lookup('one.test', endpoint: _first);
    } finally {
      pending.complete(_wire(wireRequest));
      await old;
    }
    expect(_ips(await lookup('one.test', endpoint: _first)), ['192.0.2.2']);
    await lookup('two.test', endpoint: _first);
    expect(adapter.requests.last.headers['accept'], 'application/dns-json');
  });

  test('literal addresses bypass DNS traffic', () async {
    expect(_ips(await lookup('192.0.2.1')), ['192.0.2.1']);
    expect(_ips(await lookup('2001:db8::1', type: InternetAddressType.any)),
        ['2001:db8::1']);
    expect(await lookup('2001:db8::1'), isEmpty);
    expect(adapter.requests, isEmpty);
  });

  group('IPv6 address policy', () {
    test('disabled IPv6 queries only A and filters unexpected IPv6 answers',
        () async {
      adapter.handler =
          (_) => _json([_answer('192.0.2.1'), _answer('2001:db8::1')]);
      final result = await resolver.lookup('one.test',
          endpoint: _first, enableIPv6: false);
      expect(_ips(result), ['192.0.2.1']);
      expect(
          adapter.requests
              .map((request) => request.uri.queryParameters['type']),
          ['1']);
    });

    test(
        'an IPv6-only request returns no addresses or HTTP queries when disabled',
        () async {
      expect(
          await resolver.lookup('one.test',
              endpoint: _first,
              enableIPv6: false,
              type: InternetAddressType.IPv6),
          isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('Auto skips IPv6 literal endpoints when disabled', () async {
      resolver = DohResolver(
          dio: dio,
          autoEndpoints: ['https://[2001:db8::53]/dns-query', _first],
          now: () => now);
      adapter.handler = (_) => _json([_answer('192.0.2.1')]);
      final result = await resolver.lookup('one.test',
          endpoint: DohResolver.autoEndpoint, enableIPv6: false);
      expect(_ips(result), ['192.0.2.1']);
      expect(adapter.providers, ['first.test']);
    });

    test(
        'a previously selected IPv6 Auto endpoint is skipped after disabling IPv6',
        () async {
      const ipv6Endpoint = 'https://[2001:db8::53]/dns-query';
      resolver = DohResolver(
          dio: dio, autoEndpoints: [ipv6Endpoint, _first], now: () => now);
      adapter.handler = (_) => _json([_answer('192.0.2.1')]);
      await resolver.lookup('one.test',
          endpoint: DohResolver.autoEndpoint, type: InternetAddressType.IPv4);
      expect(adapter.requests.single.uri,
          Uri.parse('$ipv6Endpoint?name=one.test&type=1'));
      await resolver.lookup('two.test',
          endpoint: DohResolver.autoEndpoint, enableIPv6: false);
      expect(adapter.requests.last.uri.host, 'first.test');
      expect(adapter.requests, hasLength(2));
    });

    test(
        'an explicit IPv6 endpoint is rejected before HTTP dispatch when disabled',
        () async {
      await expectLater(
          resolver.lookup('one.test',
              endpoint: 'https://[2001:db8::53]:8443/dns-query',
              enableIPv6: false),
          throwsA(isA<SocketException>()));
      expect(adapter.requests, isEmpty);
    });

    test('bare and bracketed IPv6 literals obey the policy without DNS traffic',
        () async {
      for (final host in ['2001:db8::1', '[2001:db8::1]']) {
        expect(await resolver.lookup(host, endpoint: _first, enableIPv6: false),
            isEmpty);
        expect(_ips(await resolver.lookup(host, endpoint: _first)),
            ['2001:db8::1']);
        expect(
            await resolver.lookup(host,
                endpoint: _first, type: InternetAddressType.IPv4),
            isEmpty);
      }
      expect(
          _ips(await resolver.lookup('192.0.2.1',
              endpoint: _first, enableIPv6: false)),
          ['192.0.2.1']);
      expect(adapter.requests, isEmpty);
    });

    test('IPv4-only cache does not reuse dual-family cache or overwrite it',
        () async {
      adapter.handler = (options) => _json([
            _answer(options.uri.queryParameters['type'] == '1'
                ? '192.0.2.1'
                : '2001:db8::1')
          ]);
      expect(_ips(await resolver.lookup('one.test', endpoint: _first)),
          ['192.0.2.1', '2001:db8::1']);
      expect(
          _ips(await resolver.lookup('one.test',
              endpoint: _first, enableIPv6: false)),
          ['192.0.2.1']);
      expect(_ips(await resolver.lookup('one.test', endpoint: _first)),
          ['192.0.2.1', '2001:db8::1']);
      expect(
          adapter.requests
              .map((request) => request.uri.queryParameters['type']),
          ['1', '28', '1']);
    });

    test('different IPv6 policies isolate in-flight IPv4 queries', () async {
      final observed = Completer<void>();
      final enabled = Completer<ResponseBody>();
      final disabled = Completer<ResponseBody>();
      adapter.handler = (_) {
        if (adapter.requests.length == 1) {
          return enabled.future;
        }
        observed.complete();
        return disabled.future;
      };
      final first = resolver.lookup('one.test',
          endpoint: _first, type: InternetAddressType.IPv4);
      final second = resolver.lookup('one.test',
          endpoint: _first, type: InternetAddressType.IPv4, enableIPv6: false);
      try {
        await observed.future;
        expect(adapter.requests, hasLength(2));
      } finally {
        enabled.complete(_json([_answer('192.0.2.1')]));
        disabled.complete(_json([_answer('192.0.2.2')]));
        await Future.wait([first, second]);
      }
      expect(_ips(await first), ['192.0.2.1']);
      expect(_ips(await second), ['192.0.2.2']);
    });
  });

  group('system DNS address policy', () {
    test('IPv4-only policy filters bare and bracketed IPv6 literals', () async {
      for (final host in ['2001:db8::1', '[2001:db8::1]']) {
        expect(await lookupSystemAddresses(host, enableIPv6: false), isEmpty);
        expect(_ips(await lookupSystemAddresses(host)), ['2001:db8::1']);
        expect(
            await lookupSystemAddresses(host, type: InternetAddressType.IPv4),
            isEmpty);
      }
      expect(_ips(await lookupSystemAddresses('192.0.2.1', enableIPv6: false)),
          ['192.0.2.1']);
      expect(
          await lookupSystemAddresses('192.0.2.1',
              type: InternetAddressType.IPv6),
          isEmpty);
    });

    test('an IPv6-only request is empty while IPv6 is disabled', () async {
      expect(
          await lookupSystemAddresses('one.invalid',
              type: InternetAddressType.IPv6, enableIPv6: false),
          isEmpty);
    });

    test('localhost system fallback uses only IPv4 while IPv6 is disabled',
        () async {
      final result =
          await lookupSystemAddresses('localhost', enableIPv6: false);
      expect(result, isNotEmpty);
      expect(
          result.every((address) => address.type == InternetAddressType.IPv4),
          isTrue);
    });
  });

  test('DoH endpoint bootstrap bypasses the global application DNS callback',
      () async {
    final previousIOOverrides = IOOverrides.current;
    final previousHttpOverrides = HttpOverrides.current;
    addTearDown(() {
      IOOverrides.global = previousIOOverrides;
      HttpOverrides.global = previousHttpOverrides;
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.queryParameters['name'], 'resolved.test');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'Status': 0,
        'Answer': [_answer('192.0.2.8')],
      }));
      await request.response.close();
    });
    final callbacks = <String>[];
    SocksProxy.initProxy(
        lookup: (host, {type = InternetAddressType.any}) async {
      callbacks.add(host);
      throw const SocketException('Recursive application DNS lookup');
    });
    final transport =
        Dio(BaseOptions(connectTimeout: const Duration(seconds: 3)))
          ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
            return createProxyHttpClient()..findProxy = (_) => 'DIRECT';
          });
    addTearDown(() => transport.close(force: true));
    final bootstrap = DohResolver(dio: transport, autoEndpoints: []);
    final result = await bootstrap.lookup(
      'resolved.test',
      endpoint: 'http://localhost:${server.port}/resolve',
      type: InternetAddressType.IPv4,
    );
    expect(_ips(result), ['192.0.2.8']);
    expect(callbacks, isEmpty);
  });
}

List<String> _ips(List<InternetAddress> addresses) =>
    addresses.map((address) => address.address).toList();

Map<String, dynamic> _answer(String address, {int? ttl = 60, String? name}) => {
      'type': address.contains(':') ? 28 : 1,
      'data': address,
      if (ttl != null) 'TTL': ttl,
      if (name != null) 'name': name,
    };

ResponseBody _json(List<Map<String, dynamic>> answers, {int age = 0}) =>
    ResponseBody.fromString(
      jsonEncode({'Status': 0, 'Answer': answers}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'age': ['$age'],
      },
    );

ResponseBody _failure() => ResponseBody.fromString('unavailable', 503);

ResponseBody _wire(RequestOptions options, {int age = 0}) {
  final List<int> question = base64Url
      .decode(base64Url.normalize(options.uri.queryParameters['dns']!));
  final List<int> answer = List.of(question);
  answer[2] = 0x81;
  answer[3] = 0x80;
  answer[7] = 1;
  final int type =
      (question[question.length - 4] << 8) | question[question.length - 3];
  final List<int> address =
      type == 1 ? [192, 0, 2, 8] : InternetAddress('2001:db8::8').rawAddress;
  answer.addAll(
      [0xc0, 0x0c, 0, type, 0, 1, 0, 0, 0, 60, 0, address.length, ...address]);
  return ResponseBody.fromBytes(answer, 200, headers: {
    Headers.contentTypeHeader: ['application/dns-message'],
    'age': ['$age'],
  });
}

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  FutureOr<ResponseBody> Function(RequestOptions options) handler =
      (_) => _failure();

  List<String> get providers =>
      requests.map((request) => request.uri.host).toList();

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
