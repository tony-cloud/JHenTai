import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/pages/details/details_page_logic.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/widget/eh_wheel_speed_controller.dart';

typedef GalleryHistoryEntry = ({GalleryUrl galleryUrl, String title, String updateTime});

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

class _EHGalleryHistoryDialogState extends State<EHGalleryHistoryDialog> {
  late final List<GalleryHistoryEntry> _descendants;
  final List<GalleryHistoryEntry> _ancestors = [];
  GalleryHistoryEntry? _parentEntry;
  final Set<int> _visitedGids = <int>{};
  bool _isSearching = false;
  bool _running = true;
  late final int _searchLimit;
  late final bool _unlimited;
  int _addedCount = 0;

  @override
  void initState() {
    super.initState();

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
    _running = false;
    super.dispose();
  }

  Future<void> _startRecursiveSearch() async {
    if (!_running || _isSearching) {
      return;
    }

    if (widget.parentUrl == null && _descendants.isEmpty) {
      return;
    }

    setState(() => _isSearching = true);

    await Future.wait(<Future<void>>[
      _searchAncestors(),
      _searchDescendants(),
    ]);

    if (!_running || !mounted) {
      return;
    }

    setState(() => _isSearching = false);
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
      GalleryUrl nextUrl = currentDetail.childrenGallerys!.last.galleryUrl;

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
      dense: true,
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: UIConfig.galleryHistoryTitleSize),
      ),
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
}
