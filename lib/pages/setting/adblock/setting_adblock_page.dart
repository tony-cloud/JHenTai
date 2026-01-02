import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/eh_raw_tag.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/image_block_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

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
            _buildBuiltInListToggle(),
            _buildHandlingDropdown(),
            _buildBlocklistActions(),
            _buildUserBlockedList(),
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

  Widget _buildBuiltInListToggle() {
    return SwitchListTile(
      title: Text('useBuiltInAdBlockList'.tr),
      subtitle: Text(
        'useBuiltInAdBlockListHint'
            .trParams({'count': imageBlockService.builtInBlockedHashes.length.toString()}),
      ),
      value: imageBlockService.useBuiltInList.value,
      onChanged: imageBlockService.saveUseBuiltInList,
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

  Widget _buildBlocklistActions() {
    return ListTile(
      title: Text('blockedImageTools'.tr),
      subtitle: Text('blockedImageToolsHint'.tr),
      trailing: Wrap(
        spacing: 8,
        children: [
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'clearBlockedImages'.tr,
            onPressed: imageBlockService.clearUserBlockedHashes,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_2),
            tooltip: 'clearQrCache'.tr,
            onPressed: imageBlockService.clearQrBlockedHashes,
          ),
        ],
      ),
    );
  }

  Widget _buildUserBlockedList() {
    if (imageBlockService.userBlockedHashes.isEmpty) {
      return ListTile(
        title: Text('blockedImageList'.tr),
        subtitle: Text('blockedImageListEmpty'.tr),
      );
    }

    return ExpansionTile(
      title: Text('blockedImageList'.tr),
      children: imageBlockService.userBlockedHashes
          .map(
            (hash) => ListTile(
              dense: true,
              title: Text(hash),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => imageBlockService.removeUserBlockedHash(hash),
              ),
            ),
          )
          .toList(),
    );
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
  final LayerLink _layerLink = LayerLink();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _fieldKey = GlobalKey();
  final List<_SelectedTag> _tags = [];
  List<TagAutoCompletionMatch> _suggestions = <TagAutoCompletionMatch>[];
  OverlayEntry? _overlayEntry;
  Timer? _debounce;
  int _requestId = 0;
  double _fieldHeight = 0;

  double get _fieldWidth => MediaQuery.of(context).size.width - 32;

  @override
  void initState() {
    super.initState();
    _tags.addAll(widget.initialTags.map(_SelectedTag.fromFilterValue));
    _controller.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant _QrTagSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.initialTags, widget.initialTags)) {
      _tags
        ..clear()
        ..addAll(widget.initialTags.map(_SelectedTag.fromFilterValue));
      _emitChange();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    _scheduleSearch(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFieldHeight());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompositedTransformTarget(
          link: _layerLink,
          child: TextField(
            key: _fieldKey,
            controller: _controller,
            focusNode: _focusNode,
            enabled: widget.enabled,
            decoration: InputDecoration(
              labelText: 'qrBlockFilterTagList'.tr,
              hintText: 'qrBlockFilterTagListHint'.tr,
            ),
            onSubmitted: _addTag,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List<Widget>.generate(
            _tags.length,
            (int index) => _buildChip(_tags[index], index),
          ),
        ),
      ],
    );
  }

  void _addTag(String raw) {
    final _SelectedTag tag = _SelectedTag.fromFilterValue(raw);
    if (tag.normalized.isEmpty) {
      return;
    }
    if (_tags.any((t) => t.normalized == tag.normalized)) {
      _controller.clear();
      return;
    }
    setState(() {
      _tags.add(tag);
    });
    _controller.clear();
    _emitChange();
  }

  void _updateFieldHeight() {
    final RenderBox? box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final double height = box.size.height;
    if ((height - _fieldHeight).abs() > 0.5) {
      setState(() {
        _fieldHeight = height;
      });
    }
  }

  void _removeTag(int index) {
    setState(() {
      _tags.removeAt(index);
    });
    _emitChange();
  }

  void _emitChange() {
    widget.onChanged(_tags.map((t) => t.filterValue).toList(growable: false));
  }

  Widget _buildChip(_SelectedTag tag, int index) {
    final Color fg = UIConfig.ehTagTextColor(context);
    final Color bg = UIConfig.ehTagBackGroundColor(context);
    return FilterChip(
      label: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _fieldWidth - 40),
        child: Text(
          tag.displayLabel,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      labelStyle: TextStyle(color: fg, fontSize: 12),
      backgroundColor: bg,
      selectedColor: bg,
      showCheckmark: false,
      onSelected: (_) {},
      deleteIcon: const Icon(Icons.close, size: 16),
      deleteIconColor: fg,
      onDeleted: () => _removeTag(index),
    );
  }

  void _scheduleSearch(String raw) {
    _debounce?.cancel();
    final String query = raw.trim();
    if (query.isEmpty) {
      _suggestions = <TagAutoCompletionMatch>[];
      _hideOverlay();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () => _search(query));
  }

  Future<void> _search(String query) async {
    final int captured = ++_requestId;
    List<TagAutoCompletionMatch> translationMatches = <TagAutoCompletionMatch>[];
    if (tagTranslationService.isReady) {
      translationMatches = await tagTranslationService.searchTags(query, limit: 50);
      if (!mounted || captured != _requestId) {
        return;
      }
    }

    final List<TagAutoCompletionMatch> rawMatches = await _fetchRawSuggestions(query);
    if (!mounted || captured != _requestId) {
      return;
    }

    final List<TagAutoCompletionMatch> matches = _mergeMatches(translationMatches, rawMatches)
        .where((m) => !_tags.any((t) => t.normalized == _normalizeMatch(m)))
        .toList();

    if (matches.isEmpty) {
      _suggestions = <TagAutoCompletionMatch>[];
      _hideOverlay();
      return;
    }

    _suggestions = matches;
    _showOverlay();
  }

  Future<List<TagAutoCompletionMatch>> _fetchRawSuggestions(String rawQuery) async {
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
          offset: Offset(0, (_fieldHeight == 0 ? 56 : _fieldHeight) + 4),
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
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _suggestions.length,
                itemBuilder: (BuildContext context, int index) {
                  final TagAutoCompletionMatch suggestion = _suggestions[index];
                  final TagData data = suggestion.tagData;
                  final String label =
                      data.namespace.isEmpty ? data.key : '${data.namespace}:${data.key}';
                  final String? subtitle = data.tagName ?? data.fullTagName;
                  return ListTile(
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -2),
                    title: Text(label, overflow: TextOverflow.ellipsis),
                    subtitle:
                        subtitle == null ? null : Text(subtitle, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      _addTag(suggestion.operator == null || suggestion.operator!.isEmpty
                          ? label
                          : '${suggestion.operator}$label');
                      _hideOverlay();
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SelectedTag {
  _SelectedTag(this.tagData, {this.operator});

  final TagData tagData;
  final String? operator;

  String get filterValue =>
      operator == null || operator!.isEmpty ? _rawValue : '${operator!}$_rawValue';

  String get normalized => filterValue.trim().toLowerCase();

  String get displayLabel => filterValue;

  String get _rawValue =>
      tagData.namespace.isEmpty ? tagData.key : '${tagData.namespace}:${tagData.key}';

  static _SelectedTag fromFilterValue(String value) {
    String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return _SelectedTag(TagData(namespace: '', key: ''));
    }

    String? operator;
    if (trimmed.startsWith('-') || trimmed.startsWith('~')) {
      operator = trimmed[0];
      trimmed = trimmed.substring(1).trimLeft();
    }

    final int colonIndex = trimmed.indexOf(':');
    TagData tagData;
    if (colonIndex <= 0 || colonIndex >= trimmed.length - 1) {
      tagData = TagData(namespace: '', key: trimmed);
    } else {
      tagData = TagData(
        namespace: trimmed.substring(0, colonIndex).trim(),
        key: trimmed.substring(colonIndex + 1).trim(),
      );
    }

    return _SelectedTag(tagData, operator: operator);
  }
}
