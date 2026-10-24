import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/service/doh_service.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/widget/eh_image_request_builder.dart';

class _ImageDohService extends DohService {
  final List<String> hosts = [];
  List<InternetAddress> addresses = [InternetAddress('192.0.2.20')];
  Future<List<InternetAddress>> Function(String host)? resolve;

  @override
  Future<List<InternetAddress>> lookup(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    hosts.add(host);
    if (resolve != null) {
      return resolve!(host);
    }
    return addresses;
  }
}

Widget _request(String url, {int revision = 0, int Function()? nextInstance}) {
  return MaterialApp(
    home: Column(
      children: [
        Text('Parent revision: $revision'),
        EHImageRequestBuilder(
          url: url,
          loadingBuilder: (_) => const Text('Resolving image'),
          builder: (_, fronting, headers, retry) => Column(
            children: [
              Text(fronting.url, key: const ValueKey('resolved-url')),
              Text(headers?['host'] ?? 'No Host override'),
              if (nextInstance != null) _RetryableImage(retry: retry, nextInstance: nextInstance),
            ],
          ),
        ),
      ],
    ),
  );
}

String _renderedUrl(WidgetTester tester) {
  return tester.widget<Text>(find.byKey(const ValueKey('resolved-url'))).data!;
}

class _RetryableImage extends StatefulWidget {
  final VoidCallback retry;
  final int Function() nextInstance;

  const _RetryableImage({required this.retry, required this.nextInstance});

  @override
  State<_RetryableImage> createState() => _RetryableImageState();
}

class _RetryableImageState extends State<_RetryableImage> {
  late final int instance;

  @override
  void initState() {
    super.initState();
    instance = widget.nextInstance();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: widget.retry,
      child: Text('Retry image instance $instance'),
    );
  }
}

void main() {
  final previousSettings = networkSetting;
  final previousDoh = dohService;
  late _ImageDohService resolver;

  setUp(() {
    networkSetting = NetworkSetting();
    networkSetting.enableDomainFronting.value = true;
    networkSetting.enableDnsOverHttps.value = true;
    resolver = _ImageDohService();
    dohService = resolver;
  });

  tearDown(() {
    networkSetting = previousSettings;
    dohService = previousDoh;
  });

  testWidgets('parent rebuild retains the prepared request and image child state', (tester) async {
    networkSetting.enableDnsOverHttps.value = false;
    int instances = 0;
    const url = 'https://ehgt.org/thumbnail.jpg';

    await tester.pumpWidget(_request(url, nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    final frontedUrl = _renderedUrl(tester);
    expect(NetworkSetting.host2IPs['ehgt.org'], contains(Uri.parse(frontedUrl).host));
    expect(find.text('ehgt.org'), findsOneWidget);
    expect(find.text('Retry image instance 1'), findsOneWidget);

    await tester.pumpWidget(_request(url, revision: 1, nextInstance: () => ++instances));
    await tester.pumpAndSettle();

    expect(find.text('Parent revision: 1'), findsOneWidget);
    expect(_renderedUrl(tester), frontedUrl);
    expect(find.text('Retry image instance 1'), findsOneWidget);
    expect(instances, 1);
    expect(resolver.hosts, isEmpty);
  });

  testWidgets('changing image URL resolves a new fronted request and recreates the child',
      (tester) async {
    int instances = 0;
    await tester
        .pumpWidget(_request('https://ehgt.org/first.jpg', nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/first.jpg');
    expect(instances, 1);

    const secondUrl = 'https://ehgt.org/second.jpg?size=small';
    await tester.pumpWidget(_request(secondUrl, nextInstance: () => ++instances));
    await tester.pumpAndSettle();

    expect(_renderedUrl(tester), 'https://192.0.2.20/second.jpg?size=small');
    expect(find.text('ehgt.org'), findsOneWidget);
    expect(find.text('Retry image instance 2'), findsOneWidget);
    expect(instances, 2);
    expect(resolver.hosts, ['ehgt.org', 'ehgt.org']);
  });

  testWidgets('DoH fronting uses the resolved IP URL with the original Host header',
      (tester) async {
    for (final host in ['ehgt.org', 'e-hentai.org']) {
      await tester.pumpWidget(_request('https://$host/thumbnail.jpg'));
      await tester.pumpAndSettle();
      expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
      expect(find.text(host), findsOneWidget);
    }
    expect(resolver.hosts, ['ehgt.org', 'e-hentai.org']);
  });

  testWidgets('EX fronting always uses static origin addresses even with DoH enabled',
      (tester) async {
    const url = 'https://exhentai.org/thumbnail.jpg';
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(NetworkSetting.host2IPs['exhentai.org'], contains(Uri.parse(_renderedUrl(tester)).host));
    expect(find.text('exhentai.org'), findsOneWidget);
    expect(resolver.hosts, isEmpty);

    networkSetting.enableDnsOverHttps.value = false;
    await tester.pumpAndSettle();
    expect(NetworkSetting.host2IPs['exhentai.org'], contains(Uri.parse(_renderedUrl(tester)).host));
    expect(find.text('exhentai.org'), findsOneWidget);
    expect(resolver.hosts, isEmpty);
  });

  testWidgets('same URL retry recreates image state while parent rebuild retains it',
      (tester) async {
    int instances = 0;
    const url = 'https://ehgt.org/thumbnail.jpg';

    await tester.pumpWidget(_request(url, nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(find.text('Retry image instance 1'), findsOneWidget);

    await tester.pumpWidget(_request(url, revision: 1, nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    expect(find.text('Parent revision: 1'), findsOneWidget);
    expect(find.text('Retry image instance 1'), findsOneWidget);
    expect(instances, 1);

    await tester.tap(find.text('Retry image instance 1'));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(find.text('Retry image instance 2'), findsOneWidget);
    expect(instances, 2);
    expect(resolver.hosts, ['ehgt.org', 'ehgt.org']);
  });

  testWidgets('routing mode and endpoint changes recreate a mounted image without parent rebuild',
      (tester) async {
    int instances = 0;
    const url = 'https://ehgt.org/thumbnail.jpg';
    await tester.pumpWidget(_request(url, nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(instances, 1);

    networkSetting.enableDnsOverHttps.value = false;
    await tester.pumpAndSettle();
    expect(NetworkSetting.host2IPs['ehgt.org'], contains(Uri.parse(_renderedUrl(tester)).host));
    expect(find.text('ehgt.org'), findsOneWidget);
    expect(instances, 2);

    networkSetting.enableDomainFronting.value = false;
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), url);
    expect(find.text('No Host override'), findsOneWidget);
    expect(instances, 3);

    networkSetting.enableDomainFronting.value = true;
    await tester.pumpAndSettle();
    expect(NetworkSetting.host2IPs['ehgt.org'], contains(Uri.parse(_renderedUrl(tester)).host));
    expect(instances, 4);

    networkSetting.enableDnsOverHttps.value = true;
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(find.text('ehgt.org'), findsOneWidget);
    expect(instances, 5);

    resolver.addresses = [InternetAddress('192.0.2.21')];
    networkSetting.dnsOverHttpsEndpoint.value = 'https://dns.example/dns-query';
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.21/thumbnail.jpg');
    expect(instances, 6);
    expect(resolver.hosts, ['ehgt.org', 'ehgt.org', 'ehgt.org']);
  });

  testWidgets('IPv6 toggle recreates a mounted image and ordinary rebuild retains the new child',
      (tester) async {
    resolver.addresses = [InternetAddress('2001:db8::20'), InternetAddress('192.0.2.20')];
    int instances = 0;
    const url = 'https://ehgt.org/thumbnail.jpg';
    await tester.pumpWidget(_request(url, nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://[2001:db8::20]/thumbnail.jpg');
    expect(instances, 1);

    networkSetting.enableIPv6.value = false;
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(find.text('Retry image instance 2'), findsOneWidget);
    expect(instances, 2);

    await tester.pumpWidget(_request(url, revision: 1, nextInstance: () => ++instances));
    await tester.pumpAndSettle();
    expect(instances, 2);
    expect(find.text('Retry image instance 2'), findsOneWidget);

    networkSetting.enableIPv6.value = true;
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://[2001:db8::20]/thumbnail.jpg');
    expect(find.text('Retry image instance 3'), findsOneWidget);
    expect(instances, 3);
    expect(resolver.hosts, ['ehgt.org', 'ehgt.org', 'ehgt.org']);
  });

  testWidgets('disposing the request removes routing setting listeners', (tester) async {
    await tester.pumpWidget(_request('https://ehgt.org/thumbnail.jpg'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    networkSetting.enableIPv6.value = false;
    networkSetting.enableDnsOverHttps.value = false;
    networkSetting.enableDomainFronting.value = false;
    networkSetting.dnsOverHttpsEndpoint.value = 'https://dns.example/dns-query';
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(resolver.hosts, ['ehgt.org']);
  });

  testWidgets('DNS failure presents a retry that resolves again', (tester) async {
    final reply = Completer<List<InternetAddress>>();
    resolver.resolve = (_) => reply.future;
    await tester.pumpWidget(_request('https://ehgt.org/thumbnail.jpg'));

    reply.completeError(const SocketException('DNS unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Resolving image'), findsNothing);
    expect(find.byKey(const ValueKey('resolved-url')), findsNothing);
    expect(find.byIcon(Icons.sentiment_very_dissatisfied), findsOneWidget);

    resolver.resolve = null;
    await tester.tap(find.byIcon(Icons.sentiment_very_dissatisfied));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(find.byIcon(Icons.sentiment_very_dissatisfied), findsNothing);
    expect(resolver.hosts, ['ehgt.org', 'ehgt.org']);
  });

  testWidgets('late DNS reply cannot replace a newer image URL', (tester) async {
    final firstReply = Completer<List<InternetAddress>>();
    final secondReply = Completer<List<InternetAddress>>();
    resolver.resolve = (host) => host == 'ehgt.org' ? firstReply.future : secondReply.future;

    await tester.pumpWidget(_request('https://ehgt.org/old.jpg'));
    await tester.pumpWidget(_request('https://e-hentai.org/new.jpg'));
    expect(find.text('Resolving image'), findsOneWidget);

    secondReply.complete([InternetAddress('192.0.2.22')]);
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.22/new.jpg');
    expect(find.text('e-hentai.org'), findsOneWidget);

    firstReply.complete([InternetAddress('192.0.2.21')]);
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.22/new.jpg');
    expect(find.text('ehgt.org'), findsNothing);
    expect(resolver.hosts, ['ehgt.org', 'e-hentai.org']);
  });
}
