import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/network/dns_message.dart';

List<int> hex(String value) => [
      for (int i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16),
    ];

List<int> response(List<List<int>> answers, {int type = 1}) => [
      ...hex('000081800001'),
      0,
      answers.length,
      0,
      0,
      0,
      0,
      ...hex('076578616d706c6503636f6d00'),
      0,
      type,
      0,
      1,
      ...answers.expand((record) => record),
    ];

void main() {
  test('encodes RFC 8484 query with zero ID and no TCP length prefix', () {
    expect(DnsMessage.query('Example.COM.', 1),
        hex('000001000001000000000000076578616d706c6503636f6d0000010001'));
    expect(DnsMessage.query('example.com', 28).sublist(25), [0, 28, 0, 1]);
    expect(() => DnsMessage.query('a..com', 1), throwsFormatException);
    expect(() => DnsMessage.query('${'a' * 64}.com', 1), throwsFormatException);
  });

  test('parses compressed A replies and ignores unrelated answers', () {
    final answer = DnsMessage.parse(
        response([
          hex('c00c000100010000001e0004c0000201'),
          hex('c00c000100010000003c0004c0000202'),
          hex('056f74686572c00c00010001000000010004c0000263'),
        ]),
        host: 'example.com',
        recordType: 1);
    expect(answer.addresses.map((address) => address.address), ['192.0.2.1', '192.0.2.2']);
    expect(answer.ttl, const Duration(seconds: 30));
  });

  test('parses IPv6 addresses', () {
    final answer = DnsMessage.parse(
        response([
          hex('c00c001c00010000002d001020010db8000000000000000000000001'),
        ], type: 28),
        host: 'example.com',
        recordType: 28);
    expect(answer.addresses.single.address, '2001:db8::1');
    expect(answer.ttl, const Duration(seconds: 45));
  });

  test('follows compressed CNAME and uses its shorter TTL including zero', () {
    for (final ttl in [0, 10]) {
      final answer = DnsMessage.parse(
          response([
            [...hex('c00c00050001000000'), ttl, ...hex('000805616c696173c00c')],
            hex('05616c696173c00c000100010000003c0004c0000201'),
          ]),
          host: 'example.com',
          recordType: 1);
      expect(answer.addresses.single.address, '192.0.2.1');
      expect(answer.ttl, Duration(seconds: ttl));
    }
  });

  test('rejects mismatched, truncated, failed and malformed replies', () {
    final valid = response([hex('c00c000100010000003c0004c0000201')]);
    for (final (offset, mask) in [(0, 1), (2, 0x80), (2, 2), (3, 1), (4, 1), (26, 1), (28, 1)]) {
      final invalid = Uint8List.fromList(valid);
      invalid[offset] ^= mask;
      expect(() => DnsMessage.parse(invalid, host: 'example.com', recordType: 1),
          throwsFormatException,
          reason: 'mutated byte $offset');
    }
    for (int length = 0; length < valid.length; length++) {
      expect(() => DnsMessage.parse(valid.sublist(0, length), host: 'example.com', recordType: 1),
          throwsFormatException);
    }
    final loop = response([hex('c01d000100010000003c0004c0000201')]);
    expect(() => DnsMessage.parse(loop, host: 'example.com', recordType: 1), throwsFormatException);
    expect(() => DnsMessage.parse(valid, host: 'other.com', recordType: 1), throwsFormatException);
  });
}
