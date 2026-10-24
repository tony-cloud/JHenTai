import 'dart:io';

/// System DNS fallback and DoH bootstrap must obey the same address policy.
Future<List<InternetAddress>> lookupSystemAddresses(
  String host, {
  InternetAddressType type = InternetAddressType.any,
  bool enableIPv6 = true,
}) async {
  if (!enableIPv6 && type == InternetAddressType.IPv6) {
    return [];
  }
  final effectiveType = enableIPv6 ? type : InternetAddressType.IPv4;
  final name =
      host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
  final literal = InternetAddress.tryParse(name);
  if (literal != null) {
    return effectiveType == InternetAddressType.any || literal.type == effectiveType
        ? [literal]
        : [];
  }
  return InternetAddress.lookup(name, type: effectiveType);
}
