import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:jhentai/widget/eh_group_name_selector.dart';

typedef EHBatchDownloadConfig = ({
  String group,
  bool downloadOriginalImage,
  bool useArchiveForNewGalleryOnly,
});

class EHBatchDownloadDialog extends StatefulWidget {
  final String title;
  final String? currentGroup;
  final List<String> candidates;
  final bool showDownloadOriginalImageCheckBox;
  final bool downloadOriginalImage;
  final bool useArchiveForNewGalleryOnly;

  const EHBatchDownloadDialog({
    super.key,
    required this.title,
    this.currentGroup,
    required this.candidates,
    this.showDownloadOriginalImageCheckBox = false,
    this.downloadOriginalImage = false,
    this.useArchiveForNewGalleryOnly = false,
  });

  @override
  State<EHBatchDownloadDialog> createState() => _EHBatchDownloadDialogState();
}

class _EHBatchDownloadDialogState extends State<EHBatchDownloadDialog> {
  late String group;
  late List<String> candidates;
  late bool downloadOriginalImage;
  late bool useArchiveForNewGalleryOnly;

  @override
  void initState() {
    super.initState();

    group = widget.currentGroup ?? widget.candidates.firstOrNull ?? 'default'.tr;
    candidates = List.of(widget.candidates);
    candidates.remove(group);
    candidates.insert(0, group);
    downloadOriginalImage = widget.downloadOriginalImage;
    useArchiveForNewGalleryOnly = widget.useArchiveForNewGalleryOnly;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12, top: 24),
      actionsPadding: const EdgeInsets.only(left: 24, right: 20, bottom: 12),
      content: _buildBody(),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          onPressed: () {
            if (group.isEmpty) {
              toast('invalid'.tr);
              backRoute();
              return;
            }

            backRoute(
              result: (
                group: group,
                downloadOriginalImage: downloadOriginalImage,
                useArchiveForNewGalleryOnly: useArchiveForNewGalleryOnly,
              ),
            );
          },
          child: Text('OK'.tr),
        ),
      ],
    );
  }

  Widget _buildBody() {
    return SizedBox(
      width: UIConfig.downloadDialogWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EHGroupNameSelector(
            currentGroup: widget.currentGroup ?? 'default'.tr,
            candidates: candidates,
            listener: (g) => group = g,
          ),
          if (widget.showDownloadOriginalImageCheckBox)
            _buildCheckBox(
              text: '${'downloadOriginalImage'.tr} ?',
              value: downloadOriginalImage,
              onChanged: (value) => setState(() => downloadOriginalImage = value ?? true),
            ).marginOnly(top: 16),
          _buildCheckBox(
            text: 'useArchiveDownloadForNewGalleryOnly'.tr,
            value: useArchiveForNewGalleryOnly,
            onChanged: (value) => setState(() => useArchiveForNewGalleryOnly = value ?? false),
          ).marginOnly(top: 16),
        ],
      ),
    );
  }

  Widget _buildCheckBox({
    required String text,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return SizedBox(
      width: UIConfig.downloadDialogWidth,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: UIConfig.groupDialogCheckBoxTextSize,
              ),
            ),
          ),
          Checkbox(
            value: value,
            activeColor: UIConfig.groupDialogCheckBoxColor(context),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
