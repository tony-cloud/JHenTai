import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/l18n/locale_text.dart';
import 'package:jhentai/pages/setting/network/setting_network_page.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';

class _ConfigService extends LocalConfigService {
  String? storedNetworkSetting;

  @override
  Future<int> write({
    required ConfigEnum configKey,
    String subConfigKey = '',
    required String value,
  }) async {
    if (configKey == ConfigEnum.networkSetting) {
      storedNetworkSetting = value;
    }
    return 1;
  }
}

void main() {
  final previousSetting = networkSetting;
  final previousConfig = localConfigService;
  final previousLogDir = log.logDirPath;
  late Directory logDirectory;
  late _ConfigService config;

  setUpAll(() async {
    logDirectory = await Directory.systemTemp.createTemp('jhentai-doh-settings-');
    log.logDirPath = logDirectory.path;
  });

  tearDownAll(() async {
    await log.clear();
    log.logDirPath = previousLogDir;
    if (await logDirectory.exists()) {
      await logDirectory.delete(recursive: true);
    }
  });

  setUp(() {
    networkSetting = NetworkSetting();
    localConfigService = config = _ConfigService();
    Get.testMode = true;
  });

  tearDown(() {
    networkSetting = previousSetting;
    localConfigService = previousConfig;
    Get.testMode = false;
  });

  test('Auto survives settings persistence without changing existing defaults or URLs', () async {
    expect(networkSetting.dnsOverHttpsEndpoint.value, NetworkSetting.defaultDohEndpoint);
    await networkSetting.saveDnsOverHttpsEndpoint(NetworkSetting.autoDohEndpoint);

    final restored = NetworkSetting()..applyBeanConfig(config.storedNetworkSetting!);
    expect(restored.dnsOverHttpsEndpoint.value, NetworkSetting.autoDohEndpoint);

    const ipv6Endpoint = 'https://[2606:4700:4700::1111]/dns-query';
    restored.applyBeanConfig(jsonEncode({'dnsOverHttpsEndpoint': ipv6Endpoint}));
    expect(restored.dnsOverHttpsEndpoint.value, ipv6Endpoint);
    restored.applyBeanConfig('{}');
    expect(restored.dnsOverHttpsEndpoint.value, ipv6Endpoint);
  });

  testWidgets('Auto is selected without displaying its sentinel and can switch to preset or URL',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    networkSetting.enableDnsOverHttps.value = true;
    final page = SettingNetworkPage();
    await tester.pumpWidget(GetMaterialApp(
      locale: const Locale('en', 'US'),
      fallbackLocale: const Locale('en', 'US'),
      translations: LocaleText(),
      home: page,
    ));

    final presetButton = find.byTooltip('Common DoH providers');
    final endpointField = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller == page.dnsOverHttpsController);
    await tester.tap(presetButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem<String> && widget.value == NetworkSetting.autoDohEndpoint));
    await tester.pumpAndSettle();

    expect(networkSetting.dnsOverHttpsEndpoint.value, NetworkSetting.autoDohEndpoint);
    expect(jsonDecode(config.storedNetworkSetting!)['dnsOverHttpsEndpoint'],
        NetworkSetting.autoDohEndpoint);
    expect(page.dnsOverHttpsController.text, isEmpty);
    expect(tester.widget<TextField>(endpointField).decoration!.hintText, 'Auto');

    await tester.tap(presetButton);
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<CheckedPopupMenuItem<String>>(find.byType(CheckedPopupMenuItem<String>))
            .singleWhere((item) => item.value == NetworkSetting.autoDohEndpoint)
            .checked,
        isTrue);
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem<String> &&
        widget.value == NetworkSetting.defaultDohEndpoint));
    await tester.pumpAndSettle();
    expect(networkSetting.dnsOverHttpsEndpoint.value, NetworkSetting.defaultDohEndpoint);
    expect(page.dnsOverHttpsController.text, NetworkSetting.defaultDohEndpoint);

    const customEndpoint = 'https://[2606:4700:4700::1001]/dns-query';
    await tester.enterText(endpointField, customEndpoint);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(networkSetting.dnsOverHttpsEndpoint.value, customEndpoint);
    expect(jsonDecode(config.storedNetworkSetting!)['dnsOverHttpsEndpoint'], customEndpoint);
  });
}
