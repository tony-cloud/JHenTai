import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/service/image_block_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const assetPath = 'assets/blocked_hashes/test.txt';
  const hash = '0123456789abcdef0123456789abcdef01234567';

  setUp(() {
    rootBundle.clear();
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'AssetManifest.bin') {
        return const StandardMessageCodec().encodeMessage({
          assetPath: [
            {'asset': assetPath}
          ],
          'assets/unrelated.txt': [
            {'asset': 'assets/unrelated.txt'}
          ],
        });
      }
      if (key == assetPath) {
        return ByteData.sublistView(utf8.encode('#name: Test list\n$hash\n'));
      }
      // Modern Flutter builds have no AssetManifest.json.
      return null;
    });
  });

  tearDown(() {
    rootBundle.clear();
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', null);
  });

  test('startup loads built-in blocking lists from the binary manifest', () async {
    final service = ImageBlockService();
    await service.doInitBean();

    expect(service.builtInHashLists.single.assetPath, assetPath);
    expect(service.builtInHashLists.single.name, 'Test list');
    expect(service.shouldBlock(hash), ImageBlockReason.builtInHash);
  });
}
