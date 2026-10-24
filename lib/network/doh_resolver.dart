import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:jhentai/network/dns_message.dart';

/// Shared DNS-over-HTTPS resolution for the main and download isolates.
///
/// The caller owns system-DNS fallback and the transport's proxy configuration.
class DohResolver {
  static const String autoEndpoint = 'auto';
  static const Duration _defaultTtl = Duration(minutes: 5);
  static const Set<int> _jsonUnsupportedStatuses = {400, 404, 405, 406, 415};

  DohResolver({
    required Dio dio,
    required List<String> autoEndpoints,
    DateTime Function()? now,
  })  : _dio = dio,
        _autoEndpoints = autoEndpoints
            .map((endpoint) => endpoint.trim())
            .where((endpoint) => endpoint.isNotEmpty)
            .toSet()
            .toList(),
        _now = now ?? DateTime.now;

  final Dio _dio;
  final List<String> _autoEndpoints;
  final DateTime Function() _now;
  final Map<String, _LookupResult> _cache = {};
  final Map<String, Future<List<InternetAddress>>> _pending = {};
  final Map<String, _Protocol> _protocols = {};
  _Selection? _selection;
  Future<void>? _discovery;
  int _generation = 0;

  Future<List<InternetAddress>> lookup(
    String host, {
    required String endpoint,
    InternetAddressType type = InternetAddressType.any,
    bool enableIPv6 = true,
  }) {
    if (!enableIPv6 && type == InternetAddressType.IPv6) {
      return Future.value(const []);
    }
    final InternetAddressType effectiveType = enableIPv6 ? type : InternetAddressType.IPv4;
    final InternetAddress? literal = InternetAddress.tryParse(_unbracket(host));
    if (literal != null) {
      return Future.value(effectiveType == InternetAddressType.any || literal.type == effectiveType
          ? [literal]
          : <InternetAddress>[]);
    }

    final String selection = endpoint.trim();
    final String name = host.trim().toLowerCase();
    final String key = '$selection\n$name\n${effectiveType.name}\n$enableIPv6';
    final _LookupResult? cached = _cache[key];
    if (cached != null && cached.expiresAt.isAfter(_now())) {
      return Future.value(cached.addresses);
    }
    _cache.remove(key);
    final Future<List<InternetAddress>>? pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    final int generation = _generation;
    late final Future<List<InternetAddress>> lookup;
    lookup = (() async {
      try {
        final _LookupResult result = selection == autoEndpoint
            ? await _resolveAuto(name, effectiveType, generation, enableIPv6)
            : await _resolveEndpoint(selection, name, effectiveType, generation, enableIPv6);
        if (generation == _generation && result.expiresAt.isAfter(_now())) {
          _cache[key] = result;
        }
        return result.addresses;
      } finally {
        if (identical(_pending[key], lookup)) {
          _pending.remove(key);
        }
      }
    })();
    _pending[key] = lookup;
    return lookup;
  }

  /// Invalidates completed and in-flight work without cancelling callers.
  void clear() {
    _generation++;
    _cache.clear();
    _pending.clear();
    _protocols.clear();
    _selection = null;
    _discovery = null;
  }

  Future<_LookupResult> _resolveAuto(
      String host, InternetAddressType type, int generation, bool enableIPv6) async {
    final Set<String> failed = {};
    while (true) {
      final _Selection? selected = generation == _generation ? _selection : null;
      if (selected != null &&
          selected.expiresAt.isAfter(_now()) &&
          !failed.contains(selected.endpoint) &&
          _endpointAllowed(selected.endpoint, enableIPv6)) {
        try {
          final _LookupResult result =
              await _resolveEndpoint(selected.endpoint, host, type, generation, enableIPv6);
          // A later domain can shorten the lease, but cannot perpetually renew it.
          if (generation == _generation &&
              identical(_selection, selected) &&
              result.expiresAt.isBefore(selected.expiresAt)) {
            selected.expiresAt = result.expiresAt;
          }
          return result;
        } catch (_) {
          failed.add(selected.endpoint);
          if (generation == _generation && identical(_selection, selected)) {
            _selection = null;
          }
        }
      }

      // Only discovery is serialized. Once selected, independent DNS queries can
      // run concurrently without every thumbnail probing the provider list.
      final Future<void>? discovery = generation == _generation ? _discovery : null;
      if (discovery != null) {
        await discovery;
        continue;
      }
      final Completer<void> completed = Completer<void>();
      if (generation == _generation) {
        _discovery = completed.future;
      }
      try {
        for (final String endpoint in _autoEndpoints) {
          if (failed.contains(endpoint) || !_endpointAllowed(endpoint, enableIPv6)) {
            continue;
          }
          try {
            final _LookupResult result =
                await _resolveEndpoint(endpoint, host, type, generation, enableIPv6);
            if (generation == _generation) {
              _selection = _Selection(endpoint, result.expiresAt);
            }
            return result;
          } catch (_) {
            failed.add(endpoint);
          }
        }
        throw SocketException('No DNS-over-HTTPS endpoint resolved $host');
      } finally {
        if (identical(_discovery, completed.future)) {
          _discovery = null;
        }
        completed.complete();
      }
    }
  }

  Future<_LookupResult> _resolveEndpoint(String endpoint, String host, InternetAddressType type,
      int generation, bool enableIPv6) async {
    if (!_endpointAllowed(endpoint, enableIPv6)) {
      throw const SocketException('IPv6 DNS-over-HTTPS endpoint is disabled');
    }
    final List<int> recordTypes = [
      if (type == InternetAddressType.any || type == InternetAddressType.IPv4) 1,
      if (type == InternetAddressType.any || type == InternetAddressType.IPv6) 28,
    ];
    final List<_LookupResult?> results = await Future.wait(recordTypes.map((recordType) async {
      try {
        return await _query(endpoint, host, recordType, generation);
      } catch (_) {
        // An unavailable family must not discard the other family's addresses.
        return null;
      }
    }));
    final List<_LookupResult> usable =
        results.whereType<_LookupResult>().where((result) => result.addresses.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw SocketException('DNS-over-HTTPS endpoint $endpoint did not resolve $host');
    }
    return _LookupResult(
      List.unmodifiable(usable.expand((result) => result.addresses).toSet()),
      usable.map((result) => result.expiresAt).reduce((a, b) => a.isBefore(b) ? a : b),
    );
  }

  bool _endpointAllowed(String endpoint, bool enableIPv6) {
    final Uri? uri = Uri.tryParse(endpoint);
    return enableIPv6 ||
        uri == null ||
        InternetAddress.tryParse(_unbracket(uri.host))?.type != InternetAddressType.IPv6;
  }

  String _unbracket(String host) =>
      host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;

  Future<_LookupResult> _query(String endpoint, String host, int recordType, int generation) async {
    if (_protocols[endpoint] == _Protocol.wire) {
      return _queryWire(endpoint, host, recordType, generation);
    }
    try {
      return await _queryJson(endpoint, host, recordType);
    } on _UnsupportedJson {
      return _queryWire(endpoint, host, recordType, generation);
    } on DioException catch (error) {
      if (_jsonUnsupportedStatuses.contains(error.response?.statusCode)) {
        return _queryWire(endpoint, host, recordType, generation);
      }
      rethrow;
    }
  }

  Uri _queryUri(String endpoint, Map<String, String> parameters) {
    final Uri base = Uri.parse(endpoint);
    if (!base.hasAuthority || (base.scheme != 'https' && base.scheme != 'http')) {
      throw const FormatException('Invalid DNS-over-HTTPS endpoint');
    }
    final Map<String, dynamic> query = Map.of(base.queryParametersAll);
    query.remove('name');
    query.remove('type');
    query.remove('dns');
    query.addAll(parameters);
    return base.replace(queryParameters: query);
  }

  Future<_LookupResult> _queryJson(String endpoint, String host, int recordType) async {
    final Response<dynamic> response = await _getUri<dynamic>(
      _queryUri(endpoint, {'name': host, 'type': '$recordType'}),
      options:
          Options(headers: {'accept': 'application/dns-json'}, responseType: ResponseType.plain),
    );
    if (_jsonUnsupportedStatuses.contains(response.statusCode)) {
      throw const _UnsupportedJson();
    }
    dynamic data = response.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        throw const _UnsupportedJson();
      }
    }
    if (data is! Map || data['Status'] is! num) {
      throw const _UnsupportedJson();
    }
    if (data['Status'] != 0 || data['TC'] == true) {
      throw const FormatException('Unusable DNS JSON response');
    }
    final dynamic answers = data['Answer'];
    if (answers is! List) {
      return _LookupResult(const [], _now());
    }
    final Set<String> names = {_dnsName(host)};
    // Answers need not be ordered; follow only aliases reachable from the
    // question before considering address records or their TTLs.
    bool changed = true;
    while (changed) {
      changed = false;
      for (final dynamic answer in answers) {
        if (answer is Map &&
            answer['type'] == 5 &&
            answer['data'] is String &&
            (answer['name'] == null ||
                (answer['name'] is String && names.contains(_dnsName(answer['name']))))) {
          changed = names.add(_dnsName(answer['data'])) || changed;
        }
      }
    }
    final List<InternetAddress> addresses = [];
    Duration? ttl;
    for (final dynamic answer in answers) {
      if (answer is! Map) {
        continue;
      }
      final dynamic owner = answer['name'];
      if (owner != null && (owner is! String || !names.contains(_dnsName(owner)))) {
        continue;
      }
      final dynamic answerType = answer['type'];
      if (answerType != recordType && answerType != 5) {
        continue;
      }
      if (answerType == recordType) {
        final dynamic value = answer['data'];
        final InternetAddress? address = value is String ? InternetAddress.tryParse(value) : null;
        final InternetAddressType expectedType =
            recordType == 1 ? InternetAddressType.IPv4 : InternetAddressType.IPv6;
        if (address == null || address.type != expectedType) {
          continue;
        }
        addresses.add(address);
      }
      final dynamic seconds = answer['TTL'];
      final Duration recordTtl = seconds is num && seconds.isFinite
          ? Duration(seconds: seconds < 0 ? 0 : seconds.toInt())
          : _defaultTtl;
      ttl = ttl == null || recordTtl < ttl ? recordTtl : ttl;
    }
    return _LookupResult(addresses, _expiresAt(response, ttl ?? _defaultTtl));
  }

  String _dnsName(String name) => name.toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  Future<_LookupResult> _queryWire(
      String endpoint, String host, int recordType, int generation) async {
    final String question =
        base64Url.encode(DnsMessage.query(host, recordType)).replaceAll('=', '');
    final Response<List<int>> response = await _getUri<List<int>>(
      _queryUri(endpoint, {'dns': question}),
      options:
          Options(headers: {'accept': 'application/dns-message'}, responseType: ResponseType.bytes),
    );
    final DnsMessageAnswer answer =
        DnsMessage.parse(response.data ?? const [], host: host, recordType: recordType);
    if (generation == _generation) {
      _protocols[endpoint] = _Protocol.wire;
    }
    return _LookupResult(answer.addresses, _expiresAt(response, answer.ttl));
  }

  Future<Response<T>> _getUri<T>(Uri uri, {required Options options}) {
    // Bootstrap the resolver and any configured proxy through system DNS.
    // Otherwise the application's global socket lookup calls this resolver
    // again before it can establish its own HTTPS connection.
    return IOOverrides.runWithIOOverrides(
      () => _dio.getUri<T>(uri, options: options),
      _DohIOOverrides(),
    );
  }

  DateTime _expiresAt(Response<dynamic> response, Duration ttl) {
    final List<String>? ageValues = response.headers['age'];
    final int age =
        ageValues == null || ageValues.isEmpty ? 0 : int.tryParse(ageValues.first.trim()) ?? 0;
    final Duration remaining = ttl - Duration(seconds: age > 0 ? age : 0);
    return _now().add(remaining.isNegative ? Duration.zero : remaining);
  }
}

final class _DohIOOverrides extends IOOverrides {}

enum _Protocol { wire }

class _UnsupportedJson implements Exception {
  const _UnsupportedJson();
}

class _LookupResult {
  const _LookupResult(this.addresses, this.expiresAt);

  final List<InternetAddress> addresses;
  final DateTime expiresAt;
}

class _Selection {
  _Selection(this.endpoint, this.expiresAt);

  final String endpoint;
  DateTime expiresAt;
}
