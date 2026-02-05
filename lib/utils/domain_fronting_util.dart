import 'package:jhentai/network/eh_ip_provider.dart';
import 'package:jhentai/setting/network_setting.dart';

class DomainFrontingResult {
  const DomainFrontingResult({
    required this.url,
    this.originalHost,
    this.ip,
  });

  final String url;
  final String? originalHost;
  final String? ip;

  bool get applied => originalHost != null && ip != null;

  Map<String, String>? get headers => applied ? <String, String>{'host': originalHost!} : null;
}

class DomainFrontingUtil {
  DomainFrontingUtil._();

  static final EHIpProvider _ipProvider = RoundRobinIpProvider(NetworkSetting.host2IPs);

  static DomainFrontingResult build(String rawUrl) {
    Uri uri;
    try {
      uri = Uri.parse(rawUrl);
    } on FormatException {
      return DomainFrontingResult(url: rawUrl);
    }

    if (!shouldFront(uri.host)) {
      return DomainFrontingResult(url: rawUrl);
    }

    final String ip = _ipProvider.nextIP(uri.host);
    final Uri frontedUri = uri.replace(host: ip);

    return DomainFrontingResult(
      url: frontedUri.toString(),
      originalHost: uri.host,
      ip: ip,
    );
  }

  static bool shouldFront(String host) {
    return networkSetting.enableDomainFronting.value && _ipProvider.supports(host);
  }

  static void markUnavailable(String host, String ip) {
    _ipProvider.addUnavailableIp(host, ip);
  }

  static void markUnavailableFromResult(DomainFrontingResult result) {
    if (!result.applied) {
      return;
    }
    markUnavailable(result.originalHost!, result.ip!);
  }
}
