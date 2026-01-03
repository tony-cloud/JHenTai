import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/detail_page_info.dart';
import 'package:jhentai/model/eh_raw_tag.dart';
import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_page.dart';
import 'package:jhentai/model/gallery_thumbnail.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/download_filter_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/image_block_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/pages/search/mixin/search_page_mixin.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/toast_util.dart';

class SettingAdBlockPage extends StatelessWidget {
  const SettingAdBlockPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('adBlocker'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildHashBlocking(),
            _buildQrBlocking(),
            _buildQrBlockingForTags(),
            _buildQrBlockOptions(context),
            _buildQrContentWhitelist(context),
            _buildBuiltInListToggle(),
            _buildExternalHashFiles(context),
            _buildHandlingDropdown(),
            _buildBlocklistActions(context),
            _buildRemoveAdsImagesAction(context),
            _buildCustomHashManager(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHashBlocking() {
    return SwitchListTile(
      title: Text('blockImageByHash'.tr),
      subtitle: Text('blockImageByHashHint'.tr),
      value: imageBlockService.enableHashBlocking.value,
      onChanged: imageBlockService.saveEnableHashBlocking,
    );
  }

  Widget _buildQrBlocking() {
    return SwitchListTile(
      title: Text('blockImageByQrCode'.tr),
      subtitle: Text('blockImageByQrCodeHint'.tr),
      value: imageBlockService.enableQrBlocking.value,
      onChanged: imageBlockService.saveEnableQrBlocking,
    );
  }

  Widget _buildQrBlockingForTags() {
    return Column(
      children: [
        SwitchListTile(
          title: Text('qrBlockFilterByTags'.tr),
          subtitle: Text('qrBlockFilterByTagsHint'.tr),
          value: imageBlockService.enableQrBlockingForTags.value,
          onChanged: imageBlockService.saveEnableQrBlockingForTags,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _QrTagSelector(
            enabled: imageBlockService.enableQrBlockingForTags.value,
            initialTags: imageBlockService.qrBlockingTagFilters.toList(),
            onChanged: (List<String> filters) =>
                imageBlockService.saveQrBlockingTagFilters(filters.join('\n')),
          ),
        ),
      ],
    );
  }

  Widget _buildQrBlockOptions(BuildContext context) {
    final List<int> tailOptions = <int>{0, 4, 8, 12, 16, 24}.toList()..sort();
    final int currentTail = imageBlockService.qrScanTailCount.value;
    if (!tailOptions.contains(currentTail)) {
      tailOptions.add(currentTail);
      tailOptions.sort();
    }

    return Column(
      children: [
        ListTile(
          title: Text('qrBlockModeSetting'.tr),
          subtitle: Text('qrBlockModeSettingHint'.tr),
          trailing: DropdownButton<QrBlockMode>(
            value: imageBlockService.qrBlockMode.value,
            onChanged: (QrBlockMode? mode) {
              if (mode != null) {
                imageBlockService.saveQrBlockMode(mode);
              }
            },
            items: [
              DropdownMenuItem(
                value: QrBlockMode.normal,
                child: Text('qrBlockModeNormal'.tr),
              ),
              DropdownMenuItem(
                value: QrBlockMode.advanced,
                child: Text('qrBlockModeAdvanced'.tr),
              ),
              DropdownMenuItem(
                value: QrBlockMode.superRange,
                child: Text('qrBlockModeSuper'.tr),
              ),
            ],
          ),
        ),
        ListTile(
          title: Text('qrScanTailCount'.tr),
          subtitle: Text('qrScanTailCountHint'.tr),
          trailing: DropdownButton<int>(
            value: currentTail,
            onChanged: (int? value) {
              if (value != null) {
                imageBlockService.saveQrScanTailCount(value);
              }
            },
            items: tailOptions
                .map(
                  (int value) => DropdownMenuItem(
                    value: value,
                    child: Text(value == 0 ? 'qrScanTailAll'.tr : value.toString()),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildQrContentWhitelist(BuildContext context) {
    return Obx(
      () => ListTile(
        title: Text('qrContentWhitelist'.tr),
        subtitle: Text(
          'qrContentWhitelistHint'
              .trParams({'count': imageBlockService.qrContentWhitelist.length.toString()}),
        ),
        trailing: OutlinedButton(
          onPressed: () => _showQrContentWhitelistDialog(context),
          child: Text('manage'.tr),
        ),
        onTap: () => _showQrContentWhitelistDialog(context),
      ),
    );
  }

  Widget _buildBuiltInListToggle() {
    return Obx(
      () => Column(
        children: [
          SwitchListTile(
            title: Text('useBuiltInAdBlockList'.tr),
            subtitle: Text(
              'useBuiltInAdBlockListHint'
                  .trParams({'count': imageBlockService.builtInBlockedHashes.length.toString()}),
            ),
            value: imageBlockService.useBuiltInList.value,
            onChanged: imageBlockService.saveUseBuiltInList,
          ),
          if (imageBlockService.builtInHashLists.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: imageBlockService.builtInHashLists
                    .map(
                      (BuiltInHashList list) => SwitchListTile(
                        dense: true,
                        title: Text(list.name),
                        subtitle: Text(
                          'hashCount'.trParams({'count': list.hashes.length.toString()}),
                        ),
                        value: list.enabled,
                        onChanged: imageBlockService.useBuiltInList.isTrue
                            ? (bool value) => imageBlockService.toggleBuiltInHashList(list, value)
                            : null,
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHandlingDropdown() {
    return ListTile(
      title: Text('blockedImageHandling'.tr),
      subtitle: Text('blockedImageHandlingHint'.tr),
      trailing: DropdownButton<BlockedImageHandling>(
        value: imageBlockService.blockedImageHandling.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (BlockedImageHandling? mode) =>
            imageBlockService.saveBlockedImageHandling(mode!),
        items: [
          DropdownMenuItem(
            value: BlockedImageHandling.hide,
            child: Text('blockedImageHandlingHide'.tr),
          ),
          DropdownMenuItem(
            value: BlockedImageHandling.placeholder,
            child: Text('blockedImageHandlingPlaceholder'.tr),
          ),
        ],
      ),
    );
  }

  Widget _buildBlocklistActions(BuildContext context) {
    return Obx(
      () => ListTile(
        title: Text('blockedImageTools'.tr),
        subtitle: Text(
          'blockedImageToolsHint'
              .trParams({'count': imageBlockService.qrBlockedHashes.length.toString()}),
        ),
        trailing: Wrap(
          spacing: 8,
          children: [
            IconButton(
              icon: const Icon(Icons.psychology_alt_outlined),
              tooltip: 'qrBlockAdvancedTool'.tr,
              onPressed: () => _showAdvancedQrBlockDialog(context),
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_2),
              tooltip: 'clearQrCache'.tr,
              onPressed: () => _confirmClearQrCache(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoveAdsImagesAction(BuildContext context) {
    return ListTile(
      title: Text('removeAdsImages'.tr),
      subtitle: Text('removeAdsImagesHint'.tr),
      trailing: const Icon(Icons.cleaning_services_outlined),
      onLongPress: () => _confirmRemoveAdsImages(context),
    );
  }

  Widget _buildCustomHashManager(BuildContext context) {
    return ListTile(
      title: Text('blockedImageList'.tr),
      subtitle: Text('blockedImageListManageHint'.tr),
      trailing: OutlinedButton(
        onPressed: () => _showCustomHashDialog(context),
        child: Text('manage'.tr),
      ),
      onTap: () => _showCustomHashDialog(context),
    );
  }

  Widget _buildExternalHashFiles(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          title: Text('autoUpdateExternalHashFiles'.tr),
          subtitle: Text('autoUpdateExternalHashFilesHint'.tr),
          value: imageBlockService.autoUpdateExternalHashFiles.value,
          onChanged: imageBlockService.saveAutoUpdateExternalHashFiles,
        ),
        ListTile(
          title: Text('externalHashFiles'.tr),
          subtitle: Text('externalHashFilesHint'.tr),
          trailing: IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddExternalHashFileDialog(context),
          ),
        ),
        ...imageBlockService.externalHashFiles.map(
          (ExternalHashFile file) => SwitchListTile(
            dense: true,
            title: Text(file.url),
            subtitle: Text(
              'externalHashFileMeta'
                  .trParams({'count': '${file.hashes.length}', 'time': _formatTime(file)}),
            ),
            value: file.enabled,
            onChanged: (bool value) => imageBlockService.toggleExternalHashFile(file, value),
            secondary: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'refresh'.tr,
                  onPressed: () => imageBlockService.refreshExternalHashFile(file),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'delete'.tr,
                  onPressed: () => imageBlockService.removeExternalHashFile(file),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showCustomHashDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => const _CustomHashDialog(),
    );
  }

  Future<void> _showAdvancedQrBlockDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => const _AdvancedQrBlockDialog(),
    );
  }

  Future<void> _showQrContentWhitelistDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => const _QrContentWhitelistDialog(),
    );
  }

  Future<void> _confirmClearQrCache(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('confirm'.tr),
        content: Text('clearQrCacheConfirm'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('cancel'.tr)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text('OK'.tr)),
        ],
      ),
    );
    if (confirmed == true) {
      await imageBlockService.clearQrBlockedHashes();
    }
  }

  Future<void> _confirmRemoveAdsImages(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('confirm'.tr),
        content: Text('removeAdsImagesConfirm'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('cancel'.tr),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('OK'.tr),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    int removed = await galleryDownloadService.removeHashBlockedImages();
    String message = removed == 0
        ? 'removeAdsImagesEmpty'.tr
        : 'removeAdsImagesResult'.trParams({'count': removed.toString()});
    toast(message);
  }

  Future<void> _showAddExternalHashFileDialog(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('addExternalHashFile'.tr),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: 'externalHashFileUrlHint'.tr),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('cancel'.tr),
            ),
            TextButton(
              onPressed: () async {
                String url = controller.text.trim();
                if (url.isNotEmpty) {
                  await imageBlockService.addExternalHashFile(url);
                }
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: Text('OK'.tr),
            ),
          ],
        );
      },
    );
  }

  String _formatTime(ExternalHashFile file) {
    if (file.updatedAtMillis <= 0) {
      return 'externalHashFileNever'.tr;
    }
    DateTime dt = file.updatedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _QrTagSelector extends StatefulWidget {
  const _QrTagSelector({
    required this.enabled,
    required this.initialTags,
    required this.onChanged,
  });

  final bool enabled;
  final List<String> initialTags;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_QrTagSelector> createState() => _QrTagSelectorState();
}

class _QrTagSelectorState extends State<_QrTagSelector> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _textFieldKey = GlobalKey();

  final List<_SelectedTag> _tags = <_SelectedTag>[];
  List<TagAutoCompletionMatch> _suggestions = <TagAutoCompletionMatch>[];

  OverlayEntry? _overlayEntry;
  Timer? _debounce;
  Timer? _hideOnUnfocusTimer;
  int _requestId = 0;
  double _fieldWidth = 0;
  double _fieldHeight = 40;

  @override
  void initState() {
    super.initState();
    for (final String raw in widget.initialTags) {
      final _SelectedTag tag = _createSelectedTagFromRaw(raw);
      _addTagInternal(tag, notifyParent: false);
    }

    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _hideOnUnfocusTimer?.cancel();
        _hideOnUnfocusTimer = Timer(const Duration(milliseconds: 200), _hideOverlay);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _QrTagSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.initialTags, widget.initialTags)) {
      if (!mounted) {
        return;
      }
      setState(() {
        _tags.clear();
        for (final String raw in widget.initialTags) {
          _tags.add(_createSelectedTagFromRaw(raw));
        }
      });
      for (final _SelectedTag tag in _tags) {
        _populateTranslation(tag);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _hideOnUnfocusTimer?.cancel();
    _hideOverlay();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    double containerWidth = screenWidth.isFinite ? screenWidth - 96 : 280;
    if (containerWidth < 200) {
      containerWidth = 200;
    } else if (containerWidth > 360) {
      containerWidth = 360;
    }
    _fieldWidth = containerWidth;
    _updateFieldSize();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompositedTransformTarget(
          link: _layerLink,
          child: TextField(
            key: _textFieldKey,
            controller: _controller,
            focusNode: _focusNode,
            enabled: widget.enabled,
            decoration: InputDecoration(
              labelText: 'qrBlockFilterTagList'.tr,
              hintText: 'qrBlockFilterTagListHint'.tr,
              isDense: true,
            ),
            onChanged: _onTextChanged,
            onSubmitted: (_) => _hideOverlay(),
            textInputAction: TextInputAction.search,
            minLines: 1,
            maxLines: 1,
          ),
        ),
        if (_tags.isNotEmpty) const SizedBox(height: 8),
        _buildSelectedTagChips(context, containerWidth),
      ],
    );
  }

  void _onTextChanged(String value) {
    _scheduleSearch(value);
  }

  void _addTagInternal(_SelectedTag tag, {bool notifyParent = true}) {
    if (tag.filterValue.trim().isEmpty) {
      return;
    }
    if (_tags.any((existing) => existing.normalized == tag.normalized)) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _tags.add(tag));
    if (notifyParent) {
      widget.onChanged(
        _tags.map((t) => t.filterValue).toList(growable: false),
      );
    }

    _populateTranslation(tag);

    _controller.clear();
    _hideOverlay();
    if (widget.enabled) {
      _focusNode.requestFocus();
    }
  }

  void _removeTagAt(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() => _tags.removeAt(index));
      widget.onChanged(
        _tags.map((t) => t.filterValue).toList(growable: false),
      );
      _scheduleSearch(_controller.text);
    });
  }

  void _scheduleSearch(String rawQuery) {
    _debounce?.cancel();

    final String query = rawQuery.trim();
    if (query.isEmpty || !widget.enabled) {
      _suggestions = <TagAutoCompletionMatch>[];
      _hideOverlay();
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 200), () => _searchSuggestions(query));
  }

  Future<void> _searchSuggestions(String query) async {
    final int captured = ++_requestId;
    List<TagAutoCompletionMatch> translationMatches = <TagAutoCompletionMatch>[];
    if (tagTranslationService.isReady) {
      translationMatches = await tagTranslationService.searchTags(query, limit: 50);
      if (!mounted || captured != _requestId) {
        return;
      }
    }

    final List<TagAutoCompletionMatch> rawMatches = await _fetchRawTagSuggestions(query);
    if (!mounted || captured != _requestId) {
      return;
    }

    final List<TagAutoCompletionMatch> uploaderMatches =
        await downloadFilterService.buildUploaderSuggestions(query);
    if (!mounted || captured != _requestId) {
      return;
    }

    final List<TagAutoCompletionMatch> matches =
        _mergeMatches(translationMatches, rawMatches, uploaderMatches);
    if (!mounted || captured != _requestId) {
      return;
    }

    final Set<String> existing = _tags.map((tag) => tag.normalized).toSet();
    final List<TagAutoCompletionMatch> filtered = matches.where((TagAutoCompletionMatch match) {
      final String normalized = _normalizeMatch(match);
      return !existing.contains(normalized);
    }).toList();

    if (filtered.isEmpty) {
      _suggestions = <TagAutoCompletionMatch>[];
      _hideOverlay();
      return;
    }

    _suggestions = filtered;
    _showOverlay();
  }

  Future<List<TagAutoCompletionMatch>> _fetchRawTagSuggestions(String rawQuery) async {
    final String trimmed = rawQuery.trim();
    if (trimmed.isEmpty) {
      return <TagAutoCompletionMatch>[];
    }

    String searchTerm = trimmed;
    String? operator;
    if (searchTerm.startsWith('-') || searchTerm.startsWith('~')) {
      operator = searchTerm[0];
      searchTerm = searchTerm.substring(1).trimLeft();
    }

    if (searchTerm.isEmpty) {
      return <TagAutoCompletionMatch>[];
    }

    final int colonIndex = searchTerm.indexOf(':');
    final String namespaceTerm = colonIndex == -1 ? '' : searchTerm.substring(0, colonIndex).trim();
    final String keyTerm =
        colonIndex == -1 ? searchTerm : searchTerm.substring(colonIndex + 1).trim();

    try {
      final List<EHRawTag> tags = await ehRequest.requestTagSuggestion(
        searchTerm,
        EHSpiderParser.tagSuggestion2TagList,
      );
      return tags
          .map(
            (EHRawTag tag) => (
              searchText: trimmed,
              matchStart: trimmed.length - searchTerm.length,
              matchEnd: trimmed.length,
              tagData: TagData(namespace: tag.namespace, key: tag.key),
              operator: operator,
              namespaceMatch: namespaceTerm.isEmpty
                  ? null
                  : _matchRangeIgnoreCase(tag.namespace, namespaceTerm),
              translatedNamespaceMatch: null,
              keyMatch: keyTerm.isEmpty ? null : _matchRangeIgnoreCase(tag.key, keyTerm),
              tagNameMatch: null,
              score: 0.0,
            ),
          )
          .toList();
    } on DioException catch (e) {
      log.error('Request qr tag suggestion failed', e);
      return <TagAutoCompletionMatch>[];
    }
  }

  List<TagAutoCompletionMatch> _mergeMatches(
    List<TagAutoCompletionMatch> translationMatches,
    List<TagAutoCompletionMatch> rawMatches,
    List<TagAutoCompletionMatch> uploaderMatches,
  ) {
    final List<TagAutoCompletionMatch> merged = <TagAutoCompletionMatch>[];
    final Set<String> seen = <String>{};

    for (final TagAutoCompletionMatch match in translationMatches) {
      final String normalized = _normalizeMatch(match);
      if (seen.add(normalized)) {
        merged.add(match);
      }
    }

    for (final TagAutoCompletionMatch match in rawMatches) {
      final String normalized = _normalizeMatch(match);
      if (seen.add(normalized)) {
        merged.add(match);
      }
    }

    for (final TagAutoCompletionMatch match in uploaderMatches) {
      final String normalized = _normalizeMatch(match);
      if (seen.add(normalized)) {
        merged.add(match);
      }
    }

    return merged;
  }

  String _normalizeMatch(TagAutoCompletionMatch match) {
    final String prefix = match.operator ?? '';
    final TagData data = match.tagData;
    final String raw = data.namespace.isEmpty ? data.key : '${data.namespace}:${data.key}';
    return '$prefix$raw'.trim().toLowerCase();
  }

  ({int start, int end})? _matchRangeIgnoreCase(String source, String term) {
    if (term.isEmpty) {
      return null;
    }
    final String lowerSource = source.toLowerCase();
    final String lowerTerm = term.toLowerCase();
    final int index = lowerSource.indexOf(lowerTerm);
    if (index == -1) {
      return null;
    }
    return (start: index, end: index + term.length);
  }

  void _showOverlay() {
    final OverlayState overlay = Overlay.of(context);
    if (_overlayEntry == null) {
      _overlayEntry = _buildOverlay();
      overlay.insert(_overlayEntry!);
    } else {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
  }

  OverlayEntry _buildOverlay() {
    return OverlayEntry(
      builder: (BuildContext context) {
        final double width = _fieldWidth;
        return CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: Offset(0, _fieldHeight + 4),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: width,
                maxWidth: width,
                maxHeight: 240,
              ),
              child: _QrTagSuggestionList(
                suggestions: _suggestions,
                onTap: (TagAutoCompletionMatch suggestion) {
                  _addTagInternal(_createSelectedTagFromSuggestion(suggestion));
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedTagChips(BuildContext context, double maxWidth) {
    if (_tags.isEmpty) {
      return const SizedBox.shrink();
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List<Widget>.generate(
          _tags.length,
          (int index) => _buildSelectedTagChip(context, _tags[index], index),
        ),
      ),
    );
  }

  Widget _buildSelectedTagChip(BuildContext context, _SelectedTag tag, int index) {
    final String formatted = _formatTagLabel(tag);
    final String label =
        tag.operator == null || tag.operator!.isEmpty ? formatted : '${tag.operator}$formatted';
    final Color foreground = UIConfig.ehTagTextColor(context);
    final Color background = UIConfig.ehTagBackGroundColor(context);

    return FilterChip(
      key: ValueKey(tag.filterValue),
      label: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _fieldWidth - 40),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
      labelStyle: TextStyle(color: foreground, fontSize: 12),
      selected: true,
      showCheckmark: false,
      backgroundColor: background,
      selectedColor: background,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      deleteIcon: const Icon(Icons.close, size: 16),
      deleteIconColor: foreground,
      onDeleted: () => _removeTagAt(index),
      onSelected: (_) => _removeTagAt(index),
    );
  }

  String _formatTagLabel(_SelectedTag tag) {
    final TagData data = tag.tagData;
    if (data.translatedNamespace != null && data.tagName != null) {
      return '${data.translatedNamespace}:${data.tagName}';
    }
    if (data.tagName != null) {
      return '${data.namespace}:${data.tagName}';
    }
    if (data.namespace.isEmpty) {
      return data.key;
    }
    return '${data.namespace}:${data.key}';
  }

  void _updateFieldSize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final RenderObject? renderObject = _textFieldKey.currentContext?.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        _fieldHeight = renderObject.size.height;
        _overlayEntry?.markNeedsBuild();
      }
    });
  }

  void _populateTranslation(_SelectedTag tag) {
    if (!tagTranslationService.isReady) {
      return;
    }
    if (tag.tagData.tagName != null || tag.tagData.translatedNamespace != null) {
      return;
    }

    tagTranslationService
        .getTagTranslation(tag.tagData.namespace, tag.tagData.key)
        .then((TagData? translated) {
      if (!mounted || translated == null) {
        return;
      }
      setState(() => tag.updateTagData(translated));
    });
  }

  _SelectedTag _createSelectedTagFromRaw(String raw) {
    String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return _SelectedTag(TagData(namespace: '', key: ''));
    }

    String? operator;
    if (trimmed.startsWith('-') || trimmed.startsWith('~')) {
      operator = trimmed[0];
      trimmed = trimmed.substring(1).trim();
    }

    final TagData tagData = _parseTagData(trimmed) ?? TagData(namespace: '', key: trimmed);
    return _SelectedTag(tagData, operator: operator);
  }

  _SelectedTag _createSelectedTagFromSuggestion(TagAutoCompletionMatch suggestion) {
    final TagData source = suggestion.tagData;
    final TagData tagData = TagData(
      namespace: source.namespace,
      key: source.key,
      translatedNamespace: source.translatedNamespace,
      tagName: source.tagName,
      fullTagName: source.fullTagName,
      intro: source.intro,
      links: source.links,
    );
    return _SelectedTag(tagData, operator: suggestion.operator);
  }

  TagData? _parseTagData(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty || !trimmed.contains(':')) {
      return null;
    }

    final int colonIndex = trimmed.indexOf(':');
    if (colonIndex <= 0 || colonIndex >= trimmed.length - 1) {
      return null;
    }

    String namespace = trimmed.substring(0, colonIndex).trim();
    String key = trimmed.substring(colonIndex + 1).trim();

    if (key.startsWith('"') && key.endsWith('"') && key.length > 1) {
      key = key.substring(1, key.length - 1);
    }

    return TagData(namespace: namespace, key: key);
  }
}

class _QrTagSuggestionList extends StatelessWidget {
  const _QrTagSuggestionList({required this.suggestions, required this.onTap});

  final List<TagAutoCompletionMatch> suggestions;
  final ValueChanged<TagAutoCompletionMatch> onTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final TextStyle highlightStyle = titleStyle.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final TextStyle subtitleStyle =
        Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12);
    final TextStyle subtitleHighlight = subtitleStyle.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: suggestions.length,
      itemBuilder: (BuildContext context, int index) {
        final TagAutoCompletionMatch suggestion = suggestions[index];
        return ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          title: highlightRawTag(context, suggestion, titleStyle, highlightStyle, singleLine: true),
          subtitle: suggestion.tagData.tagName == null
              ? null
              : highlightTranslatedTag(
                  context,
                  suggestion,
                  subtitleStyle,
                  subtitleHighlight,
                  singleLine: true,
                ),
          onTap: () => onTap(suggestion),
        );
      },
    );
  }
}

class _SelectedTag {
  _SelectedTag(this.tagData, {this.operator});

  TagData tagData;
  final String? operator;

  String get filterValue =>
      operator == null || operator!.isEmpty ? _rawValue : '${operator!}$_rawValue';

  String get normalized => filterValue.trim().toLowerCase();

  String get _rawValue =>
      tagData.namespace.isEmpty ? tagData.key : '${tagData.namespace}:${tagData.key}';

  void updateTagData(TagData newData) {
    tagData = newData;
  }
}

class _QrContentWhitelistDialog extends StatefulWidget {
  const _QrContentWhitelistDialog();

  @override
  State<_QrContentWhitelistDialog> createState() => _QrContentWhitelistDialogState();
}

class _QrContentWhitelistDialogState extends State<_QrContentWhitelistDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: imageBlockService.qrContentWhitelist.join('\n'),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('qrContentWhitelist'.tr),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              minLines: 6,
              maxLines: 10,
              decoration: InputDecoration(
                hintText: 'qrContentWhitelistDialogHint'.tr,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'qrContentWhitelistNote'.tr,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('close'.tr),
        ),
        TextButton(
          onPressed: _restoreDefaults,
          child: Text('restoreDefaults'.tr),
        ),
        TextButton(
          onPressed: _save,
          child: Text('save'.tr),
        ),
      ],
    );
  }

  void _restoreDefaults() {
    if (!mounted) {
      return;
    }
    setState(
      () => _controller.text = imageBlockService.defaultQrContentWhitelist.join('\n'),
    );
  }

  Future<void> _save() async {
    await imageBlockService.saveQrContentWhitelist(_controller.text);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _CustomHashDialog extends StatefulWidget {
  const _CustomHashDialog();

  @override
  State<_CustomHashDialog> createState() => _CustomHashDialogState();
}

class _CustomHashDialogState extends State<_CustomHashDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('blockedImageList'.tr),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(hintText: 'customHashHint'.tr),
              onSubmitted: _addHash,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: Obx(
                () {
                  if (imageBlockService.userBlockedHashes.isEmpty) {
                    return Center(child: Text('blockedImageListEmpty'.tr));
                  }
                  return ListView(
                    children: imageBlockService.userBlockedHashes
                        .map(
                          (String hash) => ListTile(
                            dense: true,
                            title: Text(hash),
                            onTap: () => _copyHash(hash),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => imageBlockService.removeUserBlockedHash(hash),
                            ),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('close'.tr),
        ),
        TextButton(
          onPressed: _copyAllHashes,
          child: Text('copyAllHashes'.tr),
        ),
        TextButton(
          onPressed: () async {
            final bool? confirmed = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: Text('confirm'.tr),
                content: Text('clearBlockedImagesConfirm'.tr),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('cancel'.tr),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text('OK'.tr),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await imageBlockService.clearUserBlockedHashes();
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            }
          },
          child: Text('clearBlockedImages'.tr),
        ),
        TextButton(
          onPressed: () => _addHash(_controller.text),
          child: Text('add'.tr),
        ),
      ],
    );
  }

  Future<void> _addHash(String raw) async {
    String hash = raw.trim();
    if (hash.isEmpty) {
      return;
    }
    await imageBlockService.addUserBlockedHash(hash);
    _controller.clear();
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _copyHash(String hash) async {
    await Clipboard.setData(ClipboardData(text: hash));
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _copyAllHashes() async {
    if (imageBlockService.userBlockedHashes.isEmpty) {
      return;
    }
    await Clipboard.setData(
      ClipboardData(text: imageBlockService.userBlockedHashes.join('\n')),
    );
    toast('hasCopiedToClipboard'.tr);
  }
}

enum _QrBlockSource { online, downloaded }

enum _QrBlockSort { recent, oldest, rating }

class _QrScanEntry {
  const _QrScanEntry({required this.index, required this.thumbnail});

  final int index;
  final GalleryThumbnail thumbnail;
}

class _DownloadedScanEntry {
  const _DownloadedScanEntry({required this.index, required this.image});

  final int index;
  final GalleryImage image;
}

class _ScanImageResult {
  const _ScanImageResult({required this.hasQr, this.key});

  final bool hasQr;
  final String? key;
}

class _AdvancedQrBlockDialog extends StatefulWidget {
  const _AdvancedQrBlockDialog();

  @override
  State<_AdvancedQrBlockDialog> createState() => _AdvancedQrBlockDialogState();
}

class _AdvancedQrBlockDialogState extends State<_AdvancedQrBlockDialog> {
  final TextEditingController _galleryCountController = TextEditingController(text: '10');
  List<String> _tagFilters = <String>[];

  _QrBlockSource _source = _QrBlockSource.online;
  _QrBlockSort _sort = _QrBlockSort.recent;
  QrBlockMode _mode = imageBlockService.qrBlockMode.value;
  int _tailImages =
      imageBlockService.qrScanTailCount.value == 0 ? 8 : imageBlockService.qrScanTailCount.value;

  bool _running = false;
  int _currentGallery = 0;
  int _totalGallery = 0;
  int _currentImage = 0;
  int _totalImages = 0;
  String? _status;
  CancelToken? _cancelToken;

  @override
  void dispose() {
    _cancelToken?.cancel('dialog closed');
    _galleryCountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('qrBlockAdvancedTool'.tr),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _QrTagSelector(
                enabled: !_running,
                initialTags: _tagFilters,
                onChanged: _handleTagFiltersChanged,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<_QrBlockSource>(
                initialValue: _source,
                decoration: InputDecoration(labelText: 'qrBlockSourceLabel'.tr),
                items: [
                  DropdownMenuItem(
                    value: _QrBlockSource.online,
                    child: Text('qrBlockSourceOnline'.tr),
                  ),
                  DropdownMenuItem(
                    value: _QrBlockSource.downloaded,
                    child: Text('qrBlockSourceDownloaded'.tr),
                  ),
                ],
                onChanged: _running
                    ? null
                    : (_QrBlockSource? value) {
                        if (value != null) {
                          setState(() => _source = value);
                        }
                      },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _galleryCountController,
                      keyboardType: TextInputType.number,
                      enabled: _source == _QrBlockSource.online && !_running,
                      decoration: InputDecoration(
                        labelText: 'qrBlockGalleryCount'.tr,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _tailImages,
                      decoration: InputDecoration(
                        labelText: 'qrBlockTailImageCount'.tr,
                      ),
                      items: <int>{4, 8, 12, 16, 24, 32}
                          .map(
                            (int value) => DropdownMenuItem(
                              value: value,
                              child: Text(value.toString()),
                            ),
                          )
                          .toList(),
                      onChanged: _running
                          ? null
                          : (int? value) {
                              if (value != null) {
                                setState(() => _tailImages = value);
                              }
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<_QrBlockSort>(
                      initialValue: _sort,
                      decoration: InputDecoration(labelText: 'qrBlockSortLabel'.tr),
                      items: [
                        DropdownMenuItem(
                          value: _QrBlockSort.recent,
                          child: Text('qrBlockSortRecent'.tr),
                        ),
                        DropdownMenuItem(
                          value: _QrBlockSort.oldest,
                          child: Text('qrBlockSortOldest'.tr),
                        ),
                        DropdownMenuItem(
                          value: _QrBlockSort.rating,
                          child: Text('qrBlockSortRating'.tr),
                        ),
                      ],
                      onChanged: _running
                          ? null
                          : (_QrBlockSort? value) {
                              if (value != null) {
                                setState(() => _sort = value);
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<QrBlockMode>(
                      initialValue: _mode,
                      decoration: InputDecoration(labelText: 'qrBlockModeLabel'.tr),
                      items: [
                        DropdownMenuItem(
                          value: QrBlockMode.normal,
                          child: Text('qrBlockModeNormal'.tr),
                        ),
                        DropdownMenuItem(
                          value: QrBlockMode.advanced,
                          child: Text('qrBlockModeAdvanced'.tr),
                        ),
                        DropdownMenuItem(
                          value: QrBlockMode.superRange,
                          child: Text('qrBlockModeSuper'.tr),
                        ),
                      ],
                      onChanged: _running
                          ? null
                          : (QrBlockMode? value) {
                              if (value != null) {
                                setState(() => _mode = value);
                              }
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildProgress(context),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: Text('close'.tr),
        ),
        if (_running)
          TextButton(
            onPressed: _stop,
            child: Text('qrBlockStop'.tr),
          )
        else
          TextButton(
            onPressed: _start,
            child: Text('qrBlockStart'.tr),
          ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    if (!_running) {
      return Text(_status ?? 'qrBlockReady'.tr);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'qrBlockProgress'.trParams({
            'gallery': '$_currentGallery/$_totalGallery',
            'image': _totalImages == 0 ? '0' : '$_currentImage/$_totalImages',
          }),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _totalGallery == 0 ? null : _currentGallery / _totalGallery.toDouble(),
        ),
      ],
    );
  }

  Future<void> _start() async {
    if (_running) {
      return;
    }

    final String keyword = _tagFilters.join(' ').trim();
    if (keyword.isEmpty) {
      setState(() => _status = 'qrBlockTagEmpty'.tr);
      return;
    }

    int limit = _source == _QrBlockSource.online ? _parseGalleryLimit() : 0;
    _cancelToken = _source == _QrBlockSource.online ? CancelToken() : null;

    setState(() {
      _running = true;
      _status = null;
      _currentGallery = 0;
      _totalGallery = 0;
      _currentImage = 0;
      _totalImages = 0;
    });

    try {
      if (_source == _QrBlockSource.downloaded) {
        await _scanDownloadedGalleries(keyword);
      } else {
        await _scanOnlineGalleries(keyword, limit);
      }
      if (mounted) {
        setState(() => _status = 'qrBlockFinished'.tr);
      }
    } catch (e, stack) {
      log.error('Advanced QR block failed', e, stack);
      if (mounted) {
        setState(() => _status = e.toString());
      }
    } finally {
      _cancelToken = null;
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  void _stop() {
    _cancelToken?.cancel('stopped');
    setState(() => _running = false);
  }

  void _handleTagFiltersChanged(List<String> tags) {
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() => _tagFilters = tags);
    });
  }

  Future<void> _scanOnlineGalleries(String keyword, int limit) async {
    final CancelToken token = _cancelToken ?? CancelToken();
    List<Gallery> galleries = await _fetchGalleries(keyword, limit, token);
    if (!mounted) {
      return;
    }

    setState(() => _totalGallery = galleries.length);

    for (int i = 0; i < galleries.length; i++) {
      if (!_running) {
        break;
      }

      setState(() {
        _currentGallery = i + 1;
        _currentImage = 0;
        _totalImages = 0;
        _status = galleries[i].title;
      });

      await _processGallery(galleries[i]);
    }
  }

  Future<void> _scanDownloadedGalleries(String keyword) async {
    List<GalleryDownloadedData> galleries = await _fetchDownloadedGalleries(keyword);
    if (!mounted) {
      return;
    }

    setState(() => _totalGallery = galleries.length);

    if (galleries.isEmpty) {
      setState(() => _status = 'qrBlockNoDownloadedMatch'.tr);
      return;
    }

    for (int i = 0; i < galleries.length; i++) {
      if (!_running) {
        break;
      }

      setState(() {
        _currentGallery = i + 1;
        _currentImage = 0;
        _totalImages = 0;
        _status = galleries[i].title;
      });

      await _processDownloadedGallery(galleries[i]);
    }
  }

  int _parseGalleryLimit() {
    int? parsed = int.tryParse(_galleryCountController.text.trim());
    if (parsed == null || parsed <= 0) {
      return 10;
    }
    return parsed.clamp(1, 1000);
  }

  Future<List<GalleryDownloadedData>> _fetchDownloadedGalleries(String keyword) async {
    await galleryDownloadService.completed;

    String normalized = keyword.toLowerCase();
    String cleaned = normalized.replaceAll('"', '');
    Set<String> terms = {
      normalized,
      cleaned,
    };

    int colonIndex = cleaned.indexOf(':');
    if (colonIndex != -1 && colonIndex < cleaned.length - 1) {
      String tail = cleaned.substring(colonIndex + 1).trim();
      if (tail.isNotEmpty) {
        terms.add(tail);
      }
    }

    List<GalleryDownloadedData> downloaded = galleryDownloadService.gallerys
        .where(
          (GalleryDownloadedData g) => g.downloadStatusIndex == DownloadStatus.downloaded.index,
        )
        .toList();

    List<GalleryDownloadedData> matches = downloaded.where((GalleryDownloadedData g) {
      String tags = g.tags.toLowerCase();
      String title = g.title.toLowerCase();
      String uploader = g.uploader?.toLowerCase() ?? '';

      for (String term in terms) {
        if (term.isEmpty) {
          continue;
        }
        if (tags.contains(term) || title.contains(term) || uploader.contains(term)) {
          return true;
        }
      }
      return false;
    }).toList();

    matches.sort(_compareDownloadedGalleries);
    return matches;
  }

  Future<List<Gallery>> _fetchGalleries(
    String keyword,
    int limit,
    CancelToken cancelToken,
  ) async {
    SearchConfig config = SearchConfig(keyword: keyword);
    List<Gallery> result = <Gallery>[];
    String? nextGid;

    while (result.length < limit) {
      if (cancelToken.isCancelled) {
        break;
      }
      GalleryPageInfo page = await ehRequest.requestGalleryPage<GalleryPageInfo>(
        nextGid: nextGid,
        searchConfig: config,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );

      result.addAll(page.gallerys);
      nextGid = page.nextGid;

      if (nextGid == null || cancelToken.isCancelled) {
        break;
      }
    }

    List<Gallery> sorted = List<Gallery>.from(result);
    sorted.sort(_compareGalleries);
    if (sorted.length > limit) {
      sorted = sorted.sublist(0, limit);
    }
    return sorted;
  }

  int _compareDownloadedGalleries(
    GalleryDownloadedData a,
    GalleryDownloadedData b,
  ) {
    switch (_sort) {
      case _QrBlockSort.recent:
        return _parsePublishTimeString(b.publishTime)
            .compareTo(_parsePublishTimeString(a.publishTime));
      case _QrBlockSort.oldest:
        return _parsePublishTimeString(a.publishTime)
            .compareTo(_parsePublishTimeString(b.publishTime));
      case _QrBlockSort.rating:
        return 0;
    }
  }

  int _compareGalleries(Gallery a, Gallery b) {
    switch (_sort) {
      case _QrBlockSort.recent:
        return _parsePublishTime(b).compareTo(_parsePublishTime(a));
      case _QrBlockSort.oldest:
        return _parsePublishTime(a).compareTo(_parsePublishTime(b));
      case _QrBlockSort.rating:
        return b.rating.compareTo(a.rating);
    }
  }

  DateTime _parsePublishTime(Gallery gallery) {
    return DateTime.tryParse(gallery.publishTime) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _parsePublishTimeString(String publishTime) {
    return DateTime.tryParse(publishTime) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _processGallery(Gallery gallery) async {
    if (!_running) {
      return;
    }

    CancelToken? token = _cancelToken;
    if (token == null) {
      return;
    }

    List<_QrScanEntry> entries = await _collectTailEntries(gallery, token);
    if (entries.isEmpty) {
      return;
    }

    setState(() {
      _totalImages = entries.length;
      _currentImage = 0;
    });

    Map<int, String> keys = <int, String>{};
    Set<int> qrIndexes = <int>{};

    for (int i = 0; i < entries.length; i++) {
      if (!_running) {
        break;
      }
      setState(() => _currentImage = i + 1);

      _ScanImageResult? result = await _loadAndScanImage(gallery, entries[i], token);
      if (result == null) {
        continue;
      }

      if (result.key != null) {
        keys[entries[i].index] = result.key!;
      }
      if (result.hasQr) {
        qrIndexes.add(entries[i].index);
      }
    }

    if (qrIndexes.isEmpty) {
      return;
    }

    List<String> toBlock = _resolveBlockKeys(
      entries.map((e) => e.index).toList(growable: false),
      keys,
      qrIndexes,
    );
    if (toBlock.isEmpty) {
      return;
    }

    await imageBlockService.addUserBlockedHashes(toBlock);
    await imageBlockService.addQrBlockedKeys(toBlock);
  }

  Future<void> _processDownloadedGallery(GalleryDownloadedData gallery) async {
    if (!_running) {
      return;
    }

    GalleryDownloadInfo? info = galleryDownloadService.galleryDownloadInfos[gallery.gid];
    if (info == null) {
      return;
    }

    List<_DownloadedScanEntry> entries = _collectDownloadedEntries(info);
    if (entries.isEmpty) {
      return;
    }

    setState(() {
      _totalImages = entries.length;
      _currentImage = 0;
    });

    Map<int, String> keys = <int, String>{};
    Set<int> qrIndexes = <int>{};

    for (int i = 0; i < entries.length; i++) {
      if (!_running) {
        break;
      }
      setState(() => _currentImage = i + 1);

      _ScanImageResult? result = await _scanDownloadedImage(entries[i]);
      if (result == null) {
        continue;
      }

      if (result.key != null) {
        keys[entries[i].index] = result.key!;
      }
      if (result.hasQr) {
        qrIndexes.add(entries[i].index);
      }
    }

    if (qrIndexes.isEmpty) {
      return;
    }

    List<String> toBlock = _resolveBlockKeys(
      entries.map((e) => e.index).toList(growable: false),
      keys,
      qrIndexes,
    );
    if (toBlock.isEmpty) {
      return;
    }

    await imageBlockService.addUserBlockedHashes(toBlock);
    await imageBlockService.addQrBlockedKeys(toBlock);
  }

  List<_DownloadedScanEntry> _collectDownloadedEntries(GalleryDownloadInfo info) {
    List<_DownloadedScanEntry> downloaded = <_DownloadedScanEntry>[];

    for (int i = 0; i < info.images.length; i++) {
      GalleryImage? image = info.images[i];
      if (image == null) {
        continue;
      }
      if (image.downloadStatus != DownloadStatus.downloaded) {
        continue;
      }
      if (image.path == null) {
        continue;
      }
      downloaded.add(_DownloadedScanEntry(index: i, image: image));
    }

    if (downloaded.isEmpty) {
      return downloaded;
    }

    downloaded.sort((a, b) => a.index.compareTo(b.index));

    int desired = _tailImages <= 0 ? downloaded.length : _tailImages;
    desired = desired.clamp(1, downloaded.length).toInt();

    return downloaded.sublist(downloaded.length - desired);
  }

  Future<_ScanImageResult?> _scanDownloadedImage(_DownloadedScanEntry entry) async {
    try {
      String? relativePath = entry.image.path;
      if (relativePath == null) {
        return null;
      }

      String absolutePath = GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
        relativePath,
      );

      File file = File(absolutePath);
      if (!await file.exists()) {
        return null;
      }

      Uint8List bytes = await file.readAsBytes();
      String? cacheKey = imageBlockService.buildCacheKey(entry.image);
      bool hasQr = await imageBlockService.containsQrCodeInBytes(bytes);
      return _ScanImageResult(hasQr: hasQr, key: cacheKey);
    } catch (e, stack) {
      log.error('Scan downloaded image failed', e, stack);
      return null;
    }
  }

  List<String> _resolveBlockKeys(
    List<int> indexes,
    Map<int, String> keys,
    Set<int> qrIndexes,
  ) {
    if (qrIndexes.isEmpty) {
      return const <String>[];
    }

    int start = qrIndexes.reduce((int a, int b) => a < b ? a : b);
    int end = qrIndexes.reduce((int a, int b) => a > b ? a : b);
    List<int> sortedIndexes = List<int>.from(indexes)..sort();
    int lastScannedIndex = sortedIndexes.isEmpty ? 0 : sortedIndexes.last;

    Set<int> targets;
    switch (_mode) {
      case QrBlockMode.normal:
        targets = qrIndexes;
        break;
      case QrBlockMode.advanced:
        targets = {
          for (int i = start; i <= end; i++) i,
        };
        break;
      case QrBlockMode.superRange:
        targets = {
          for (int i = start; i <= lastScannedIndex; i++) i,
        };
        break;
    }

    return targets
        .map((int index) => keys[index])
        .whereType<String>()
        .toSet()
        .toList(growable: false);
  }

  Future<List<_QrScanEntry>> _collectTailEntries(
    Gallery gallery,
    CancelToken cancelToken,
  ) async {
    int totalCount = gallery.pageCount ?? 0;
    int desired = _tailImages <= 0 ? totalCount : _tailImages;
    if (desired <= 0) {
      desired = 1;
    }

    int pageIndex = totalCount > 0 ? totalCount - 1 : 0;

    DetailPageInfo page = await _loadDetailPage(
      gallery.galleryUrl.url,
      pageIndex,
      cancelToken,
    );
    List<_QrScanEntry> entries = _buildEntriesFromPage(page);

    int currentPage = page.pageCount - 2;
    while (entries.length < desired && currentPage >= 0 && _running) {
      DetailPageInfo more = await _loadDetailPage(
        gallery.galleryUrl.url,
        currentPage,
        cancelToken,
      );
      entries.addAll(_buildEntriesFromPage(more));
      currentPage--;
    }

    entries.sort((a, b) => a.index.compareTo(b.index));

    if (entries.length > desired) {
      entries = entries.sublist(entries.length - desired);
    }

    return entries;
  }

  Future<DetailPageInfo> _loadDetailPage(
    String url,
    int pageIndex,
    CancelToken cancelToken,
  ) {
    return ehRequest.requestDetailPage<DetailPageInfo>(
      galleryUrl: url,
      thumbnailsPageIndex: pageIndex,
      useCacheIfAvailable: false,
      cancelToken: cancelToken,
      parser: EHSpiderParser.detailPage2RangeAndThumbnails,
    );
  }

  List<_QrScanEntry> _buildEntriesFromPage(DetailPageInfo info) {
    return List<_QrScanEntry>.generate(
      info.thumbnails.length,
      (int i) => _QrScanEntry(index: info.imageNoFrom + i, thumbnail: info.thumbnails[i]),
    );
  }

  Future<_ScanImageResult?> _loadAndScanImage(
    Gallery gallery,
    _QrScanEntry entry,
    CancelToken cancelToken,
  ) async {
    try {
      GalleryImage imagePage = await ehRequest.requestImagePage<GalleryImage>(
        entry.thumbnail.href,
        useCacheIfAvailable: false,
        cancelToken: cancelToken,
        parser: EHSpiderParser.imagePage2GalleryImage,
      );

      GalleryImage cacheImage = imagePage.copyWith(
        imageHash: imagePage.imageHash ?? entry.thumbnail.originImageHash,
      );
      String? cacheKey = imageBlockService.buildCacheKey(cacheImage);

      String tempPath = p.join(
        pathService.tempDir.path,
        'qr_${gallery.gid}_${entry.index}_${DateTime.now().millisecondsSinceEpoch}',
      );

      await ehRequest.download<void>(
        url: imagePage.url,
        path: tempPath,
        cancelToken: cancelToken,
        deleteOnError: true,
        receiveTimeout: const Duration(minutes: 1).inMilliseconds,
      );

      Uint8List bytes = await File(tempPath).readAsBytes();
      await File(tempPath).delete().catchError((_) => File(tempPath));

      bool hasQr = await imageBlockService.containsQrCodeInBytes(bytes);
      return _ScanImageResult(hasQr: hasQr, key: cacheKey);
    } catch (e, stack) {
      log.error('Scan qr image failed', e, stack);
      return null;
    }
  }
}
