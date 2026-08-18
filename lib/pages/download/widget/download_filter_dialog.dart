import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/model/gallery_tag.dart';
import 'package:jhentai/pages/download/filter/download_filter.dart';
import 'package:jhentai/pages/search/mixin/search_page_mixin.dart';
import 'package:jhentai/model/eh_raw_tag.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/download_filter_service.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

import 'package:jhentai/service/log.dart';

Future<DownloadFilter?> showDownloadFilterDialog({
  required BuildContext context,
  required DownloadFilter initialFilter,
  required List<String> availableGroups,
}) {
  return showDialog<DownloadFilter>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadFilterDialog(
      initialFilter: initialFilter,
      availableGroups: availableGroups,
    ),
  );
}

@visibleForTesting
Widget buildDownloadTagSuggestionPopup({
  required LayerLink layerLink,
  required double width,
  required Widget child,
}) {
  return UnconstrainedBox(
    child: CompositedTransformFollower(
      link: layerLink,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomCenter,
      followerAnchor: Alignment.topCenter,
      offset: const Offset(0, 4),
      child: Material(
        key: const ValueKey<String>('download-tag-suggestion-popup'),
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: width,
            maxWidth: width,
            maxHeight: 240,
          ),
          child: child,
        ),
      ),
    ),
  );
}

class _DownloadFilterDialog extends StatefulWidget {
  const _DownloadFilterDialog({
    required this.initialFilter,
    required this.availableGroups,
  });

  final DownloadFilter initialFilter;
  final List<String> availableGroups;

  @override
  State<_DownloadFilterDialog> createState() => _DownloadFilterDialogState();
}

class _DownloadFilterDialogState extends State<_DownloadFilterDialog> {
  late final TextEditingController _keywordController;
  final GlobalKey<_TagSelectorState> _tagSelectorKey = GlobalKey<_TagSelectorState>();
  late Set<String> _selectedGroups;
  late DownloadCompletionFilter _completion;
  late List<String> _includeTags;

  @override
  void initState() {
    super.initState();
    _keywordController = TextEditingController(text: widget.initialFilter.keyword);
    _selectedGroups = Set<String>.from(widget.initialFilter.selectedGroups);
    _completion = widget.initialFilter.completion;
    _includeTags = List<String>.from(widget.initialFilter.includeTags);
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> groups = <String>{
      ...widget.availableGroups,
      ..._selectedGroups,
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return AlertDialog(
      title: Text('filter'.tr),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _keywordController,
              decoration: InputDecoration(
                labelText: 'keyword'.tr,
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            _TagSelector(
              key: _tagSelectorKey,
              initialTags: _includeTags,
              onChanged: (List<String> tags) => setState(() => _includeTags = tags),
            ),
            const SizedBox(height: 16),
            Text('downloadFilterGroups'.tr,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: groups
                  .map(
                    (String group) => FilterChip(
                      label: Text(group.isEmpty ? 'default'.tr : group),
                      selected: _selectedGroups.contains(group),
                      onSelected: (bool selected) {
                        setState(() {
                          if (selected) {
                            _selectedGroups.add(group);
                          } else {
                            _selectedGroups.remove(group);
                          }
                        });
                      },
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
            Text('downloadFilterCompletion'.tr,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14)),
            const SizedBox(height: 8),
            DropdownButton<DownloadCompletionFilter>(
              isExpanded: true,
              value: _completion,
              items: DownloadCompletionFilter.values
                  .map(
                    (DownloadCompletionFilter option) => DropdownMenuItem<DownloadCompletionFilter>(
                      value: option,
                      child: Text(_completionLabel(option)),
                    ),
                  )
                  .toList(),
              onChanged: (DownloadCompletionFilter? value) {
                if (value == null) {
                  return;
                }
                setState(() => _completion = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              _keywordController.clear();
              _includeTags = const <String>[];
              _selectedGroups.clear();
              _completion = DownloadCompletionFilter.all;
            });
            _tagSelectorKey.currentState?.reset();
          },
          child: Text('reset'.tr),
        ),
        TextButton(
          onPressed: () => Get.back<DownloadFilter?>(),
          child: Text('cancel'.tr),
        ),
        TextButton(
          onPressed: _handleSubmit,
          child: Text('OK'.tr),
        ),
      ],
    );
  }

  void _handleSubmit() {
    final DownloadFilter filter = DownloadFilter(
      keyword: _keywordController.text.trim(),
      includeTags: List<String>.from(_includeTags),
      selectedGroups: Set<String>.from(_selectedGroups),
      completion: _completion,
    );

    Get.back(result: filter);
  }

  String _completionLabel(DownloadCompletionFilter filter) {
    switch (filter) {
      case DownloadCompletionFilter.all:
        return 'all'.tr;
      case DownloadCompletionFilter.finished:
        return 'finished'.tr;
      case DownloadCompletionFilter.unfinished:
        return 'unfinished'.tr;
    }
  }
}

class _TagSelector extends StatefulWidget {
  const _TagSelector({
    super.key,
    required this.initialTags,
    required this.onChanged,
  });

  final List<String> initialTags;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_TagSelector> createState() => _TagSelectorState();
}

class _TagSelectorState extends State<_TagSelector> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();

  final List<_SelectedTag> _tags = <_SelectedTag>[];
  List<TagAutoCompletionMatch> _suggestions = <TagAutoCompletionMatch>[];

  OverlayEntry? _overlayEntry;
  Timer? _debounce;
  int _requestId = 0;
  double _fieldWidth = 280;

  Timer? _hideOnUnfocusTimer;

  @override
  void initState() {
    super.initState();
    for (final String raw in widget.initialTags) {
      final _SelectedTag tag = _createSelectedTagFromRaw(raw);
      _addTagInternal(tag, notifyParent: false);
    }
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        // 延时隐藏，给 ListTile 的 onTap 留出触发时间
        _hideOnUnfocusTimer?.cancel();
        _hideOnUnfocusTimer = Timer(const Duration(milliseconds: 200), _hideOverlay);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _hideOverlay();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void reset() {
    _debounce?.cancel();
    _hideOverlay();
    setState(() {
      _controller.clear();
      _tags.clear();
      _suggestions = <TagAutoCompletionMatch>[];
    });
    widget.onChanged(const <String>[]);
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle labelStyle = Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14) ??
        const TextStyle(fontSize: 14);

    final double screenWidth = MediaQuery.of(context).size.width;
    double containerWidth = screenWidth.isFinite ? screenWidth - 96 : 280;
    if (containerWidth < 200) {
      containerWidth = 200;
    } else if (containerWidth > 360) {
      containerWidth = 360;
    }
    _fieldWidth = containerWidth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('downloadFilterIncludeTags'.tr, style: labelStyle),
        const SizedBox(height: 8),
        _buildSelectedTagChips(context, containerWidth),
        if (_tags.isNotEmpty) const SizedBox(height: 8),
        SizedBox(
          width: containerWidth,
          child: CompositedTransformTarget(
            link: _layerLink,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'downloadFilterIncludeTagsHint'.tr,
              ),
              onChanged: _onTextChanged,
              onSubmitted: (_) => _hideOverlay(),
              textInputAction: TextInputAction.search,
              minLines: 1,
              maxLines: 1,
            ),
          ),
        ),
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

    setState(() => _tags.add(tag));
    if (notifyParent) {
      widget.onChanged(
        _tags.map((t) => t.filterValue).toList(growable: false),
      );
    }

    if (tagTranslationService.isReady) {
      tagTranslationService
          .getTagTranslation(tag.tagData.namespace, tag.tagData.key)
          .then((TagData? translated) {
        if (!mounted || translated == null) {
          return;
        }
        setState(() => tag.updateTagData(translated));
      });
    }

    _controller.clear();
    _hideOverlay();
    _focusNode.requestFocus();
  }

  void _removeTagAt(int index) {
    setState(() => _tags.removeAt(index));
    widget.onChanged(
      _tags.map((t) => t.filterValue).toList(growable: false),
    );
    _scheduleSearch(_controller.text);
  }

  void _scheduleSearch(String rawQuery) {
    _debounce?.cancel();

    final String query = rawQuery.trim();
    if (query.isEmpty) {
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

    List<TagAutoCompletionMatch> rawMatches = await _fetchRawTagSuggestions(query);
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
      final List<EHRawTag> tags =
          await ehRequest.requestTagSuggestion(searchTerm, EHSpiderParser.tagSuggestion2TagList);
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
      log.error('Request download tag suggestion failed', e);
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

  OverlayEntry _buildOverlay() {
    return OverlayEntry(
      builder: (BuildContext context) => buildDownloadTagSuggestionPopup(
        layerLink: _layerLink,
        width: _fieldWidth,
        child: _TagSuggestionList(
          suggestions: _suggestions,
          onTap: _handleSuggestionTap,
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

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
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

  void _handleSuggestionTap(TagAutoCompletionMatch suggestion) {
    log.debug('Tag suggestion tapped: ${suggestion.tagData.namespace}:${suggestion.tagData.key}');
    _addTagInternal(_createSelectedTagFromSuggestion(suggestion));
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
}

class _TagSuggestionList extends StatelessWidget {
  const _TagSuggestionList({
    required this.suggestions,
    required this.onTap,
  });

  final List<TagAutoCompletionMatch> suggestions;
  final ValueChanged<TagAutoCompletionMatch> onTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final TextStyle highlightStyle = titleStyle.copyWith(
        color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600);
    final TextStyle subtitleStyle =
        Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12);
    final TextStyle subtitleHighlight = subtitleStyle.copyWith(
        color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600);

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
  _SelectedTag(TagData tagData, {this.operator}) : galleryTag = GalleryTag(tagData: tagData);

  final GalleryTag galleryTag;
  final String? operator;

  TagData get tagData => galleryTag.tagData;

  String get filterValue => operator == null || operator!.isEmpty
      ? _tagValue(tagData)
      : '${operator!}${_tagValue(tagData)}';

  String get normalized => _normalize(tagData, operator);

  void updateTagData(TagData tagData) {
    galleryTag.tagData = tagData;
  }

  static String _normalize(TagData tagData, String? operator) {
    final String value = operator == null || operator.isEmpty
        ? _tagValue(tagData)
        : '$operator${_tagValue(tagData)}';
    return value.trim().toLowerCase();
  }

  static String _tagValue(TagData tagData) =>
      tagData.namespace.isEmpty ? tagData.key : '${tagData.namespace}:${tagData.key}';
}
