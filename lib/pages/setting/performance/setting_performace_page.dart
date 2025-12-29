import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/extension/widget_extension.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/setting/performance_setting.dart';
import 'package:jhentai/utils/text_input_formatter.dart';
import 'package:jhentai/utils/toast_util.dart';

class SettingPerformancePage extends StatelessWidget {
  SettingPerformancePage({super.key});

  final TextEditingController maxGalleryNum4AnimationController =
      TextEditingController(text: performanceSetting.maxGalleryNum4Animation.value.toString());
  final TextEditingController inactivateTimeoutSecondsController =
      TextEditingController(text: performanceSetting.inactivateTimeoutSeconds.value.toString());
  final TextEditingController inactivateShadeTextController =
      TextEditingController(text: performanceSetting.inactivateShadeText.value);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('performanceSetting'.tr)),
      body: ListView(
        padding: const EdgeInsets.only(top: 16),
        children: [
          _buildEnableInactivateShade(context),
          _buildInactivateShadeText(context),
          _buildInactivateTimeout(context),
          _buildDisableAllLoadingAnimations(context),
          _buildMaxGalleryNum4Animation(context),
        ],
      ).withListTileTheme(context),
    );
  }

  Widget _buildEnableInactivateShade(BuildContext context) {
    return Obx(
      () => SwitchListTile(
        title: Text('enableInactivateShade'.tr),
        subtitle: Text('enableInactivateShadeHint'.tr),
        value: performanceSetting.enableInactivateShade.value,
        onChanged: performanceSetting.setEnableInactivateShade,
      ).fadeInWidget(),
    );
  }

  Widget _buildInactivateTimeout(BuildContext context) {
    return ListTile(
      title: Text('inactivateTimeout'.tr),
      subtitle: Text('inactivateTimeoutHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 70,
            child: TextField(
              controller: inactivateTimeoutSecondsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  isDense: true, labelStyle: TextStyle(fontSize: 12), suffixText: 's'),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 1),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              int? value = int.tryParse(inactivateTimeoutSecondsController.value.text);
              if (value == null) {
                return;
              }
              performanceSetting.setInactivateTimeoutSeconds(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildInactivateShadeText(BuildContext context) {
    return ListTile(
      title: Text('inactivateShadeText'.tr),
      subtitle: Text('inactivateShadeTextHint'.tr),
      trailing: SizedBox(
        width: 200,
        child: TextField(
          controller: inactivateShadeTextController,
          decoration: const InputDecoration(isDense: true),
          textAlign: TextAlign.start,
          maxLength: 40,
          inputFormatters: [
            LengthLimitingTextInputFormatter(40),
          ],
          onSubmitted: (value) => _saveInactivateShadeText(value, context),
        ),
      ),
    );
  }

  void _saveInactivateShadeText(String value, BuildContext context) {
    final String trimmed = value.trim();
    final String fallback = performanceSetting.inactivateShadeText.value;
    final String next = trimmed.isNotEmpty ? trimmed : fallback;
    performanceSetting.setInactivateShadeText(next);
    inactivateShadeTextController.text = next;
    toast('saveSuccess'.tr);
  }

  Widget _buildDisableAllLoadingAnimations(BuildContext context) {
    return Obx(
      () => SwitchListTile(
        title: Text('disableLoadingAnimations'.tr),
        subtitle: Text('disableLoadingAnimationsHint'.tr),
        value: performanceSetting.disableAllLoadingAnimations.value,
        onChanged: performanceSetting.setDisableAllLoadingAnimations,
      ).fadeInWidget(),
    );
  }

  Widget _buildMaxGalleryNum4Animation(BuildContext context) {
    return ListTile(
      title: Text('maxGalleryNum4Animation'.tr),
      subtitle: Text('maxGalleryNum4AnimationHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: maxGalleryNum4AnimationController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, labelStyle: TextStyle(fontSize: 12)),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 0),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              int? value = int.tryParse(maxGalleryNum4AnimationController.value.text);
              if (value == null) {
                return;
              }
              performanceSetting.setMaxGalleryNum4Animation(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }
}
