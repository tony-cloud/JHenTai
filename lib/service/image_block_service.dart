import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:dio/dio.dart' as dio;
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/database/database.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:zxing2/qrcode.dart';

ImageBlockService imageBlockService = ImageBlockService();

enum BlockedImageHandling { hide, placeholder }

enum ImageBlockReason { hash, builtInHash, qrCode }

enum QrBlockMode { normal, advanced, superRange }

const String _defaultQrFilterTag = 'other:"extraneous ads\$"';

class ImageBlockService with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxBool enableHashBlocking = true.obs;
  RxBool enableQrBlocking = false.obs;
  RxBool enableQrBlockingForTags = false.obs;
  RxBool useBuiltInList = true.obs;
  RxBool autoUpdateExternalHashFiles = false.obs;
  Rx<BlockedImageHandling> blockedImageHandling = BlockedImageHandling.placeholder.obs;
  Rx<QrBlockMode> qrBlockMode = QrBlockMode.normal.obs;
  RxInt qrScanTailCount = 0.obs;
  RxSet<String> userBlockedHashes = <String>{}.obs;
  RxSet<String> qrBlockedHashes = <String>{}.obs;
  RxList<String> qrBlockingTagFilters = <String>[_defaultQrFilterTag].obs;

  final Set<String> builtInBlockedHashes = <String>{};
  RxList<BuiltInHashList> builtInHashLists = <BuiltInHashList>[].obs;
  RxList<ExternalHashFile> externalHashFiles = <ExternalHashFile>[].obs;
  final Set<String> _externalBlockedHashes = <String>{};

  final Set<String> _scannedKeys = {};
  final Set<String> _scanningKeys = {};
  final RxInt _version = 0.obs;
  List<_QrTagRule> _qrTagRules = [];
  Map<String, bool> _builtInListEnabledConfig = {};

  final dio.Dio _dio = dio.Dio(
    dio.BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      responseType: dio.ResponseType.plain,
    ),
  );

  RxInt get version => _version;

  @override
  ConfigEnum get configEnum => ConfigEnum.imageBlockSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    enableHashBlocking.value = map['enableHashBlocking'] ?? enableHashBlocking.value;
    enableQrBlocking.value = map['enableQrBlocking'] ?? enableQrBlocking.value;
    enableQrBlockingForTags.value = map['enableQrBlockingForTags'] ?? enableQrBlockingForTags.value;
    useBuiltInList.value = map['useBuiltInList'] ?? useBuiltInList.value;
    autoUpdateExternalHashFiles.value =
        map['autoUpdateExternalHashFiles'] ?? autoUpdateExternalHashFiles.value;
    blockedImageHandling.value = BlockedImageHandling
        .values[map['blockedImageHandling'] ?? blockedImageHandling.value.index];

    int? rawQrBlockMode = map['qrBlockMode'] as int?;
    if (rawQrBlockMode != null &&
        rawQrBlockMode >= 0 &&
        rawQrBlockMode < QrBlockMode.values.length) {
      qrBlockMode.value = QrBlockMode.values[rawQrBlockMode];
    }

    int? rawTailCount = map['qrScanTailCount'] as int?;
    if (rawTailCount != null && rawTailCount >= 0) {
      qrScanTailCount.value = rawTailCount;
    }

    userBlockedHashes
      ..clear()
      ..addAll(Set<String>.from(map['userBlockedHashes'] ?? const <String>[]))
      ..refresh();
    qrBlockedHashes
      ..clear()
      ..addAll(Set<String>.from(map['qrBlockedHashes'] ?? const <String>[]))
      ..refresh();
    qrBlockingTagFilters
      ..clear()
      ..addAll(List<String>.from(map['qrBlockingTagFilters'] ?? const <String>[]));
    if (qrBlockingTagFilters.isEmpty) {
      qrBlockingTagFilters.add(_defaultQrFilterTag);
    }
    qrBlockingTagFilters.refresh();
    _qrTagRules = _parseQrTagFilters(qrBlockingTagFilters);

    externalHashFiles
      ..clear()
      ..addAll(_parseExternalHashFiles(map['externalHashFiles']))
      ..refresh();
    _rebuildExternalHashCache();

    Map<String, dynamic>? rawBuiltInStates = map['builtInHashListStates'] as Map<String, dynamic>?;
    if (rawBuiltInStates != null) {
      _builtInListEnabledConfig = rawBuiltInStates.map(
        (String key, dynamic value) => MapEntry(key, value == true),
      );
    }
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enableHashBlocking': enableHashBlocking.value,
      'enableQrBlocking': enableQrBlocking.value,
      'enableQrBlockingForTags': enableQrBlockingForTags.value,
      'useBuiltInList': useBuiltInList.value,
      'autoUpdateExternalHashFiles': autoUpdateExternalHashFiles.value,
      'blockedImageHandling': blockedImageHandling.value.index,
      'qrBlockMode': qrBlockMode.value.index,
      'qrScanTailCount': qrScanTailCount.value,
      'userBlockedHashes': userBlockedHashes.toList(),
      'qrBlockedHashes': qrBlockedHashes.toList(),
      'qrBlockingTagFilters': qrBlockingTagFilters.toList(),
      'externalHashFiles': externalHashFiles.map((ExternalHashFile file) => file.toJson()).toList(),
      'builtInHashListStates': Map<String, bool>.fromEntries(
        builtInHashLists.map(
          (BuiltInHashList list) => MapEntry(list.assetPath, list.enabled),
        ),
      ),
    });
  }

  @override
  Future<void> doInitBean() async {
    await _loadBuiltInHashesFromAssets();
  }

  @override
  void doAfterBeanReady() {
    if (autoUpdateExternalHashFiles.isTrue) {
      updateAllExternalHashFiles();
    }
  }

  ImageBlockReason? shouldBlock(String? imageHash, {String? fallbackKey}) {
    String? key = _normalizeKey(imageHash, fallbackKey);
    if (enableHashBlocking.isTrue && key != null) {
      if (userBlockedHashes.contains(key)) {
        return ImageBlockReason.hash;
      }
      if (useBuiltInList.isTrue && builtInBlockedHashes.contains(key)) {
        return ImageBlockReason.builtInHash;
      }
      if (_externalBlockedHashes.contains(key)) {
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

  Future<void> addUserBlockedHashes(Iterable<String> hashes) async {
    Set<String> normalized = hashes.map(_normalizeString).whereType<String>().toSet();
    if (normalized.isEmpty) {
      return;
    }

    bool changed = false;
    for (String hash in normalized) {
      if (userBlockedHashes.add(hash)) {
        changed = true;
      }
    }

    if (!changed) {
      return;
    }

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

  Future<void> saveEnableQrBlockingForTags(bool value) async {
    enableQrBlockingForTags.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveQrBlockMode(QrBlockMode mode) async {
    qrBlockMode.value = mode;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveQrScanTailCount(int count) async {
    int value = count < 0 ? 0 : count;
    qrScanTailCount.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveQrBlockingTagFilters(String raw) async {
    List<String> filters =
        raw.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(growable: false);

    qrBlockingTagFilters
      ..clear()
      ..addAll(filters)
      ..refresh();

    _qrTagRules = _parseQrTagFilters(filters);

    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveUseBuiltInList(bool value) async {
    useBuiltInList.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> toggleBuiltInHashList(BuiltInHashList list, bool enabled) async {
    int index =
        builtInHashLists.indexWhere((BuiltInHashList item) => item.assetPath == list.assetPath);
    if (index < 0) {
      return;
    }

    builtInHashLists[index] = builtInHashLists[index].copyWith(enabled: enabled);
    builtInHashLists.refresh();
    _rebuildBuiltInHashCache();

    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> saveAutoUpdateExternalHashFiles(bool value) async {
    autoUpdateExternalHashFiles.value = value;
    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> addExternalHashFile(String url) async {
    ExternalHashFile? file = await _fetchExternalHashFile(url);

    int existingIndex = externalHashFiles.indexWhere((ExternalHashFile f) => f.url == url);
    if (file == null) {
      // Network failed: add a placeholder for new entries; keep cache for existing ones.
      if (existingIndex < 0) {
        externalHashFiles.add(
          ExternalHashFile(
            url: url,
            hashes: const <String>[],
            updatedAtMillis: 0,
            enabled: true,
          ),
        );
        externalHashFiles.refresh();
        _rebuildExternalHashCache();
        await saveBeanConfig();
        _bumpVersion();
      }
      return;
    }

    if (existingIndex >= 0) {
      bool enabled = externalHashFiles[existingIndex].enabled;
      externalHashFiles[existingIndex] = file.copyWith(enabled: enabled);
    } else {
      externalHashFiles.add(file);
    }
    externalHashFiles.refresh();
    _rebuildExternalHashCache();

    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> refreshExternalHashFile(ExternalHashFile file) async {
    await addExternalHashFile(file.url);
  }

  Future<void> removeExternalHashFile(ExternalHashFile file) async {
    externalHashFiles.removeWhere((ExternalHashFile f) => f.url == file.url);
    externalHashFiles.refresh();
    _rebuildExternalHashCache();

    await saveBeanConfig();
    _bumpVersion();
  }

  Future<void> updateAllExternalHashFiles() async {
    for (ExternalHashFile file in List<ExternalHashFile>.from(externalHashFiles)) {
      await addExternalHashFile(file.url);
    }
  }

  Future<void> toggleExternalHashFile(ExternalHashFile file, bool enabled) async {
    int index = externalHashFiles.indexWhere((ExternalHashFile f) => f.url == file.url);
    if (index < 0) {
      return;
    }

    externalHashFiles[index] = externalHashFiles[index].copyWith(enabled: enabled);
    externalHashFiles.refresh();
    _rebuildExternalHashCache();

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
    List<TagData>? galleryTags,
    Iterable<String> extraKeysOnDetect = const <String>[],
    required Future<Object?> Function() bytesLoader,
  }) async {
    String? key = _normalizeKey(imageHash, fallbackKey);
    if (enableQrBlocking.isFalse || key == null) {
      return false;
    }
    if (!_shouldScanQrForTags(galleryTags)) {
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

      Set<String> targets = {key};
      for (String? extra in extraKeysOnDetect) {
        String? normalized = _normalizeString(extra);
        if (normalized != null) {
          targets.add(normalized);
        }
      }

      await addQrBlockedKeys(targets);
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

  bool shouldScanQrForIndex(int index, {int? totalImages}) {
    if (qrScanTailCount.value <= 0) {
      return true;
    }
    if (totalImages == null || totalImages <= 0) {
      return true;
    }

    return index >= totalImages - qrScanTailCount.value;
  }

  Future<void> addQrBlockedKeys(Iterable<String> keys) async {
    Set<String> normalized = keys.map(_normalizeString).whereType<String>().toSet();
    if (normalized.isEmpty) {
      return;
    }

    bool changed = false;
    for (String key in normalized) {
      if (qrBlockedHashes.add(key)) {
        changed = true;
      }
    }

    if (!changed) {
      return;
    }

    qrBlockedHashes.refresh();
    await saveBeanConfig();
    _bumpVersion();
  }

  bool _shouldScanQrForTags(List<TagData>? galleryTags) {
    if (enableQrBlockingForTags.isFalse) {
      return true;
    }
    if (_qrTagRules.isEmpty) {
      return false;
    }
    if (galleryTags == null || galleryTags.isEmpty) {
      return false;
    }

    for (TagData tag in galleryTags) {
      for (_QrTagRule rule in _qrTagRules) {
        if (tag.namespace.toLowerCase() != rule.namespace) {
          continue;
        }
        if (rule.pattern.hasMatch(tag.key)) {
          return true;
        }
      }
    }

    return false;
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

  Future<bool> containsQrCodeInBytes(Uint8List bytes) async {
    img.Image? image = img.decodeImage(bytes);
    if (image == null) {
      return false;
    }
    return _containsQrCode(image);
  }

  String? _normalizeKey(String? imageHash, String? fallbackKey) {
    return _normalizeString(imageHash) ?? _normalizeString(fallbackKey);
  }

  List<_QrTagRule> _parseQrTagFilters(List<String> filters) {
    List<_QrTagRule> rules = [];
    for (String raw in filters) {
      String filter = raw.trim();
      if (filter.isEmpty) {
        continue;
      }

      int splitterIndex = filter.indexOf(':');
      if (splitterIndex <= 0 || splitterIndex >= filter.length - 1) {
        log.info('Ignore invalid qr tag filter: $filter');
        continue;
      }

      String namespace = filter.substring(0, splitterIndex).trim().toLowerCase();
      String patternRaw = filter.substring(splitterIndex + 1).trim();
      if (patternRaw.startsWith('"') && patternRaw.endsWith('"') && patternRaw.length >= 2) {
        patternRaw = patternRaw.substring(1, patternRaw.length - 1);
      }

      try {
        rules.add(
          _QrTagRule(
            namespace: namespace,
            pattern: RegExp(patternRaw, caseSensitive: false),
          ),
        );
      } on FormatException catch (e, stack) {
        log.error('Invalid qr tag regex: $filter', e, stack);
      }
    }

    return rules;
  }

  ExternalHashFile? _externalFromJson(dynamic data) {
    if (data is! Map) {
      return null;
    }
    try {
      return ExternalHashFile.fromJson(data);
    } catch (e, stack) {
      log.error('Parse external hash file json failed', e, stack);
      return null;
    }
  }

  List<ExternalHashFile> _parseExternalHashFiles(dynamic data) {
    if (data is! List) {
      return <ExternalHashFile>[];
    }
    return data.map(_externalFromJson).whereType<ExternalHashFile>().toList();
  }

  Future<ExternalHashFile?> _fetchExternalHashFile(String url) async {
    try {
      dio.Response<String> response = await _dio.get<String>(url);
      if (response.data == null) {
        log.error('External hash file empty: $url');
        return null;
      }
      List<String> hashes = _parseHashLines(response.data!);
      return ExternalHashFile(
        url: url,
        hashes: hashes,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        enabled: true,
      );
    } catch (e, stack) {
      log.error('Download external hash file failed: $url', e, stack);
      return null;
    }
  }

  List<String> _parseHashLines(String raw) {
    return raw
        .split('\n')
        .map(_normalizeString)
        .whereType<String>()
        .toSet()
        .toList(growable: false);
  }

  void _rebuildExternalHashCache() {
    _externalBlockedHashes
      ..clear()
      ..addAll(
        externalHashFiles
            .where((ExternalHashFile file) => file.enabled)
            .expand((ExternalHashFile file) => file.hashes)
            .toSet(),
      );
  }

  Future<void> _loadBuiltInHashesFromAssets() async {
    builtInHashLists.clear();
    builtInBlockedHashes.clear();

    List<String> assetPaths = await _readBuiltInAssetPaths();
    for (String path in assetPaths) {
      BuiltInHashList? list = await _readBuiltInHashList(path);
      if (list == null) {
        continue;
      }
      bool enabled = _builtInListEnabledConfig[path] ?? true;
      BuiltInHashList applied = list.copyWith(enabled: enabled);
      builtInHashLists.add(applied);
      if (applied.enabled) {
        builtInBlockedHashes.addAll(applied.hashes);
      }
    }

    builtInHashLists.refresh();
  }

  Future<List<String>> _readBuiltInAssetPaths() async {
    try {
      String manifestContent = await rootBundle.loadString('AssetManifest.json');
      Map<String, dynamic> manifestMap = json.decode(manifestContent) as Map<String, dynamic>;
      return manifestMap.keys
          .where((String key) => key.startsWith('assets/blocked_hashes/'))
          .toList(growable: false);
    } catch (e, stack) {
      log.error('Load built-in hash manifest failed', e, stack);
      return <String>[];
    }
  }

  Future<BuiltInHashList?> _readBuiltInHashList(String assetPath) async {
    try {
      String raw = await rootBundle.loadString(assetPath);
      return _parseBuiltInHashList(assetPath, raw);
    } catch (e, stack) {
      log.error('Load built-in hash file failed: $assetPath', e, stack);
      return null;
    }
  }

  BuiltInHashList _parseBuiltInHashList(String assetPath, String raw) {
    List<String> hashes = <String>[];
    String name = assetPath.split('/').isNotEmpty ? assetPath.split('/').last : assetPath;

    for (String line in raw.split('\n')) {
      String trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (trimmed.toLowerCase().startsWith('#name:')) {
          name = trimmed.substring(6).trim();
        }
        continue;
      }

      String? normalized = _normalizeString(trimmed);
      if (normalized == null) {
        continue;
      }
      if (normalized.length != 40) {
        continue;
      }
      hashes.add(normalized);
    }

    return BuiltInHashList(
      assetPath: assetPath,
      name: name,
      hashes: hashes,
      enabled: true,
    );
  }

  void _rebuildBuiltInHashCache() {
    builtInBlockedHashes
      ..clear()
      ..addAll(
        builtInHashLists.where((BuiltInHashList list) => list.enabled).expand(
              (BuiltInHashList list) => list.hashes,
            ),
      );
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

class _QrTagRule {
  _QrTagRule({required this.namespace, required this.pattern});

  final String namespace;
  final RegExp pattern;
}

class ExternalHashFile {
  ExternalHashFile({
    required this.url,
    required this.hashes,
    required this.updatedAtMillis,
    required this.enabled,
  });

  final String url;
  final List<String> hashes;
  final int updatedAtMillis;
  final bool enabled;

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'hashes': hashes,
      'updatedAtMillis': updatedAtMillis,
      'enabled': enabled,
    };
  }

  factory ExternalHashFile.fromJson(Map<dynamic, dynamic> json) {
    List<dynamic> rawHashes = json['hashes'] as List<dynamic>? ?? const <dynamic>[];
    return ExternalHashFile(
      url: json['url'] as String? ?? '',
      hashes: rawHashes
          .map((dynamic e) => e.toString().trim().toLowerCase())
          .where((String e) => e.isNotEmpty)
          .toList(),
      updatedAtMillis: json['updatedAtMillis'] as int? ?? 0,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  ExternalHashFile copyWith({bool? enabled}) {
    return ExternalHashFile(
      url: url,
      hashes: hashes,
      updatedAtMillis: updatedAtMillis,
      enabled: enabled ?? this.enabled,
    );
  }

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
}

class BuiltInHashList {
  BuiltInHashList({
    required this.assetPath,
    required this.name,
    required this.hashes,
    required this.enabled,
  });

  final String assetPath;
  final String name;
  final List<String> hashes;
  final bool enabled;

  BuiltInHashList copyWith({bool? enabled}) {
    return BuiltInHashList(
      assetPath: assetPath,
      name: name,
      hashes: hashes,
      enabled: enabled ?? this.enabled,
    );
  }
}
