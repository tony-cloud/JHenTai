import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../routes/routes.dart';
import '../../../../setting/style_setting.dart';

class SettingPageListStylePage extends StatelessWidget {
  SettingPageListStylePage({super.key});

  final List<PageListStyleItem> items = [
    PageListStyleItem(name: 'home'.tr, route: Routes.gallerys, show: () => styleSetting.isInDesktopLayout),
    PageListStyleItem(name: 'home'.tr, route: Routes.dashboard, show: () => styleSetting.isInMobileLayout || styleSetting.isInTabletLayout),
    PageListStyleItem(name: 'search'.tr, route: Routes.desktopSearch, show: () => styleSetting.isInDesktopLayout),
    PageListStyleItem(name: 'search'.tr, route: Routes.mobileV2Search, show: () => styleSetting.isInMobileLayout || styleSetting.isInTabletLayout),
    PageListStyleItem(name: 'popular'.tr, route: Routes.popular, show: () => true),
    PageListStyleItem(name: 'ranklist'.tr, route: Routes.ranklist, show: () => true),
    PageListStyleItem(name: 'favorite'.tr, route: Routes.favorite, show: () => true),
    PageListStyleItem(name: 'watched'.tr, route: Routes.watched, show: () => true),
    PageListStyleItem(name: 'history'.tr, route: Routes.history, show: () => true),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('pageListStyle'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: items
              .where((item) => item.show())
              .map(
                (item) => ListTile(
                  title: Text(item.name),
                  trailing: DropdownButton<ListMode?>(
                    value: styleSetting.pageListMode[item.route],
                    elevation: 4,
                    alignment: AlignmentDirectional.centerEnd,
                    onChanged: (value) => styleSetting.savePageListMode(item.route, value),
                    items: [
                      DropdownMenuItem(value: null, child: Text('global'.tr)),
                      DropdownMenuItem(value: ListMode.flat, child: Text('flat'.tr)),
                      DropdownMenuItem(value: ListMode.flatWithoutTags, child: Text('flatWithoutTags'.tr)),
                      DropdownMenuItem(value: ListMode.listWithTags, child: Text('listWithTags'.tr)),
                      DropdownMenuItem(value: ListMode.listWithoutTags, child: Text('listWithoutTags'.tr)),
                      DropdownMenuItem(value: ListMode.waterfallFlowSmall, child: Text('waterfallFlowSmall'.tr)),
                      DropdownMenuItem(value: ListMode.waterfallFlowMedium, child: Text('waterfallFlowMedium'.tr)),
                      DropdownMenuItem(value: ListMode.waterfallFlowBig, child: Text('waterfallFlowBig'.tr)),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class PageListStyleItem {
  final String name;
  final String route;
  final ValueGetter<bool> show;

  const PageListStyleItem({required this.name, required this.route, required this.show});
}
