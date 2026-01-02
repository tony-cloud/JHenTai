import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:zxing2/qrcode.dart';

ImageBlockService imageBlockService = ImageBlockService();

enum BlockedImageHandling { hide, placeholder }

enum ImageBlockReason { hash, builtInHash, qrCode }

class ImageBlockService with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxBool enableHashBlocking = true.obs;
  RxBool enableQrBlocking = false.obs;
  RxBool useBuiltInList = true.obs;
  Rx<BlockedImageHandling> blockedImageHandling = BlockedImageHandling.placeholder.obs;
  RxSet<String> userBlockedHashes = <String>{}.obs;
  RxSet<String> qrBlockedHashes = <String>{}.obs;

  final Set<String> builtInBlockedHashes = {
    'a1a1ad7f2fd9d0c447ddb5a0f0c5bc3c',
    '4e3d70f7ae404c9089c9ed24b7b0f2c4',
  };

  final Set<String> _scannedKeys = {};
  final Set<String> _scanningKeys = {};
  final RxInt _version = 0.obs;

  RxInt get version => _version;

  @override
  ConfigEnum get configEnum => ConfigEnum.imageBlockSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    enableHashBlocking.value = map['enableHashBlocking'] ?? enableHashBlocking.value;
    enableQrBlocking.value = map['enableQrBlocking'] ?? enableQrBlocking.value;
    useBuiltInList.value = map['useBuiltInList'] ?? useBuiltInList.value;
    blockedImageHandling.value = BlockedImageHandling
        .values[map['blockedImageHandling'] ?? blockedImageHandling.value.index];

    userBlockedHashes
      ..clear()
      ..addAll(Set<String>.from(map['userBlockedHashes'] ?? const <String>[]))
      ..refresh();
    qrBlockedHashes
      ..clear()
      ..addAll(Set<String>.from(map['qrBlockedHashes'] ?? const <String>[]))
      ..refresh();
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enableHashBlocking': enableHashBlocking.value,
      'enableQrBlocking': enableQrBlocking.value,
      'useBuiltInList': useBuiltInList.value,
      'blockedImageHandling': blockedImageHandling.value.index,
      'userBlockedHashes': userBlockedHashes.toList(),
      'qrBlockedHashes': qrBlockedHashes.toList(),
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  ImageBlockReason? shouldBlock(String? imageHash, {String? fallbackKey}) {
    String? key = _normalizeKey(imageHash, fallbackKey);
    if (enableHashBlocking.isTrue && key != null) {
      if (userBlockedHashes.contains(key)) {
        return ImageBlockReason.hash;
      }
      if (useBuiltInList.isTrue && builtInBlockedHashes.contains(key)) {
        return ImageBlockReason.builtInHash;
      }
    }

    if (enableQrBlocking.isTrue && key != null && qrBlockedHashes.contains(key)) {
      return ImageBlockReason.qrCode;
    }

    return null;
  }

  Future<void> addUserBlockedHash(String hash) async {
    String? normalized = _normalizeString(hash);
    if (normalized == null) {
      return;
    }
    if (userBlockedHashes.contains(normalized)) {
      return;
    }

    userBlockedHashes.add(normalized);
    userBlockedHashes.refresh();
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveEnableHashBlocking(bool value) async {
    enableHashBlocking.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveEnableQrBlocking(bool value) async {
    enableQrBlocking.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveUseBuiltInList(bool value) async {
    useBuiltInList.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveBlockedImageHandling(BlockedImageHandling handling) async {
    blockedImageHandling.value = handling;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> removeUserBlockedHash(String hash) async {
    String? normalized = _normalizeString(hash);
    if (normalized == null) {
      return;
    }
    if (!userBlockedHashes.remove(normalized)) {
      return;
    }

    userBlockedHashes.refresh();
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> clearUserBlockedHashes() async {
    if (userBlockedHashes.isEmpty) {
      return;
    }

    userBlockedHashes.clear();
    userBlockedHashes.refresh();
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> clearQrBlockedHashes() async {
    if (qrBlockedHashes.isEmpty) {
      return;
    }

    qrBlockedHashes.clear();
    qrBlockedHashes.refresh();
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<bool> scanQrIfNeeded({
    String? imageHash,
    String? fallbackKey,
    required Future<Object?> Function() bytesLoader,
  }) async {
    String? key = _normalizeKey(imageHash, fallbackKey);
    if (enableQrBlocking.isFalse || key == null) {
      return false;
    }
    if (qrBlockedHashes.contains(key)) {
      return true;
    }
    if (_scannedKeys.contains(key) || _scanningKeys.contains(key)) {
      return false;
    }

    _scanningKeys.add(key);
    try {
      Object? data = await bytesLoader();
      img.Image? image;
      if (data is Uint8List) {
        image = img.decodeImage(data);
      } else if (data is ui.Image) {
        image = await _convertUiImageToImgImage(data);
      }

      if (image == null) {
        return false;
      }

      _scannedKeys.add(key);
      bool blocked = await _containsQrCode(image);
      if (!blocked) {
        return false;
      }

      qrBlockedHashes.add(key);
      qrBlockedHashes.refresh();
      await saveBeanConfig();
      _bumpVersion();
      log.info('Image blocked due to QR code, key: $key');
      return true;
    } catch (e, stack) {
      log.error('Scan QR code failed, key: $key', e, stack);
      return false;
    } finally {
      _scanningKeys.remove(key);
    }
  }

  String? buildCacheKey(GalleryImage image) {
    return _normalizeKey(image.imageHash, image.path ?? image.url);
  }

  Future<img.Image?> _convertUiImageToImgImage(ui.Image image) async {
    ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      return null;
    }

    return img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: data.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }

  Future<bool> _containsQrCode(img.Image image) async {
    try {
      LuminanceSource source = RGBLuminanceSource(
        image.width,
        image.height,
        image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
      );
      BinaryBitmap bitmap = BinaryBitmap(HybridBinarizer(source));
      QRCodeReader reader = QRCodeReader();
      reader.decode(bitmap);
      log.debug('QR code detected in image for blocking');
      return true;
    } on NotFoundException {
      // No QR code found in the image
      log.debug('No QR code found in image');
      return false;
    } on FormatReaderException {
      // QR code found but couldn't be decoded properly
      log.debug('QR code found but format is invalid');
      return true;
    } on ChecksumException {
      // QR code found but checksum validation failed
      // Again, for blocking ads, you might want to return true
      log.debug('QR code found but checksum validation failed');
      return true;
    } catch (e) {
      // Any other error - assume no QR code
      log.error('Error while scanning QR code: $e');
      return false;
    }
  }

  String? _normalizeKey(String? imageHash, String? fallbackKey) {
    return _normalizeString(imageHash) ?? _normalizeString(fallbackKey);
  }

  String? _normalizeString(String? value) {
    if (value == null) {
      return null;
    }
    String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed.toLowerCase();
  }

  void _bumpVersion() {
    _version.value++;
  }
}
