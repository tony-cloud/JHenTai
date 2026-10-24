import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/utils/socks_proxy.dart';

const _cert = 'test/fixtures/domain_fronting/server-cert.pem';
const _key = 'test/fixtures/domain_fronting/server-key.pem';

SecurityContext _serverContext() => SecurityContext()
  ..useCertificateChain(_cert)
  ..usePrivateKey(_key);
SecurityContext _trustedContext() =>
    SecurityContext(withTrustedRoots: false)..setTrustedCertificates(_cert);

// The host Dart SDK on macOS rejects test-only trust anchors through its
// platform verifier. Keep the fixture and requested hostname pinned there;
// other platforms exercise the custom SecurityContext without a callback.
void _acceptFixtureOnMacOS(HttpClient client) {
  if (!Platform.isMacOS) {
    return;
  }
  final expected = File(_cert).readAsStringSync().trim();
  client.badCertificateCallback = (certificate, host, _) =>
      host == 'ehgt.org' && certificate.pem.trim() == expected;
}

Future<String> _get(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  return utf8.decode(await response
      .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk)));
}

Future<HttpServer> _server({bool secure = false}) async {
  final server = secure
      ? await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4, 0, _serverContext())
      : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.write('ok');
    await request.response.close();
  });
  return server;
}

void main() {
  for (final secure in [false, true]) {
    test('${secure ? 'HTTPS' : 'HTTP'} falls back from dead IPv6 to IPv4',
        () async {
      final server = await _server(secure: secure);
      addTearDown(() => server.close(force: true));
      final client = createProxyHttpClient(
        context: secure ? _trustedContext() : null,
        lookup: (host, {type = InternetAddressType.any}) async =>
            [InternetAddress.loopbackIPv6, InternetAddress.loopbackIPv4],
      )..findProxy = (_) {
          return 'DIRECT';
        };
      _acceptFixtureOnMacOS(client);
      addTearDown(() => client.close(force: true));
      expect(
          await _get(
              client,
              Uri.parse(
                  '${secure ? 'https' : 'http'}://ehgt.org:${server.port}/')),
          'ok');
    });
  }

  test(
      'HTTPS retries a subsequent address after a TLS failure, preserving hostname verification',
      () async {
    final server = await _server(secure: true);
    addTearDown(() => server.close(force: true));
    final broken = await ServerSocket.bind(
        InternetAddress.loopbackIPv6, server.port,
        v6Only: true);
    addTearDown(broken.close);
    broken.listen((socket) {
      socket.listen((_) {
        socket.destroy();
      });
    });
    final client = createProxyHttpClient(
      context: _trustedContext(),
      lookup: (host, {type = InternetAddressType.any}) async =>
          [InternetAddress.loopbackIPv6, InternetAddress.loopbackIPv4],
    )..findProxy = (_) {
        return 'DIRECT';
      };
    _acceptFixtureOnMacOS(client);
    addTearDown(() => client.close(force: true));
    expect(await _get(client, Uri.parse('https://ehgt.org:${server.port}/')),
        'ok');
  });

  test('an unresponsive IPv6 TLS peer cannot prevent IPv4 fallback', () async {
    final server = await _server(secure: true);
    addTearDown(() => server.close(force: true));
    final stalled = await ServerSocket.bind(
        InternetAddress.loopbackIPv6, server.port,
        v6Only: true);
    final sockets = <Socket>[];
    stalled.listen(sockets.add);
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await stalled.close();
    });
    final client = createProxyHttpClient(
      context: _trustedContext(),
      lookup: (host, {type = InternetAddressType.any}) async =>
          [InternetAddress.loopbackIPv6, InternetAddress.loopbackIPv4],
    )..findProxy = (_) {
        return 'DIRECT';
      };
    _acceptFixtureOnMacOS(client);
    addTearDown(() => client.close(force: true));
    expect(
        await _get(client, Uri.parse('https://ehgt.org:${server.port}/'))
            .timeout(const Duration(seconds: 5)),
        'ok');
  });

  test('IPv4-only filters callback results and requests IPv4 lookups',
      () async {
    final server = await _server();
    addTearDown(() => server.close(force: true));
    final types = <InternetAddressType>[];
    final client = createProxyHttpClient(
      enableIPv6: () => false,
      lookup: (host, {type = InternetAddressType.any}) async {
        types.add(type);
        return [InternetAddress.loopbackIPv6, InternetAddress.loopbackIPv4];
      },
    )..findProxy = (_) {
        return 'DIRECT';
      };
    addTearDown(() => client.close(force: true));
    expect(await _get(client, Uri.parse('http://ipv4.test:${server.port}/')),
        'ok');
    expect(types, [InternetAddressType.IPv4]);
    await expectLater(client.getUrl(Uri.parse('http://[::1]:${server.port}/')),
        throwsA(isA<SocketException>()));
  });

  test('IPv4-only also works with system DNS and no custom resolver', () async {
    final server = await _server();
    addTearDown(() => server.close(force: true));
    final client = createProxyHttpClient(enableIPv6: () => false)
      ..findProxy = (_) {
        return 'DIRECT';
      };
    addTearDown(() => client.close(force: true));
    expect(await _get(client, Uri.parse('http://localhost:${server.port}/')),
        'ok');
  });

  test('certificate rejection is default and late callback/keyLog setters work',
      () async {
    final server = await _server(secure: true);
    addTearDown(() => server.close(force: true));
    final client = createProxyHttpClient(
      context: SecurityContext(withTrustedRoots: false),
      lookup: (host, {type = InternetAddressType.any}) async =>
          [InternetAddress.loopbackIPv4],
    )..findProxy = (_) {
        return 'DIRECT';
      };
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('https://ehgt.org:${server.port}/');
    await expectLater(client.getUrl(uri), throwsA(isA<HandshakeException>()));
    final hosts = <String>[];
    final keys = <String>[];
    client.badCertificateCallback = (_, host, port) {
      hosts.add(host);
      expect(port, server.port);
      return true;
    };
    client.keyLog = keys.add;
    expect(await _get(client, uri), 'ok');
    expect(hosts, ['ehgt.org']);
    expect(keys, isNotEmpty);
  });

  test('connectionTimeout covers a hanging lookup', () async {
    final pending = Completer<List<InternetAddress>>();
    final client = createProxyHttpClient(
        lookup: (host, {type = InternetAddressType.any}) => pending.future)
      ..findProxy = (_) {
        return 'DIRECT';
      }
      ..connectionTimeout = const Duration(milliseconds: 40);
    addTearDown(() => client.close(force: true));
    await expectLater(
        client.getUrl(Uri.parse('http://waiting.test/')),
        throwsA(isA<SocketException>().having(
            (error) => error.message, 'message', contains('timed out'))));
    pending.complete([InternetAddress.loopbackIPv4]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test(
      'closing the client cancels DNS and does not connect after late completion',
      () async {
    final pending = Completer<List<InternetAddress>>();
    final observed = Completer<void>();
    final server = await _server();
    addTearDown(() => server.close(force: true));
    final client =
        createProxyHttpClient(lookup: (host, {type = InternetAddressType.any}) {
      observed.complete();
      return pending.future;
    })
          ..findProxy = (_) {
            return 'DIRECT';
          };
    final request =
        client.getUrl(Uri.parse('http://waiting.test:${server.port}/'));
    final failed = expectLater(request, throwsA(isA<SocketException>()));
    await observed.future;
    client.close(force: true);
    await failed;
    pending.complete([InternetAddress.loopbackIPv4]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test(
      'refresh applies policy to a pooled client while preserving settings and callbacks',
      () async {
    final server = await _server(secure: true);
    addTearDown(() => server.close(force: true));
    var ipv6 = true;
    final types = <InternetAddressType>[];
    final client = createProxyHttpClient(
      enableIPv6: () => ipv6,
      lookup: (host, {type = InternetAddressType.any}) async {
        types.add(type);
        return [InternetAddress.loopbackIPv4];
      },
    )
      ..findProxy = (_) {
        return 'DIRECT';
      }
      ..badCertificateCallback = (_, host, __) {
        return host == 'ehgt.org';
      }
      ..userAgent = 'policy-test'
      ..connectionTimeout = const Duration(seconds: 2);
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('https://ehgt.org:${server.port}/');
    expect(await _get(client, uri), 'ok');
    ipv6 = false;
    SocksProxy.refreshAddressPolicy();
    expect(await _get(client, uri), 'ok');
    expect(types, [InternetAddressType.any, InternetAddressType.IPv4]);
    expect(client.userAgent, 'policy-test');
    expect(client.connectionTimeout, const Duration(seconds: 2));
  });

  test('HTTP proxy hostname uses IPv4 lookup and keeps the original target URL',
      () async {
    final proxy = await _server();
    addTearDown(() => proxy.close(force: true));
    final hosts = <String>[];
    final client = createProxyHttpClient(
      enableIPv6: () => false,
      lookup: (host, {type = InternetAddressType.any}) async {
        hosts.add(host);
        expect(type, InternetAddressType.IPv4);
        return [InternetAddress.loopbackIPv6, InternetAddress.loopbackIPv4];
      },
    )..findProxy = (_) => 'PROXY proxy.test:${proxy.port}';
    addTearDown(() => client.close(force: true));
    expect(await _get(client, Uri.parse('http://remote.test/path')), 'ok');
    expect(hosts, ['proxy.test']);
  });
  test('custom connectionFactory can be assigned and reset', () async {
    final server = await _server();
    addTearDown(() => server.close(force: true));
    final lookedUp = <String>[];
    final client = createProxyHttpClient(
        lookup: (host, {type = InternetAddressType.any}) async {
      lookedUp.add(host);
      return [InternetAddress.loopbackIPv4];
    })
      ..findProxy = (_) {
        return 'DIRECT';
      };
    addTearDown(() => client.close(force: true));
    var customCalls = 0;
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      customCalls++;
      return Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
    };
    expect(await _get(client, Uri.parse('http://custom.test:${server.port}/')),
        'ok');
    client.connectionFactory = null;
    expect(await _get(client, Uri.parse('http://managed.test:${server.port}/')),
        'ok');
    expect(customCalls, 1);
    expect(lookedUp, ['managed.test']);
  });

  test(
      'SOCKS HTTPS honors a late certificate callback and original TLS hostname',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    final handshakeErrors = <Object>[];
    server.listen((socket) {
      sockets.add(socket);
      var stage = 0;
      socket.listen((data) async {
        if (stage++ == 0) {
          socket.add([5, 0]);
        } else {
          socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 1]);
          await socket.flush();
          try {
            final secure =
                await SecureSocket.secureServer(socket, _serverContext());
            sockets.add(secure);
            secure.listen((_) {
              secure.add(utf8.encode(
                  'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'));
            });
          } catch (error) {
            handshakeErrors.add(error);
          }
        }
      });
    });
    final client = createProxyHttpClient(
      socksConfig:
          SocksProxyConfiguration(host: '127.0.0.1', port: server.port),
      enableIPv6: () => false,
      lookup: (host, {type = InternetAddressType.any}) async =>
          [InternetAddress.loopbackIPv4],
    );
    addTearDown(() => client.close(force: true));
    final hosts = <String>[];
    client.badCertificateCallback = (_, host, __) {
      hosts.add(host);
      return host == 'ehgt.org';
    };
    expect(await _get(client, Uri.parse('https://ehgt.org/')), 'ok');
    expect(hosts, ['ehgt.org']);
    expect(handshakeErrors, isEmpty);
  });

  for (final enableIPv6 in [true, false]) {
    test(
        'fronted literal retains literal SNI and filters alternate addresses with IPv6=$enableIPv6',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final rejectedIPv6 = await ServerSocket.bind(
          InternetAddress.loopbackIPv6, server.port,
          v6Only: true);
      final sockets = <Socket>[];
      var ipv6Attempts = 0;
      rejectedIPv6.listen((socket) {
        ipv6Attempts++;
        socket.destroy();
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        await rejectedIPv6.close();
      });
      final sni = Completer<String?>();
      server.listen((socket) {
        sockets.add(socket);
        final hello = <int>[];
        var upgrading = false;
        socket.listen((data) async {
          if (upgrading) {
            return;
          }
          hello.addAll(data);
          if (hello.length < 5 ||
              hello.length < 5 + (hello[3] << 8) + hello[4]) {
            return;
          }
          upgrading = true;
          sni.complete(_clientHelloServerName(hello));
          final secure = await SecureSocket.secureServer(
              socket, _serverContext(),
              bufferedData: hello);
          sockets.add(secure);
          secure.listen((_) => secure.add(utf8.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')));
        });
      });
      final original = Uri.parse('https://127.0.0.2:${server.port}/image');
      final client = createProxyHttpClient(
        enableIPv6: () => enableIPv6,
        lookup: (host, {type = InternetAddressType.any}) async =>
            throw StateError(
                'Normal DNS must not resolve a registered fronted URL'),
        connectionAddresses: (uri) async {
          expect(uri, original);
          return [InternetAddress.loopbackIPv6, InternetAddress.loopbackIPv4];
        },
      );
      addTearDown(() => client.close(force: true));
      client.badCertificateCallback = (_, host, __) => host == '127.0.0.2';
      expect(await _get(client, original), 'ok');
      expect(await sni.future, '127.0.0.2');
      expect(ipv6Attempts, enableIPv6 ? 1 : 0);
    });
  }

  test(
      'fronting fallback cannot be pooled across virtual hosts sharing a literal URL authority',
      () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(
        InternetAddress.loopbackIPv6, first.port,
        v6Only: true);
    addTearDown(() async {
      await first.close(force: true);
      await second.close(force: true);
    });
    final receivedHosts = <String>[];
    for (final (server, label) in [(first, 'first'), (second, 'second')]) {
      server.listen((request) async {
        receivedHosts.add(request.headers.host!);
        expect(request.persistentConnection, isFalse);
        request.response.write(label);
        await request.response.close();
      });
    }
    final routes = <String>[];
    final client = createProxyHttpClient(connectionAddresses: (uri) async {
      routes.add(uri.path);
      return [
        uri.path == '/one'
            ? InternetAddress.loopbackIPv4
            : InternetAddress.loopbackIPv6
      ];
    });
    addTearDown(() => client.close(force: true));
    for (final (path, host, label) in [
      ('/one', 'one.test', 'first'),
      ('/two', 'two.test', 'second')
    ]) {
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.2:${first.port}$path'));
      request.headers.host = host;
      // Dio sets this after opening; callers can also supply connection headers.
      request.persistentConnection = true;
      request.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
      final response = await request.close();
      expect(await utf8.decodeStream(response), label);
    }
    expect(routes, ['/one', '/two']);
    expect(receivedHosts, ['one.test', 'two.test']);
  });

  test(
      'nonpersistent fronting survives automatic redirects to an alternate address',
      () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(
        InternetAddress.loopbackIPv6, first.port,
        v6Only: true);
    addTearDown(() async {
      await first.close(force: true);
      await second.close(force: true);
    });
    final received = <String>[];
    first.listen((request) async {
      received.add('first:${request.uri.path}');
      expect(request.persistentConnection, isFalse);
      if (request.uri.path == '/start') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/follow');
      } else {
        request.response.write('next');
      }
      await request.response.close();
    });
    second.listen((request) async {
      received.add('second:${request.uri.path}');
      expect(request.persistentConnection, isFalse);
      request.response.write('redirected');
      await request.response.close();
    });
    final routes = <String>[];
    final client = createProxyHttpClient(connectionAddresses: (uri) async {
      routes.add(uri.path);
      return [
        uri.path == '/follow'
            ? InternetAddress.loopbackIPv6
            : InternetAddress.loopbackIPv4
      ];
    });
    addTearDown(() => client.close(force: true));
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.2:${first.port}/start'));
    request.persistentConnection = true;
    expect(await utf8.decodeStream(await request.close()), 'redirected');
    expect(await _get(client, Uri.parse('http://127.0.0.2:${first.port}/next')),
        'next');
    expect(routes, ['/start', '/follow', '/next']);
    expect(received, ['first:/start', 'second:/follow', 'first:/next']);
  });

  for (final localResolution in [false, true]) {
    test(
        'SOCKS authenticates and ${localResolution ? 'pins IPv4 destinations' : 'retains remote DNS by default'}',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      final destinationType = Completer<int>();
      final authenticated = Completer<List<int>>();
      server.listen((socket) async {
        sockets.add(socket);
        final bytes = _SocketBytes(socket);
        final greeting = await bytes.read(2);
        await bytes.read(greeting[1]);
        socket.add([5, 2]);
        final auth = await bytes.read(2);
        final username = await bytes.read(auth[1]);
        final passwordLength = (await bytes.read(1)).single;
        final password = await bytes.read(passwordLength);
        authenticated.complete([...username, 0, ...password]);
        socket.add([1, 0]);
        final command = await bytes.read(4);
        destinationType.complete(command[3]);
        final length = command[3] == 1 ? 4 : (await bytes.read(1)).single;
        await bytes.read(length + 2);
        socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 1]);
        var tail = '';
        while (!tail.endsWith('\r\n\r\n')) {
          tail += String.fromCharCode((await bytes.read(1)).single);
        }
        socket.add(utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'));
        await socket.flush();
      });
      final hosts = <String>[];
      final client = createProxyHttpClient(
        socksConfig: SocksProxyConfiguration(
            host: '127.0.0.1',
            port: server.port,
            username: 'user',
            password: 'secret'),
        enableIPv6: () => !localResolution,
        lookup: localResolution
            ? (host, {type = InternetAddressType.any}) async {
                hosts.add(host);
                expect(type, InternetAddressType.IPv4);
                return [
                  InternetAddress.loopbackIPv6,
                  InternetAddress.loopbackIPv4
                ];
              }
            : null,
      );
      addTearDown(() => client.close(force: true));
      expect(await _get(client, Uri.parse('http://origin.test/')), 'ok');
      expect(await authenticated.future, utf8.encode('user\u0000secret'));
      expect(await destinationType.future, localResolution ? 1 : 3);
      expect(hosts, localResolution ? ['origin.test'] : isEmpty);
    });
  }
}

class _SocketBytes {
  _SocketBytes(Socket socket) : _iterator = StreamIterator(socket);
  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = [];
  int _offset = 0;

  Future<List<int>> read(int count) async {
    final result = <int>[];
    while (result.length < count) {
      if (_offset == _chunk.length) {
        if (!await _iterator.moveNext()) {
          throw const SocketException('Unexpected EOF');
        }
        _chunk = _iterator.current;
        _offset = 0;
      }
      result.add(_chunk[_offset++]);
    }
    return result;
  }
}

String? _clientHelloServerName(List<int> record) {
  var offset = 5 + 4 + 2 + 32;
  offset += 1 + record[offset]; // session ID
  offset += 2 + (record[offset] << 8) + record[offset + 1]; // ciphers
  offset += 1 + record[offset]; // compression methods
  final end = offset + 2 + (record[offset] << 8) + record[offset + 1];
  offset += 2;
  while (offset + 4 <= end) {
    final type = (record[offset] << 8) + record[offset + 1];
    final length = (record[offset + 2] << 8) + record[offset + 3];
    offset += 4;
    if (type == 0) {
      final nameLength = (record[offset + 3] << 8) + record[offset + 4];
      return utf8.decode(record.sublist(offset + 5, offset + 5 + nameLength));
    }
    offset += length;
  }
  return null;
}
