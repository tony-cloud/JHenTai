import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/service/image_block_service.dart';

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
