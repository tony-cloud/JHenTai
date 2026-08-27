import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/model/downloaded_gallery_cleanup.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/read_page_info.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/downloaded_gallery_cleanup_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/utils/byte_util.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/toast_util.dart';

class DuplicateGalleryCleanupPage extends StatefulWidget {
  const DuplicateGalleryCleanupPage({super.key});

  @override
  State<DuplicateGalleryCleanupPage> createState() =>
      _DuplicateGalleryCleanupPageState();
}

class _DuplicateGalleryCleanupPageState
    extends State<DuplicateGalleryCleanupPage> {
  List<DownloadedGalleryDuplicateGroup> _groups =
      const <DownloadedGalleryDuplicateGroup>[];
  final Map<int, DownloadedGalleryCleanupAction> _actions =
      <int, DownloadedGalleryCleanupAction>{};
  bool _loading = true;
  bool _applying = false;
  Object? _loadError;

  int get _selectedCount => _actions.values
      .where((action) => action != DownloadedGalleryCleanupAction.keep)
      .length;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('duplicateGalleryReview'.tr),
        actions: <Widget>[
          IconButton(
            onPressed: _loading || _applying ? null : _loadGroups,
            tooltip: 'duplicateGalleryRefresh'.tr,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            key: const ValueKey<String>('apply-duplicate-gallery-cleanup'),
            onPressed: _selectedCount == 0 || _loading || _applying
                ? null
                : _confirmAndApply,
            tooltip: 'duplicateGalleryApply'.tr,
            icon: _applying
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Badge(
                    isLabelVisible: _selectedCount > 0,
                    label: Text('$_selectedCount'),
                    child: const Icon(Icons.delete_sweep_outlined),
                  ),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text('duplicateGalleryReviewLoadFailed'.tr,
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loadGroups,
                icon: const Icon(Icons.refresh),
                label: Text('duplicateGalleryRetry'.tr),
              ),
            ],
          ),
        ),
      );
    }

    if (_groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.library_add_check_outlined,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text('duplicateGalleryReviewEmpty'.tr,
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      itemCount: _groups.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              'duplicateGalleryReviewHint'.tr,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        return _buildGroupCard(context, _groups[index - 1]);
      },
    );
  }

  Widget _buildGroupCard(
    BuildContext context,
    DownloadedGalleryDuplicateGroup group,
  ) {
    final DownloadedGalleryCleanupCandidate first = group.candidates.first;
    return Card(
      key: ValueKey<String>('duplicate-gallery-group-${group.normalizedTitle}'),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                englishGalleryTitleWithoutLanguageTag(first.englishTitle),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          for (int index = 0;
              index < group.candidates.length;
              index++) ...<Widget>[
            if (index > 0) const Divider(height: 1),
            _buildCandidateTile(context, group.candidates[index]),
          ],
        ],
      ),
    );
  }

  Widget _buildCandidateTile(
    BuildContext context,
    DownloadedGalleryCleanupCandidate candidate,
  ) {
    final DownloadedGalleryCleanupAction action =
        _actions[candidate.gallery.gid] ?? DownloadedGalleryCleanupAction.keep;
    final Color? actionColor = switch (action) {
      DownloadedGalleryCleanupAction.keep => null,
      DownloadedGalleryCleanupAction.delete =>
        Theme.of(context).colorScheme.error,
      DownloadedGalleryCleanupAction.deleteAndUnfavorite =>
        Theme.of(context).colorScheme.error,
    };

    return ListTile(
      key: ValueKey<String>('duplicate-gallery-${candidate.gallery.gid}'),
      contentPadding:
          const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 4),
      title: Text(candidate.englishTitle,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'duplicateGalleryStats'.trParams(<String, String>{
            'size': byte2String(candidate.sizeBytes.toDouble()),
            'downloaded': '${candidate.downloadedImageCount}',
            'total': '${candidate.gallery.pageCount}',
            'group': candidate.gallery.groupName,
            'gid': '${candidate.gallery.gid}',
          }),
        ),
      ),
      trailing: PopupMenuButton<DownloadedGalleryCleanupAction>(
        key: ValueKey<String>(
            'duplicate-gallery-action-${candidate.gallery.gid}'),
        initialValue: action,
        tooltip: 'duplicateGalleryChooseAction'.tr,
        onSelected: (value) =>
            setState(() => _actions[candidate.gallery.gid] = value),
        itemBuilder: (context) => DownloadedGalleryCleanupAction.values
            .map(
              (value) => PopupMenuItem<DownloadedGalleryCleanupAction>(
                value: value,
                child: Row(
                  children: <Widget>[
                    Icon(_actionIcon(value), size: 20),
                    const SizedBox(width: 10),
                    Text(_actionLabel(value)),
                  ],
                ),
              ),
            )
            .toList(growable: false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(
                color: actionColor ?? Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(_actionIcon(action), size: 18, color: actionColor),
              const SizedBox(width: 5),
              Text(_actionLabel(action), style: TextStyle(color: actionColor)),
            ],
          ),
        ),
      ),
      onTap: () => _openReader(candidate),
    );
  }

  IconData _actionIcon(DownloadedGalleryCleanupAction action) =>
      switch (action) {
        DownloadedGalleryCleanupAction.keep => Icons.bookmark_outline,
        DownloadedGalleryCleanupAction.delete => Icons.delete_outline,
        DownloadedGalleryCleanupAction.deleteAndUnfavorite =>
          Icons.heart_broken_outlined,
      };

  String _actionLabel(DownloadedGalleryCleanupAction action) =>
      switch (action) {
        DownloadedGalleryCleanupAction.keep => 'duplicateGalleryActionKeep'.tr,
        DownloadedGalleryCleanupAction.delete =>
          'duplicateGalleryActionDelete'.tr,
        DownloadedGalleryCleanupAction.deleteAndUnfavorite =>
          'deleteAndUnfavorite'.tr,
      };

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final List<DownloadedGalleryDuplicateGroup> groups =
          await downloadedGalleryCleanupService.findDuplicateGroups();
      if (!mounted) {
        return;
      }
      setState(() {
        _groups = groups;
        _actions
          ..clear()
          ..addEntries(
            groups.expand((group) => group.candidates).map(
                  (candidate) => MapEntry<int, DownloadedGalleryCleanupAction>(
                    candidate.gallery.gid,
                    DownloadedGalleryCleanupAction.keep,
                  ),
                ),
          );
        _loading = false;
      });
    } catch (error, stackTrace) {
      log.error(
          'Load downloaded duplicate gallery review failed', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _openReader(DownloadedGalleryCleanupCandidate candidate) async {
    try {
      final List<GalleryImage>? images =
          galleryDownloadService.usesRemoteRpcData
              ? await galleryDownloadService
                  .fetchRemoteGalleryImages(candidate.gallery.gid)
              : null;
      if (!mounted) {
        return;
      }

      toRoute(
        Routes.read,
        arguments: ReadPageInfo(
          mode: ReadMode.downloaded,
          gid: candidate.gallery.gid,
          token: candidate.gallery.token,
          galleryTitle: candidate.gallery.title,
          galleryUrl: candidate.gallery.galleryUrl,
          initialIndex: 0,
          readProgressRecordStorageKey: candidate.gallery.gid.toString(),
          pageCount: candidate.gallery.pageCount,
          images: images,
          useSuperResolution: superResolutionService.get(
                candidate.gallery.gid,
                SuperResolutionType.gallery,
              ) !=
              null,
        ),
      );
    } catch (error, stackTrace) {
      log.error('Open duplicate gallery in reader failed', error, stackTrace);
      toast('internalError'.tr);
    }
  }

  Future<void> _confirmAndApply() async {
    final Map<DownloadedGalleryCleanupCandidate, DownloadedGalleryCleanupAction>
        selected =
        <DownloadedGalleryCleanupCandidate, DownloadedGalleryCleanupAction>{};
    for (final DownloadedGalleryDuplicateGroup group in _groups) {
      for (final DownloadedGalleryCleanupCandidate candidate
          in group.candidates) {
        final DownloadedGalleryCleanupAction action =
            _actions[candidate.gallery.gid] ??
                DownloadedGalleryCleanupAction.keep;
        if (action != DownloadedGalleryCleanupAction.keep) {
          selected[candidate] = action;
        }
      }
    }

    if (selected.isEmpty) {
      return;
    }

    final int unfavoriteCount = selected.values
        .where((action) =>
            action == DownloadedGalleryCleanupAction.deleteAndUnfavorite)
        .length;
    final bool? confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: Text('duplicateGalleryConfirmTitle'.tr),
        content: Text(
          'duplicateGalleryConfirmMessage'.trParams(<String, String>{
            'delete': '${selected.length}',
            'unfavorite': '$unfavoriteCount',
          }),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Get.back(result: false),
              child: Text('cancel'.tr)),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: Text('duplicateGalleryConfirm'.tr),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _applying = true);
    final DownloadedGalleryCleanupResult result =
        await downloadedGalleryCleanupService.applyActions(selected);
    if (!mounted) {
      return;
    }

    final Set<int> removedGids = selected.keys
        .map((candidate) => candidate.gallery.gid)
        .where((gid) => !result.failedGids.contains(gid))
        .toSet();
    setState(() {
      _groups = _groups
          .map(
            (group) => DownloadedGalleryDuplicateGroup(
              normalizedTitle: group.normalizedTitle,
              candidates: group.candidates
                  .where((candidate) =>
                      !removedGids.contains(candidate.gallery.gid))
                  .toList(growable: false),
            ),
          )
          .where((group) => group.candidates.length > 1)
          .toList(growable: false);
      for (final int gid in removedGids) {
        _actions.remove(gid);
      }
      _applying = false;
    });

    toast(
      'duplicateGalleryCleanupResult'.trParams(<String, String>{
        'deleted': '${result.deleted}',
        'unfavorited': '${result.unfavorited}',
        'failed': '${result.failedGids.length}',
      }),
      isCenter: false,
    );
  }
}
