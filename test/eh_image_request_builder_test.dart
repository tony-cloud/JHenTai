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
  }) {
    hosts.add(host);
    return resolve?.call(host) ?? Future.value(addresses);
  }
}

Widget _request(String url, {int revision = 0}) {
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

  testWidgets('parent rebuild retains the resolved image request', (tester) async {
    final reply = Completer<List<InternetAddress>>();
    resolver.resolve = (_) => reply.future;
    const url = 'https://ehgt.org/thumbnail.jpg';

    await tester.pumpWidget(_request(url));
    expect(find.text('Resolving image'), findsOneWidget);
    expect(resolver.hosts, ['ehgt.org']);

    reply.complete([InternetAddress('192.0.2.20')]);
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(find.text('ehgt.org'), findsOneWidget);

    resolver.resolve = null;
    resolver.addresses = [InternetAddress('192.0.2.21')];
    await tester.pumpWidget(_request(url, revision: 1));
    await tester.pumpAndSettle();

    expect(find.text('Parent revision: 1'), findsOneWidget);
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');
    expect(resolver.hosts, ['ehgt.org']);
  });

  testWidgets('changing image URL resolves the new request', (tester) async {
    await tester.pumpWidget(_request('https://ehgt.org/first.jpg'));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/first.jpg');

    resolver.addresses = [InternetAddress('192.0.2.21')];
    await tester.pumpWidget(_request('https://ehgt.org/second.jpg?size=small'));
    await tester.pumpAndSettle();

    expect(_renderedUrl(tester), 'https://192.0.2.21/second.jpg?size=small');
    expect(resolver.hosts, ['ehgt.org', 'ehgt.org']);
  });

  testWidgets('same URL retry recreates image state while parent rebuild retains it',
      (tester) async {
    networkSetting.enableDomainFronting.value = false;
    int instances = 0;
    const url = 'https://ehgt.org/thumbnail.jpg';

    Widget request({int revision = 0}) {
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
                  _RetryableImage(retry: retry, nextInstance: () => ++instances),
                ],
              ),
            ),
          ],
        ),
      );
    }

    await tester.pumpWidget(request());
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), url);
    expect(find.text('Retry image instance 1'), findsOneWidget);

    await tester.pumpWidget(request(revision: 1));
    await tester.pumpAndSettle();
    expect(find.text('Parent revision: 1'), findsOneWidget);
    expect(find.text('Retry image instance 1'), findsOneWidget);
    expect(instances, 1);

    await tester.tap(find.text('Retry image instance 1'));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), url);
    expect(find.text('Retry image instance 2'), findsOneWidget);
    expect(instances, 2);
    expect(resolver.hosts, isEmpty);
  });

  testWidgets('network setting changes update routing on rebuild', (tester) async {
    const url = 'https://ehgt.org/thumbnail.jpg';
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.20/thumbnail.jpg');

    networkSetting.enableDomainFronting.value = false;
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), url);
    expect(find.text('No Host override'), findsOneWidget);
    expect(resolver.hosts, hasLength(1));

    networkSetting.enableDomainFronting.value = true;
    resolver.addresses = [InternetAddress('192.0.2.21')];
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.21/thumbnail.jpg');
    expect(resolver.hosts, hasLength(2));

    networkSetting.enableDnsOverHttps.value = false;
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(NetworkSetting.host2IPs['ehgt.org'], contains(Uri.parse(_renderedUrl(tester)).host));
    expect(resolver.hosts, hasLength(2));

    networkSetting.enableDnsOverHttps.value = true;
    resolver.addresses = [InternetAddress('192.0.2.22')];
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.22/thumbnail.jpg');
    expect(resolver.hosts, hasLength(3));

    networkSetting.dnsOverHttpsEndpoint.value = 'https://dns.example/dns-query';
    resolver.addresses = [InternetAddress('192.0.2.23')];
    await tester.pumpWidget(_request(url));
    await tester.pumpAndSettle();
    expect(_renderedUrl(tester), 'https://192.0.2.23/thumbnail.jpg');
    expect(resolver.hosts, hasLength(4));
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
