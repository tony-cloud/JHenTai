part of 'socks_proxy.dart';

// A separate deadline for each candidate prevents an unreachable IPv6 route
// from consuming the entire connection timeout before trying an IPv4 answer.
final _managedClients = <WeakReference<_TransportHttpClient>>[];

const _candidateTimeout = Duration(seconds: 3);
const _finalCandidateTimeout = Duration(seconds: 30);

final class _NeutralSocketOverrides extends IOOverrides {}

final class _ConnectedSocketOverrides extends IOOverrides {
  _ConnectedSocketOverrides(this.socket);
  final Socket socket;

  @override
  Future<Socket> socketConnect(dynamic host, int port,
          {dynamic sourceAddress,
          int sourcePort = 0,
          Duration? timeout}) async =>
      socket;
}

class _TransportAttempt {
  final _result = Completer<Socket>();
  ConnectionTask<Socket>? _connecting;
  Socket? _socket;
  bool _cancelled = false;
  bool _expired = false;

  ConnectionTask<Socket> get task =>
      ConnectionTask.fromSocket(_result.future, cancel);

  void cancel() =>
      _cancelWithError(const SocketException('Connection attempt cancelled'));

  void _cancelWithError(SocketException error) {
    _cancelled = true;
    _connecting?.cancel();
    _socket?.destroy();
    if (!_result.isCompleted) {
      _result.completeError(error);
    }
  }

  void checkActive() {
    if (_cancelled || _expired) {
      throw const SocketException('Connection attempt cancelled');
    }
  }

  Future<Socket> connect(InternetAddress address, int port) async {
    checkActive();
    final connecting = await IOOverrides.runWithIOOverrides(
      () => Socket.startConnect(address, port),
      _NeutralSocketOverrides(),
    );
    _connecting = connecting;
    if (_cancelled || _expired) {
      connecting.cancel();
    }
    final socket = await connecting.socket;
    if (_cancelled || _expired) {
      socket.destroy();
      checkActive();
    }
    _socket = socket;
    return socket;
  }

  Future<Socket> track(Future<Socket> future) async {
    final socket = await future;
    if (_cancelled || _expired) {
      socket.destroy();
      checkActive();
    }
    _socket = socket;
    return socket;
  }

  Future<Socket> candidate(
      Future<Socket> Function() action, Duration timeout) async {
    _expired = false;
    try {
      return await action().timeout(timeout, onTimeout: () {
        _expired = true;
        _connecting?.cancel();
        _socket?.destroy();
        throw const SocketException('Address connection timed out');
      });
    } catch (_) {
      _connecting?.cancel();
      _socket?.destroy();
      rethrow;
    }
  }

  void run(Future<Socket> Function() action, Duration? timeout) {
    Future<void> work() async {
      try {
        final socket = await action();
        if (_cancelled || _result.isCompleted) {
          socket.destroy();
        } else {
          _result.complete(socket);
        }
      } catch (error, stack) {
        if (!_result.isCompleted) {
          _result.completeError(error, stack);
        }
      }
    }

    final timer = timeout == null
        ? null
        : Timer(
            timeout,
            () => _cancelWithError(
                SocketException('HTTP connection timed out after $timeout')));
    unawaited(work().whenComplete(() => timer?.cancel()));
  }
}

Future<List<InternetAddress>> _lookupAddresses(
    String host, LookupCallback? lookup, bool ipv6) async {
  // Uri.host can contain brackets around an IPv6 literal.
  final name = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final literal = InternetAddress.tryParse(name);
  final addresses = literal != null
      ? [literal]
      : await (lookup != null
          ? lookup(name,
              type: ipv6 ? InternetAddressType.any : InternetAddressType.IPv4)
          : IOOverrides.runWithIOOverrides(
              () => InternetAddress.lookup(name,
                  type: ipv6
                      ? InternetAddressType.any
                      : InternetAddressType.IPv4),
              _NeutralSocketOverrides(),
            ));
  final filtered = addresses
      .where((address) => ipv6 || address.type == InternetAddressType.IPv4)
      .toList();
  if (filtered.isEmpty) {
    throw SocketException('No permitted IP addresses for $host');
  }
  return filtered;
}

/// Captures setter-only TLS options while forwarding the complete HttpClient
/// interface. A connection factory owns TLS for direct and SOCKS connections;
/// HTTP proxies retain the SDK's CONNECT and certificate handling.
class _TransportHttpClient implements HttpClient {
  _TransportHttpClient(this._inner, this._context, this._lookup,
      this._enableIPv6, this._socks, this._connectionAddresses) {
    _lastIPv6 = _enableIPv6?.call() ?? true;
    _inner.connectionFactory = _connect;
    if (_socks != null) {
      findProxy = (_) => 'DIRECT';
    }
    _managedClients.add(WeakReference(this));
  }

  HttpClient _inner;
  late bool _lastIPv6;
  bool _closed = false;
  final _frontingAuthorities = <String>{};
  String Function(Uri)? _findProxy;
  Future<bool> Function(Uri, String, String?)? _authenticate;
  Future<bool> Function(String, int, String, String?)? _authenticateProxy;
  Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? _customFactory;
  final _credentials = <(Uri, String, HttpClientCredentials)>[];
  final _proxyCredentials = <(String, int, String, HttpClientCredentials)>[];
  final SecurityContext? _context;
  final LookupCallback? _lookup;
  final bool Function()? _enableIPv6;
  final SocksProxyConfiguration? _socks;
  final ConnectionAddressProvider? _connectionAddresses;
  bool Function(X509Certificate cert, String host, int port)? _badCertificate;
  void Function(String line)? _keyLog;

  void _refreshAddressPolicy() {
    final ipv6 = _enableIPv6?.call() ?? true;
    if (_closed || _lastIPv6 == ipv6) {
      return;
    }
    _lastIPv6 = ipv6;
    final old = _inner;
    final replacement = HttpOverrides.runWithHttpOverrides(
        () => HttpClient(context: _context), _PassthroughHttpOverrides());
    replacement
      ..idleTimeout = old.idleTimeout
      ..connectionTimeout = old.connectionTimeout
      ..maxConnectionsPerHost = old.maxConnectionsPerHost
      ..autoUncompress = old.autoUncompress
      ..userAgent = old.userAgent
      ..badCertificateCallback = _badCertificate
      ..keyLog = _keyLog
      ..findProxy = _findProxy
      ..authenticate = _authenticate
      ..authenticateProxy = _authenticateProxy
      ..connectionFactory = _customFactory ?? _connect;
    for (final (url, realm, credentials) in _credentials) {
      replacement.addCredentials(url, realm, credentials);
    }
    for (final (host, port, realm, credentials) in _proxyCredentials) {
      replacement.addProxyCredentials(host, port, realm, credentials);
    }
    _inner = replacement;
    old.close(force: true);
  }

  HttpClient get _ready {
    _refreshAddressPolicy();
    return _inner;
  }

  Future<ConnectionTask<Socket>> _connect(
      Uri uri, String? proxyHost, int? proxyPort) {
    final attempt = _TransportAttempt();
    final ipv6 = _enableIPv6?.call() ?? true;
    final badCertificate = _badCertificate;
    final keyLog = _keyLog;
    final timeout = connectionTimeout;
    attempt.run(() async {
      if (!ipv6) {
        final literal = InternetAddress.tryParse(
            uri.host.replaceAll('[', '').replaceAll(']', ''));
        if (literal?.type == InternetAddressType.IPv6) {
          throw const SocketException('IPv6 is disabled');
        }
      }
      final socks = _socks;
      final host = socks?.host ?? proxyHost ?? uri.host;
      final port = socks?.port ?? proxyPort ?? uri.port;
      final supplied =
          proxyHost == null ? await _connectionAddresses?.call(uri) : null;
      // HttpClient pools by URL authority, while a registered fronting route
      // may connect to an alternate IP specific to the original virtual host.
      // Keep these requests and their redirect descendants out of that pool.
      if (supplied != null) {
        _frontingAuthorities.add(_authority(uri));
      }
      final originAddresses = supplied
          ?.where((address) => ipv6 || address.type == InternetAddressType.IPv4)
          .toList();
      if (originAddresses != null && originAddresses.isEmpty) {
        throw SocketException('No permitted IP addresses for ${uri.host}');
      }
      final endpoints =
          socks == null && proxyHost == null && originAddresses != null
              ? originAddresses
              : await _lookupAddresses(host, _lookup, ipv6);
      attempt.checkActive();
      // Keep remote SOCKS DNS when no local resolver/policy is requested.
      final destinations = socks == null
          ? <InternetAddress?>[null]
          : originAddresses ??
              ((_lookup != null || !ipv6)
                  ? await _lookupAddresses(uri.host, _lookup, ipv6)
                  : <InternetAddress?>[
                      InternetAddress(uri.host, type: InternetAddressType.unix)
                    ]);
      var remainingCandidates = destinations.length * endpoints.length;
      Object? lastError;
      StackTrace? lastStack;
      for (final destination in destinations) {
        for (final endpoint in endpoints) {
          attempt.checkActive();
          remainingCandidates--;
          final candidateTimeout = remainingCandidates > 0
              ? _candidateTimeout
              : _finalCandidateTimeout;
          try {
            // Each candidate has its own owner. A timed-out TCP/TLS future may
            // finish later; it must not replace or close a subsequent socket.
            final candidate = _TransportAttempt();
            candidate._result.future.ignore();
            attempt._connecting = candidate.task;
            final socket = await candidate.candidate(() async {
              Socket socket = await candidate.connect(endpoint, port);
              if (socks != null) {
                final tunnel = await IOOverrides.runWithIOOverrides(
                  () => SocksTCPClient.connect([
                    ProxySettings(endpoint, port,
                        username: _normalize(socks.username),
                        password: _normalize(socks.password)),
                  ], destination!, uri.port),
                  _ConnectedSocketOverrides(socket),
                );
                candidate.checkActive();
                if (uri.scheme == 'https') {
                  socket = await candidate.track(tunnel.secure(uri.host,
                      context: _context,
                      onBadCertificate: badCertificate == null
                          ? null
                          : (cert) => badCertificate(cert, uri.host, uri.port),
                      keyLog: keyLog));
                } else {
                  socket = tunnel;
                }
              } else if (proxyHost == null && uri.scheme == 'https') {
                socket = await candidate.track(SecureSocket.secure(socket,
                    host: uri.host,
                    context: _context,
                    onBadCertificate: badCertificate == null
                        ? null
                        : (cert) => badCertificate(cert, uri.host, uri.port),
                    keyLog: keyLog));
              }
              return socket;
            },
                timeout == null || timeout > candidateTimeout
                    ? candidateTimeout
                    : timeout);
            return await attempt.track(Future.value(socket));
          } catch (error, stack) {
            attempt.checkActive();
            lastError = error;
            lastStack = stack;
          }
        }
      }
      Error.throwWithStackTrace(lastError!, lastStack!);
    }, timeout);
    return Future.value(attempt.task);
  }

  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {
    _badCertificate = callback;
    _inner.badCertificateCallback = callback;
  }

  @override
  set keyLog(void Function(String line)? callback) {
    _keyLog = callback;
    _inner.keyLog = callback;
  }

  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
              Uri url, String? proxyHost, int? proxyPort)?
          factory) {
    _customFactory = factory;
    _inner.connectionFactory = factory ?? _connect;
  }

  @override
  set findProxy(String Function(Uri url)? callback) {
    _findProxy = callback;
    _inner.findProxy = callback;
  }

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  set authenticate(
      Future<bool> Function(Uri url, String scheme, String? realm)? f) {
    _authenticate = f;
    _inner.authenticate = f;
  }

  @override
  set authenticateProxy(
      Future<bool> Function(
              String host, int port, String scheme, String? realm)?
          f) {
    _authenticateProxy = f;
    _inner.authenticateProxy = f;
  }

  @override
  void addCredentials(
      Uri url, String realm, HttpClientCredentials credentials) {
    _credentials.add((url, realm, credentials));
    _inner.addCredentials(url, realm, credentials);
  }

  @override
  void addProxyCredentials(
      String host, int port, String realm, HttpClientCredentials credentials) {
    _proxyCredentials.add((host, port, realm, credentials));
    _inner.addProxyCredentials(host, port, realm, credentials);
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _managedClients.removeWhere((reference) =>
        reference.target == null || identical(reference.target, this));
    _inner.close(force: force);
  }

  String _authority(Uri uri) => '${uri.scheme}://${uri.host}:${uri.port}';

  Future<HttpClientRequest> _wrapRequest(
      Future<HttpClientRequest> pending) async {
    final request = await pending;
    return _frontingAuthorities.contains(_authority(request.uri))
        ? _NonPersistentRequest(request)
        : request;
  }

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _wrapRequest(_ready.open(method, host, port, path));
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrapRequest(_ready.openUrl(method, url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _wrapRequest(_ready.get(host, port, path));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _wrapRequest(_ready.getUrl(url));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _wrapRequest(_ready.post(host, port, path));
  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _wrapRequest(_ready.postUrl(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _wrapRequest(_ready.put(host, port, path));
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _wrapRequest(_ready.putUrl(url));
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _wrapRequest(_ready.delete(host, port, path));
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _wrapRequest(_ready.deleteUrl(url));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _wrapRequest(_ready.patch(host, port, path));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _wrapRequest(_ready.patchUrl(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _wrapRequest(_ready.head(host, port, path));
  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _wrapRequest(_ready.headUrl(url));
}

/// The adapter may set persistentConnection after opening the request. Pin it
/// through the request API and again before any bytes can send the headers.
/// The SDK copies Connection: close when following redirects internally.
class _NonPersistentRequest implements HttpClientRequest {
  _NonPersistentRequest(this._inner) {
    _inner.persistentConnection = false;
  }
  final HttpClientRequest _inner;
  bool _outputStarted = false;

  void _beginOutput() {
    if (_outputStarted) {
      return;
    }
    _inner.headers.set(HttpHeaders.connectionHeader, 'close');
    _inner.persistentConnection = false;
    _outputStarted = true;
  }

  @override
  bool get persistentConnection => false;
  @override
  set persistentConnection(bool _) => _inner.persistentConnection = false;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  Future<HttpClientResponse> get done => _inner.done;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) {
    _beginOutput();
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _beginOutput();
    return _inner.addStream(stream);
  }

  @override
  void write(Object? object) {
    _beginOutput();
    _inner.write(object);
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    _beginOutput();
    _inner.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _beginOutput();
    _inner.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    _beginOutput();
    _inner.writeln(object);
  }

  @override
  Future<void> flush() {
    _beginOutput();
    return _inner.flush();
  }

  @override
  Future<HttpClientResponse> close() {
    _beginOutput();
    return _inner.close();
  }
}
