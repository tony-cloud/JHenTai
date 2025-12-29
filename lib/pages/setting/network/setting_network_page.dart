import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/setting/network_setting.dart';

import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/text_input_formatter.dart';
import 'package:jhentai/utils/toast_util.dart';

class SettingNetworkPage extends StatelessWidget {
  final TextEditingController proxyAddressController =
      TextEditingController(text: networkSetting.proxyAddress.value);
  final TextEditingController connectTimeoutController =
      TextEditingController(text: networkSetting.connectTimeout.value.toString());
  final TextEditingController receiveTimeoutController =
      TextEditingController(text: networkSetting.receiveTimeout.value.toString());

  SettingNetworkPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('networkSetting'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildEnableDomainFronting(),
            _buildProxyAddress(),
            _buildPageCacheMaxAge(),
            _buildCacheImageExpireDuration(),
            _buildConnectTimeout(context),
            _buildReceiveTimeout(context),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildEnableDomainFronting() {
    return SwitchListTile(
      title: Text('enableDomainFronting'.tr),
      subtitle: Text('bypassSNIBlocking'.tr),
      value: networkSetting.enableDomainFronting.value,
      onChanged: networkSetting.saveEnableDomainFronting,
    );
  }

  Widget _buildProxyAddress() {
    return ListTile(
      title: Text('proxyAddress'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => toRoute(Routes.proxy),
    );
  }

  Widget _buildPageCacheMaxAge() {
    return ListTile(
      title: Text('pageCacheMaxAge'.tr),
      subtitle: Text('pageCacheMaxAgeHint'.tr),
      trailing: DropdownButton<Duration>(
        value: networkSetting.pageCacheMaxAge.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (Duration? newValue) => networkSetting.savePageCacheMaxAge(newValue!),
        items: [
          DropdownMenuItem(value: const Duration(minutes: 1), child: Text('1m'.tr)),
          DropdownMenuItem(value: const Duration(minutes: 10), child: Text('10m'.tr)),
          DropdownMenuItem(value: const Duration(hours: 1), child: Text('1h'.tr)),
          DropdownMenuItem(value: const Duration(days: 1), child: Text('1d'.tr)),
          DropdownMenuItem(value: const Duration(days: 3), child: Text('3d'.tr)),
        ],
      ),
    );
  }

  Widget _buildCacheImageExpireDuration() {
    return ListTile(
      title: Text('cacheImageExpireDuration'.tr),
      subtitle: Text('cacheImageExpireDurationHint'.tr),
      trailing: DropdownButton<Duration>(
        value: networkSetting.cacheImageExpireDuration.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (Duration? newValue) => networkSetting.saveCacheImageExpireDuration(newValue!),
        items: [
          DropdownMenuItem(value: const Duration(days: 1), child: Text('1d'.tr)),
          DropdownMenuItem(value: const Duration(days: 2), child: Text('2d'.tr)),
          DropdownMenuItem(value: const Duration(days: 3), child: Text('3d'.tr)),
          DropdownMenuItem(value: const Duration(days: 5), child: Text('5d'.tr)),
          DropdownMenuItem(value: const Duration(days: 7), child: Text('7d'.tr)),
          DropdownMenuItem(value: const Duration(days: 14), child: Text('14d'.tr)),
          DropdownMenuItem(value: const Duration(days: 30), child: Text('30d'.tr)),
        ],
      ),
    );
  }

  Widget _buildConnectTimeout(BuildContext context) {
    return ListTile(
      title: Text('connectTimeout'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: connectTimeoutController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, labelStyle: TextStyle(fontSize: 12)),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 0),
              ],
            ),
          ),
          Text('ms', style: UIConfig.settingPageListTileTrailingTextStyle(context)),
          IconButton(
            onPressed: () {
              int? value = int.tryParse(connectTimeoutController.value.text);
              if (value == null) {
                return;
              }
              networkSetting.saveConnectTimeout(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiveTimeout(BuildContext context) {
    return ListTile(
      title: Text('receiveTimeout'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: receiveTimeoutController,
              decoration: const InputDecoration(isDense: true, labelStyle: TextStyle(fontSize: 12)),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 0),
              ],
            ),
          ),
          Text('ms', style: UIConfig.settingPageListTileTrailingTextStyle(context)),
          IconButton(
            onPressed: () {
              int? value = int.tryParse(receiveTimeoutController.value.text);
              if (value == null) {
                return;
              }
              networkSetting.saveReceiveTimeout(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }
}
