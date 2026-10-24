import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class DnsMessageAnswer {
  const DnsMessageAnswer({required this.addresses, required this.ttl});

  final List<InternetAddress> addresses;
  final Duration ttl;
}

/// The A/AAAA subset of DNS wire messages used by RFC 8484 DoH endpoints.
class DnsMessage {
  DnsMessage._();

  static Uint8List query(String host, int recordType) {
    if (recordType != 1 && recordType != 28) {
      throw ArgumentError.value(recordType, 'recordType');
    }
    final bytes = <int>[0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    for (final label in _normalize(host).split('.')) {
      final encoded = ascii.encode(label);
      if (encoded.isEmpty || encoded.length > 63) {
        throw const FormatException('Invalid DNS label');
      }
      bytes.addAll([encoded.length, ...encoded]);
    }
    bytes.add(0);
    if (bytes.length - 12 > 255) {
      throw const FormatException('DNS name too long');
    }
    bytes.addAll([0, recordType, 0, 1]);
    return Uint8List.fromList(bytes);
  }

  static DnsMessageAnswer parse(
    List<int> bytes, {
    required String host,
    required int recordType,
  }) {
    final reader = _DnsReader(bytes);
    reader.require(0, 12);
    if (bytes.length > 65535 || reader.u16(0) != 0) {
      throw const FormatException('Invalid DNS response ID or length');
    }
    final flags = reader.u16(2);
    if ((flags & 0x8000) == 0 || (flags & 0x7a0f) != 0 || reader.u16(4) != 1) {
      throw const FormatException('Failed, truncated or invalid DNS response');
    }
    final question = reader.name(12);
    reader.require(question.end, 4);
    final expectedHost = _normalize(host);
    if (question.value != expectedHost ||
        reader.u16(question.end) != recordType ||
        reader.u16(question.end + 2) != 1) {
      throw const FormatException('DNS response question mismatch');
    }

    int offset = question.end + 4;
    final answers = <_DnsRecord>[];
    final answerCount = reader.u16(6);
    final total = answerCount + reader.u16(8) + reader.u16(10);
    for (int index = 0; index < total; index++) {
      final owner = reader.name(offset);
      offset = owner.end;
      reader.require(offset, 10);
      final type = reader.u16(offset);
      final klass = reader.u16(offset + 2);
      final rawTtl = reader.u32(offset + 4);
      final length = reader.u16(offset + 8);
      offset += 10;
      reader.require(offset, length);
      if (type == 41 && (rawTtl >> 24) != 0) {
        throw const FormatException('Extended DNS error response');
      }
      if (index < answerCount && klass == 1) {
        final ttl = rawTtl > 0x7fffffff ? 0 : rawTtl;
        if (type == 5) {
          final target = reader.name(offset);
          if (target.end != offset + length) {
            throw const FormatException('Invalid DNS CNAME length');
          }
          answers.add(_DnsRecord(owner.value, ttl, target: target.value));
        } else if (type == recordType) {
          if (length != (recordType == 1 ? 4 : 16)) {
            throw const FormatException('Invalid DNS address length');
          }
          answers.add(_DnsRecord(
            owner.value,
            ttl,
            address: InternetAddress.fromRawAddress(
                Uint8List.fromList(bytes.sublist(offset, offset + length))),
          ));
        }
      }
      offset += length;
    }

    String current = expectedHost;
    final visited = <String>{};
    int? ttl;
    while (visited.add(current)) {
      final aliases =
          answers.where((answer) => answer.owner == current && answer.target != null).toList();
      if (aliases.isEmpty) {
        final addresses = <String, InternetAddress>{};
        for (final answer
            in answers.where((answer) => answer.owner == current && answer.address != null)) {
          addresses[answer.address!.address] = answer.address!;
          ttl = min(ttl ?? answer.ttl, answer.ttl);
        }
        return DnsMessageAnswer(
          addresses: addresses.values.toList(growable: false),
          ttl: Duration(seconds: ttl ?? 0),
        );
      }
      if (aliases.any((alias) => alias.target != aliases.first.target)) {
        throw const FormatException('Conflicting DNS aliases');
      }
      for (final alias in aliases) {
        ttl = min(ttl ?? alias.ttl, alias.ttl);
      }
      current = aliases.first.target!;
    }
    throw const FormatException('DNS alias cycle');
  }

  static String _normalize(String host) =>
      (host.endsWith('.') ? host.substring(0, host.length - 1) : host).toLowerCase();
}

class _DnsRecord {
  const _DnsRecord(this.owner, this.ttl, {this.target, this.address});
  final String owner;
  final int ttl;
  final String? target;
  final InternetAddress? address;
}

class _DnsReader {
  const _DnsReader(this.bytes);
  final List<int> bytes;

  void require(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw const FormatException('Truncated DNS message');
    }
  }

  int u16(int offset) {
    require(offset, 2);
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  int u32(int offset) => (u16(offset) << 16) | u16(offset + 2);

  ({String value, int end}) name(int start) {
    int offset = start;
    int? end;
    int expandedLength = 1;
    final labels = <String>[];
    final visited = <int>{};
    while (visited.add(offset)) {
      require(offset, 1);
      final length = bytes[offset];
      if ((length & 0xc0) == 0xc0) {
        final target = u16(offset) & 0x3fff;
        if (target < 12 || target >= offset) {
          throw const FormatException('Invalid DNS compression pointer');
        }
        end ??= offset + 2;
        offset = target;
        continue;
      }
      if (length > 63) {
        throw const FormatException('Invalid DNS label');
      }
      offset++;
      if (length == 0) {
        return (value: labels.join('.').toLowerCase(), end: end ?? offset);
      }
      require(offset, length);
      expandedLength += length + 1;
      if (expandedLength > 255) {
        throw const FormatException('DNS name too long');
      }
      labels.add(ascii.decode(bytes.sublist(offset, offset + length)));
      offset += length;
    }
    throw const FormatException('DNS compression cycle');
  }
}
