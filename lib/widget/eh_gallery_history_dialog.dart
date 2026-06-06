import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_history_entry.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/pages/details/details_page_logic.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/gallery_history_lineage_service.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/widget/eh_wheel_speed_controller.dart';

class EHGalleryHistoryDialog extends StatefulWidget {
  final String currentGalleryTitle;
  final GalleryUrl? parentUrl;
  final List<GalleryHistoryEntry>? childrenGallerys;
  final GalleryDetail baseDetail;
  final DetailsPageLogic logic;

  const EHGalleryHistoryDialog({
    super.key,
    required this.currentGalleryTitle,
    this.parentUrl,
    this.childrenGallerys,
    required this.baseDetail,
    required this.logic,
  });

  @override
  State<EHGalleryHistoryDialog> createState() => _EHGalleryHistoryDialogState();
}

class _EHGalleryHistoryDialogState extends State<EHGalleryHistoryDialog>
    with SingleTickerProviderStateMixin {
  late final List<GalleryHistoryEntry> _descendants;
  final List<GalleryHistoryEntry> _ancestors = [];
  GalleryHistoryEntry? _parentEntry;
  final Set<int> _visitedGids = <int>{};
  bool _isSearching = false;
  bool _running = true;
  late final int _searchLimit;
  late final bool _unlimited;
  int _addedCount = 0;
  late final AnimationController _marqueeController;
  bool _marqueeStarted = false;
  int _marqueeSubscribers = 0;

  @override
  void initState() {
    super.initState();

    _marqueeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    _descendants = List<GalleryHistoryEntry>.from(
      widget.childrenGallerys ?? <GalleryHistoryEntry>[],
    ).reversed.toList();

    _visitedGids.add(widget.baseDetail.galleryUrl.gid);
    for (GalleryHistoryEntry entry in _descendants) {
      _visitedGids.add(entry.galleryUrl.gid);
    }

    _searchLimit = advancedSetting.historySearchLimit.value;
    _unlimited = _searchLimit <= 0;

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _startRecursiveSearch(),
    );
  }

  @override
  void dispose() {
    _marqueeController.dispose();
    _running = false;
    super.dispose();
  }

  Future<void> _startRecursiveSearch() async {
    if (!_running || _isSearching) {
      return;
    }

    setState(() => _isSearching = true);

    if (await _searchHistoryChain()) {
      if (!_running || !mounted) {
        return;
      }

      setState(() => _isSearching = false);
      return;
    }

    if (widget.parentUrl == null && _descendants.isEmpty) {
      if (!_running || !mounted) {
        return;
      }

      setState(() => _isSearching = false);
      return;
    }

    await Future.wait(<Future<void>>[
      _searchAncestors(),
      _searchDescendants(),
    ]);

    if (!_running || !mounted) {
      return;
    }

    setState(() => _isSearching = false);
  }

  Future<bool> _searchHistoryChain() async {
    final GalleryHistoryChain? historyChain =
        await galleryHistoryLineageService.getHistoryChainFromFirstGallery(
      baseDetail: widget.baseDetail,
      fetchDetail: widget.logic.fetchGalleryDetailForHistory,
      useCache: true,
    );

    if (!_running || historyChain == null) {
      return false;
    }

    final int currentGid = widget.baseDetail.galleryUrl.gid;
    if (!historyChain.containsGid(currentGid)) {
      return false;
    }

    final List<GalleryHistoryEntry> descendants = <GalleryHistoryEntry>[];
    final List<GalleryHistoryEntry> ancestors = <GalleryHistoryEntry>[];
    GalleryHistoryEntry? parentEntry;
    int addedCount = 0;

    bool canAdd() => _unlimited || addedCount < _searchLimit;

    for (final GalleryHistoryEntry entry in historyChain.entriesAfterGid(currentGid).reversed) {
      if (!canAdd()) {
        break;
      }

      descendants.add(entry);
      addedCount++;
    }

    final List<GalleryHistoryEntry> beforeCurrent = historyChain.entriesBeforeGid(currentGid);
    if (beforeCurrent.isNotEmpty && canAdd()) {
      parentEntry = beforeCurrent.last;
      addedCount++;
    }

    for (int index = beforeCurrent.length - 2; index >= 0 && canAdd(); index--) {
      ancestors.add(beforeCurrent[index]);
      addedCount++;
    }

    if (!_running || !mounted) {
      return true;
    }

    setState(() {
      _descendants
        ..clear()
        ..addAll(descendants);
      _parentEntry = parentEntry;
      _ancestors
        ..clear()
        ..addAll(ancestors);
      _addedCount = addedCount;
      for (final GalleryHistoryEntry entry in historyChain.entries) {
        _visitedGids.add(entry.galleryUrl.gid);
      }
    });

    return true;
  }

  Future<void> _searchAncestors() async {
    GalleryUrl? currentParent = widget.parentUrl;
    bool handledParent = false;

    while (_running && currentParent != null && !_hitLimit()) {
      GalleryDetail? detail = await widget.logic.fetchGalleryDetailForHistory(
        currentParent,
        useCacheIfAvailable: true,
      );

      if (!_running || detail == null) {
        break;
      }

      if (_visitedGids.contains(detail.galleryUrl.gid)) {
        currentParent = detail.parentGalleryUrl;
        continue;
      }
      _visitedGids.add(detail.galleryUrl.gid);

      GalleryHistoryEntry entry = _detail2Entry(detail);

      if (!mounted || !_running) {
        break;
      }

      setState(() {
        if (!handledParent) {
          _parentEntry = entry;
          handledParent = true;
        } else {
          _ancestors.add(entry);
        }
        _addedCount++;
      });

      currentParent = detail.parentGalleryUrl;
    }
  }

  Future<void> _searchDescendants() async {
    GalleryDetail currentDetail = widget.baseDetail;

    while (_running && (currentDetail.childrenGallerys?.isNotEmpty ?? false) && !_hitLimit()) {
      GalleryUrl? nextUrl = currentDetail.newVersionGalleryUrl;
      if (nextUrl == null) {
        break;
      }

      if (_visitedGids.contains(nextUrl.gid)) {
        break;
      }

      GalleryDetail? detail = await widget.logic.fetchGalleryDetailForHistory(
        nextUrl,
        useCacheIfAvailable: true,
      );

      if (!_running || detail == null) {
        break;
      }

      _visitedGids.add(detail.galleryUrl.gid);

      if (!mounted || !_running) {
        break;
      }

      setState(() {
        _descendants.insert(0, _detail2Entry(detail));
        _addedCount++;
      });

      currentDetail = detail;
    }
  }

  GalleryHistoryEntry _detail2Entry(GalleryDetail detail) {
    return (
      galleryUrl: detail.galleryUrl,
      title: _formatTitle(detail),
      updateTime: detail.publishTime,
    );
  }

  String _formatTitle(GalleryDetail detail) {
    String? japaneseTitle = detail.japaneseTitle;
    if (japaneseTitle != null && japaneseTitle.isNotEmpty) {
      return japaneseTitle;
    }
    String rawTitle = detail.rawTitle;
    if (rawTitle.isNotEmpty) {
      return rawTitle;
    }
    return widget.currentGalleryTitle;
  }

  void _navigateTo(GalleryUrl url) {
    backRoute();
    toRoute(
      Routes.details,
      arguments: DetailsPageArgument(galleryUrl: url),
      offAllBefore: false,
      preventDuplicates: false,
    );
  }

  Widget _buildDescendantTile(GalleryHistoryEntry entry) {
    return _buildTile(
      entry,
      trailing: entry.updateTime,
      isDownloaded: _isDownloaded(entry.galleryUrl),
    );
  }

  Widget _buildCurrentTile() {
    return _buildTile(
      (
        galleryUrl: widget.baseDetail.galleryUrl,
        title: widget.currentGalleryTitle,
        updateTime: 'current'.tr,
      ),
      selected: true,
      enableTap: false,
      isDownloaded: _isDownloaded(widget.baseDetail.galleryUrl),
    );
  }

  List<Widget> _buildParentTiles() {
    if (widget.parentUrl == null && _parentEntry == null) {
      return const <Widget>[];
    }

    final GalleryHistoryEntry entry = _parentEntry ??
        (
          galleryUrl: widget.parentUrl!,
          title: 'parentGallery'.tr,
          updateTime: '',
        );

    return <Widget>[
      _buildTile(
        entry,
        trailing: entry.updateTime.isEmpty
            ? const Icon(
                Icons.exit_to_app,
                size: UIConfig.galleryHistoryDialogSubtitleIconSize,
              )
            : entry.updateTime,
        isDownloaded: _isDownloaded(entry.galleryUrl),
      ),
    ];
  }

  List<Widget> _buildAncestorTiles() {
    return _ancestors
        .map(
          (GalleryHistoryEntry entry) => _buildTile(
            entry,
            trailing: entry.updateTime,
            isDownloaded: _isDownloaded(entry.galleryUrl),
          ),
        )
        .toList();
  }

  Widget _buildTile(
    GalleryHistoryEntry entry, {
    Object? trailing,
    bool selected = false,
    bool enableTap = true,
    bool isDownloaded = false,
  }) {
    final List<Widget> trailingWidgets = <Widget>[];

    if (isDownloaded) {
      trailingWidgets.add(const Icon(Icons.download_done, size: 16));
    }

    if (trailing != null) {
      if (trailingWidgets.isNotEmpty) {
        trailingWidgets.add(const SizedBox(width: 6));
      }

      if (trailing is Widget) {
        trailingWidgets.add(trailing);
      } else if (trailing.toString().isNotEmpty) {
        trailingWidgets.add(
          Text(
            trailing.toString(),
            style: const TextStyle(fontSize: UIConfig.galleryHistoryDialogTrailingTextSize),
          ),
        );
      }
    }

    return ListTile(
      key: ValueKey<int>(entry.galleryUrl.gid),
      dense: true,
      title: _buildMarqueeTitle(entry.title),
      trailing: trailingWidgets.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: trailingWidgets),
      selected: selected,
      selectedTileColor: selected ? UIConfig.galleryHistoryDialogTileColor(context) : null,
      onTap: enableTap ? () => _navigateTo(entry.galleryUrl) : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Widget _buildSearchingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('loading'.tr),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> children = <Widget>[
      ..._descendants.map(_buildDescendantTile),
      _buildCurrentTile(),
      ..._buildParentTiles(),
      ..._buildAncestorTiles(),
      if (_isSearching) _buildSearchingIndicator(),
    ];

    final int tileCount = children.isEmpty ? 1 : children.length;
    final int visibleCount = tileCount > 5 ? 5 : tileCount;
    final double maxHeight = visibleCount * 72.0;

    return EHWheelSpeedController(
      controller: null,
      child: SimpleDialog(
        title: Center(child: Text('history'.tr)),
        contentPadding: const EdgeInsets.only(top: 18, left: 12, right: 12, bottom: 12),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }

  bool _hitLimit() => !_unlimited && _addedCount >= _searchLimit;

  bool _isDownloaded(GalleryUrl url) {
    return galleryDownloadService.gallerys.any((g) => g.gid == url.gid);
  }

  Widget _buildMarqueeTitle(String title) {
    return _MarqueeTitle(
      title: title,
      style: const TextStyle(fontSize: UIConfig.galleryHistoryTitleSize),
      animation: _marqueeController,
      onOverflowChanged: _handleOverflowChange,
    );
  }

  void _handleOverflowChange(bool overflow) {
    if (overflow) {
      _marqueeSubscribers++;
      if (!_marqueeStarted) {
        _marqueeStarted = true;
        _marqueeController.repeat();
      }
      return;
    }

    if (_marqueeSubscribers == 0) {
      return;
    }

    _marqueeSubscribers = _marqueeSubscribers > 0 ? _marqueeSubscribers - 1 : 0;

    if (_marqueeSubscribers == 0 && _marqueeStarted) {
      _marqueeStarted = false;
      _marqueeController.stop();
      _marqueeController.reset();
    }
  }
}

class _MarqueeTitle extends StatefulWidget {
  final String title;
  final TextStyle style;
  final Animation<double> animation;
  final ValueChanged<bool> onOverflowChanged;

  const _MarqueeTitle({
    required this.title,
    required this.style,
    required this.animation,
    required this.onOverflowChanged,
  });

  @override
  State<_MarqueeTitle> createState() => _MarqueeTitleState();
}

class _MarqueeTitleState extends State<_MarqueeTitle> {
  static const double _gap = 32;
  double? _maxWidth;
  double? _textWidth;
  double? _textHeight;
  bool _isOverflow = false;

  @override
  void initState() {
    super.initState();
    final Size textSize = _calculateTextSize(widget.title, widget.style);
    _textWidth = textSize.width;
    _textHeight = textSize.height;
  }

  @override
  void didUpdateWidget(covariant _MarqueeTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title || oldWidget.style != widget.style) {
      final Size textSize = _calculateTextSize(widget.title, widget.style);
      if (textSize.width != _textWidth || textSize.height != _textHeight) {
        setState(() {
          _textWidth = textSize.width;
          _textHeight = textSize.height;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleWidthMeasurement();

    final bool hasWidths = _maxWidth != null && _textWidth != null && _maxWidth! > 0;
    final bool overflow = hasWidths && _textWidth! > _maxWidth!;

    if (overflow != _isOverflow) {
      _isOverflow = overflow;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onOverflowChanged(overflow),
      );
    }

    if (!overflow || _textWidth == null) {
      return Text(
        widget.title,
        maxLines: 1,
        overflow: TextOverflow.visible,
        style: widget.style,
      );
    }

    final double scrollWidth = _textWidth! + (_gap * 2);
    final double textHeight = _textHeight ?? (widget.style.fontSize ?? 14);

    return ClipRect(
      child: SizedBox(
        height: textHeight,
        child: AnimatedBuilder(
          animation: widget.animation,
          builder: (BuildContext context, Widget? child) {
            final double offset = -scrollWidth * widget.animation.value;

            return Transform.translate(
              offset: Offset(offset, 0),
              child: SizedBox(
                width: scrollWidth * 2,
                height: textHeight,
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: _textWidth! + _gap,
                      height: textHeight,
                      child: Text(
                        widget.title,
                        style: widget.style,
                        maxLines: 1,
                        softWrap: true,
                      ),
                    ),
                    const SizedBox(width: _gap),
                    SizedBox(
                      width: _textWidth! + _gap,
                      height: textHeight,
                      child: Text(
                        widget.title,
                        style: widget.style,
                        maxLines: 1,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _scheduleWidthMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final RenderBox? box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        return;
      }

      final double width = box.size.width;
      if (_maxWidth == width) {
        return;
      }

      setState(() => _maxWidth = width);
    });
  }

  Size _calculateTextSize(String title, TextStyle style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: title, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);

    return painter.size;
  }

  @override
  void dispose() {
    if (_isOverflow) {
      widget.onOverflowChanged(false);
    }
    super.dispose();
  }
}
