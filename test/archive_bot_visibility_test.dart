import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/setting/archive_bot_setting.dart';
import 'package:jhentai/widget/eh_archive_parse_source_select_dialog.dart';

void main() {
  test('visibility defaults to hidden and survives a settings round trip', () {
    final setting = ArchiveBotSetting(hasJHServer: true);
    setting.applyBeanConfig('{"preferBotSource":true}');
    expect(setting.isVisible, isFalse);
    setting.hideArchiveBot.value = false;
    final restored = ArchiveBotSetting(hasJHServer: true)
      ..applyBeanConfig(setting.toConfigString());
    expect(restored.isVisible, isTrue);
    expect(restored.preferBotSource.value, isTrue);
  });

  test('settings cannot enable bots in a build without JH server credentials', () {
    final setting = ArchiveBotSetting(hasJHServer: false)
      ..applyBeanConfig('{"hideArchiveBot":false,"apiKey":"test"}');
    expect(setting.isVisible, isFalse);
    expect(setting.isReady, isFalse);
  });

  for (final configuration in [
    (supported: true, hidden: false),
    (supported: true, hidden: true),
    (supported: false, hidden: false),
  ]) {
    testWidgets('archive source choices respect $configuration', (tester) async {
      final previous = archiveBotSetting;
      archiveBotSetting = ArchiveBotSetting(hasJHServer: configuration.supported)
        ..hideArchiveBot.value = configuration.hidden;
      addTearDown(() => archiveBotSetting = previous);
      await tester.pumpWidget(const MaterialApp(home: EHArchiveParseSourceSelectDialog()));
      expect(find.text('official'), findsOneWidget);
      expect(find.text('archiveBot'),
          configuration.supported && !configuration.hidden ? findsOneWidget : findsNothing);
    });
  }
}
