import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/setting/style_setting.dart';

import '../../../model/jh_layout.dart';
import '../../../routes/routes.dart';
import '../../../utils/route_util.dart';

class SettingStylePage extends StatelessWidget {
  const SettingStylePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('styleSetting'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildBrightness(),
            _buildThemeColor(),
            _buildListMode(),
            if (styleSetting.isInWaterFlowListMode) _buildCrossAxisCountInWaterFallFlow().fadeInWidget(),
            _buildPageListMode(),
            _buildCrossAxisCountInGridDownloadPageForGroup(),
            _buildCrossAxisCountInGridDownloadPageForGallery(),
            _buildCrossAxisCountInDetailPage(),
            if (!styleSetting.isInWaterFlowListMode) _buildMoveCover2RightSide().fadeInWidget(),
            _buildLayout(context),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildBrightness() {
    return ListTile(
      title: Text('themeMode'.tr),
      trailing: DropdownButton<ThemeMode>(
        value: styleSetting.themeMode.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (ThemeMode? newValue) => styleSetting.saveThemeMode(newValue!),
        items: [
          DropdownMenuItem(value: ThemeMode.light, child: Text('light'.tr)),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('dark'.tr)),
          DropdownMenuItem(value: ThemeMode.system, child: Text('followSystem'.tr)),
        ],
      ),
    );
  }

  Widget _buildThemeColor() {
    return ListTile(
      title: Text('themeColor'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right),
      onTap: () => toRoute(Routes.themeColor),
    );
  }

  Widget _buildListMode() {
    return ListTile(
      title: Text('listStyle'.tr),
      trailing: DropdownButton<ListMode>(
        value: styleSetting.listMode.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (ListMode? newValue) => styleSetting.saveListMode(newValue!),
        items: [
          DropdownMenuItem(value: ListMode.flat, child: Text('flat'.tr)),
          DropdownMenuItem(value: ListMode.flatWithoutTags, child: Text('flatWithoutTags'.tr)),
          DropdownMenuItem(value: ListMode.listWithTags, child: Text('listWithTags'.tr)),
          DropdownMenuItem(value: ListMode.listWithoutTags, child: Text('listWithoutTags'.tr)),
          DropdownMenuItem(
              value: ListMode.waterfallFlowSmall,
              child: Text('waterfallFlowSmall'.tr)),
          DropdownMenuItem(
              value: ListMode.waterfallFlowMedium,
              child: Text('waterfallFlowMedium'.tr)),
          DropdownMenuItem(value: ListMode.waterfallFlowBig, child: Text('waterfallFlowBig'.tr)),
        ],
      ),
    );
  }

  Widget _buildCrossAxisCountInWaterFallFlow() {
    return ListTile(
      title: Text('crossAxisCountInWaterFallFlow'.tr),
      trailing: DropdownButton<int?>(
        value: styleSetting.crossAxisCountInWaterFallFlow.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: styleSetting.saveCrossAxisCountInWaterFallFlow,
        items: [
          DropdownMenuItem(value: null, child: Text('auto'.tr)),
          DropdownMenuItem(value: 2, child: Text('2'.tr)),
          DropdownMenuItem(value: 3, child: Text('3'.tr)),
          DropdownMenuItem(value: 4, child: Text('4'.tr)),
          DropdownMenuItem(value: 5, child: Text('5'.tr)),
          DropdownMenuItem(value: 6, child: Text('6'.tr)),
        ],
      ),
    );
  }

  Widget _buildCrossAxisCountInGridDownloadPageForGroup() {
    return ListTile(
      title: Text('crossAxisCountInGridDownloadPageForGroup'.tr),
      trailing: DropdownButton<int?>(
        value: styleSetting.crossAxisCountInGridDownloadPageForGroup.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: styleSetting.saveCrossAxisCountInGridDownloadPageForGroup,
        items: [
          DropdownMenuItem(value: null, child: Text('auto'.tr)),
          DropdownMenuItem(value: 2, child: Text('2'.tr)),
          DropdownMenuItem(value: 3, child: Text('3'.tr)),
          DropdownMenuItem(value: 4, child: Text('4'.tr)),
          DropdownMenuItem(value: 5, child: Text('5'.tr)),
          DropdownMenuItem(value: 6, child: Text('6'.tr)),
        ],
      ),
    );
  }

  Widget _buildCrossAxisCountInGridDownloadPageForGallery() {
    return ListTile(
      title: Text('crossAxisCountInGridDownloadPageForGallery'.tr),
      trailing: DropdownButton<int?>(
        value: styleSetting.crossAxisCountInGridDownloadPageForGallery.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: styleSetting.saveCrossAxisCountInGridDownloadPageForGallery,
        items: [
          DropdownMenuItem(value: null, child: Text('auto'.tr)),
          DropdownMenuItem(value: 2, child: Text('2'.tr)),
          DropdownMenuItem(value: 3, child: Text('3'.tr)),
          DropdownMenuItem(value: 4, child: Text('4'.tr)),
          DropdownMenuItem(value: 5, child: Text('5'.tr)),
          DropdownMenuItem(value: 6, child: Text('6'.tr)),
        ],
      ),
    );
  }

  Widget _buildCrossAxisCountInDetailPage() {
    return ListTile(
      title: Text('crossAxisCountInDetailPage'.tr),
      trailing: DropdownButton<int?>(
        value: styleSetting.crossAxisCountInDetailPage.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: styleSetting.saveCrossAxisCountInDetailPage,
        items: [
          DropdownMenuItem(value: null, child: Text('auto'.tr)),
          DropdownMenuItem(value: 2, child: Text('2'.tr)),
          DropdownMenuItem(value: 3, child: Text('3'.tr)),
          DropdownMenuItem(value: 4, child: Text('4'.tr)),
          DropdownMenuItem(value: 5, child: Text('5'.tr)),
          DropdownMenuItem(value: 6, child: Text('6'.tr)),
        ],
      ),
    );
  }

  Widget _buildPageListMode() {
    return ListTile(
      title: Text('pageListStyle'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right),
      onTap: () => toRoute(Routes.pageListStyle),
    );
  }

  Widget _buildMoveCover2RightSide() {
    return SwitchListTile(
      title: Text('moveCover2RightSide'.tr),
      subtitle: Text('needRestart'.tr),
      value: styleSetting.moveCover2RightSide.value,
      onChanged: styleSetting.saveMoveCover2RightSide,
    );
  }

  Widget _buildLayout(BuildContext context) {
    return ListTile(
      title: Text('layoutMode'.tr),
      subtitle:
          Text(JHLayout.allLayouts.firstWhere((e) => e.mode == styleSetting.layout.value).desc),
      trailing: DropdownButton<LayoutMode>(
        value: styleSetting.actualLayout,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (LayoutMode? newValue) => styleSetting.saveLayoutMode(newValue!),
        items: JHLayout.allLayouts
            .map((e) => DropdownMenuItem(
                  enabled: e.isSupported(),
                  value: e.mode,
                  child: Text(e.name,
                      style: e.isSupported()
                          ? null
                          : TextStyle(
                              color: UIConfig.settingPageLayoutSelectorUnSupportColor(context))),
                ))
            .toList(),
      ),
    );
  }
}
