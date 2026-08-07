import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/setting/read_setting.dart';

import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/text_input_formatter.dart';
import 'package:jhentai/utils/toast_util.dart';

class SettingReadPage extends StatelessWidget {
  static const List<int> _wakelockTimeLimitOptions = <int>[0, 5, 10, 15, 20, 30, 45, 60];

  final TextEditingController imageRegionWidthRatioController =
      TextEditingController(text: readSetting.imageRegionWidthRatio.value.toString());
  final TextEditingController gestureRegionWidthRatioController =
      TextEditingController(text: readSetting.gestureRegionWidthRatio.value.toString());
  final TextEditingController imageMaxKilobytesController =
      TextEditingController(text: readSetting.maxImageKilobyte.value.toString());

  SettingReadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('readSetting'.tr)),
      body: Obx(
        () => SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(top: 16),
            children: [
              if (GetPlatform.isMobile || GetPlatform.isWindows)
                _buildEnableImmersiveMode().center(),
              _buildKeepScreenAwake().center(),
              if (readSetting.keepScreenAwakeWhenReading.isTrue) _buildWakelockTimeLimit().center(),
              if (GetPlatform.isMobile) _buildEnableCustomReadBrightness().center(),
              if (GetPlatform.isMobile) _buildCustomReadBrightness().center(),
              _buildShowThumbnails().center(),
              _buildShowScrollBar().center(),
              _buildShowStatusInfo().center(),
              if (GetPlatform.isAndroid) _buildEnablePageTurnByVolumeKeys().center(),
              _buildEnablePageTurnAnime().center(),
              _buildEnableDoubleTapToScaleUp().center(),
              _buildEnableTapDragToScaleUp().center(),
              _buildEnableBottomMenu().center(),
              _buildReverseTurnPageDirection().center(),
              _buildDisableTurnPageOnTap().center(),
              _buildSmartScaling().center(),
              if (readSetting.smartScaling.isTrue)
                _buildSmartScalingThreshold()
                    .fadeInWidget(const Key('smartScalingThreshold'))
                    .center(),
              _buildEnableImageMaxKilobytes().center(),
              if (readSetting.enableMaxImageKilobyte.isTrue)
                _buildImageMaxKilobytes(context)
                    .fadeInWidget(const Key('imageMaxKilobytes'))
                    .center(),
              _buildGestureRegionWidthRatio(context).center(),
              if (GetPlatform.isDesktop) _buildUseThirdPartyViewer().center(),
              if (GetPlatform.isDesktop) _buildThirdPartyViewerPath().center(),
              if (GetPlatform.isMobile) _buildDeviceDirection().center(),
              _buildReadDirection().center(),
              if (GetPlatform.isMobile &&
                  readSetting.readDirection.value == ReadDirection.top2bottomList)
                _buildNotchOptimization().center(),
              if (readSetting.readDirection.value == ReadDirection.top2bottomList)
                _buildImageRegionWidthRatio(context).center(),
              if (readSetting.isInListReadDirection)
                _buildPreloadDistanceInOnlineMode(context)
                    .fadeInWidget(const Key('preloadDistanceInOnlineMode'))
                    .center(),
              if (readSetting.isInListReadDirection)
                _buildPreloadDistanceInLocalMode(context)
                    .fadeInWidget(const Key('preloadDistanceInLocalMode'))
                    .center(),
              if (!readSetting.isInListReadDirection)
                _buildPreloadPageCount().fadeInWidget(const Key('preloadPageCount')).center(),
              if (!readSetting.isInListReadDirection)
                _buildPreloadPageCountInLocalMode()
                    .fadeInWidget(const Key('preloadPageCountInLocalMode'))
                    .center(),
              if (readSetting.isInDoubleColumnReadDirection)
                _buildDisplayFirstPageAlone()
                    .fadeInWidget(const Key('displayFirstPageAloneGlobally'))
                    .center(),
              if (readSetting.isInListReadDirection)
                _buildAutoModeStyle().fadeInWidget(const Key('autoModeStyle')).center(),
              if (readSetting.isInListReadDirection)
                _buildTurnPageMode().fadeInWidget(const Key('turnPageMode')).center(),
              _buildImageSpace().center(),
            ],
          ).withListTileTheme(context),
        ),
      ),
    );
  }

  Widget _buildEnableImmersiveMode() {
    return SwitchListTile(
      title: Text('enableImmersiveMode'.tr),
      subtitle: GetPlatform.isMobile
          ? Text('enableImmersiveHint'.tr)
          : Text('enableImmersiveHint4Windows'.tr),
      value: readSetting.enableImmersiveMode.value,
      onChanged: readSetting.saveEnableImmersiveMode,
    );
  }

  Widget _buildKeepScreenAwake() {
    return SwitchListTile(
      title: Text('keepScreenAwakeWhenReading'.tr),
      value: readSetting.keepScreenAwakeWhenReading.value,
      onChanged: readSetting.saveKeepScreenAwakeWhenReading,
    );
  }

  Widget _buildWakelockTimeLimit() {
    final List<int> options = List<int>.from(_wakelockTimeLimitOptions);
    final int currentValue = readSetting.wakelockTimeLimitMinutes.value;
    if (!options.contains(currentValue)) {
      options.add(currentValue);
      options.sort();
    }

    return ListTile(
      title: Text('wakelockTimeLimitWhenReading'.tr),
      subtitle: Text('wakelockTimeLimitWhenReadingHint'.tr),
      trailing: DropdownButton<int>(
        value: currentValue,
        elevation: 4,
        onChanged: (int? newValue) {
          if (newValue == null) {
            return;
          }
          readSetting.saveWakelockTimeLimitMinutes(newValue);
        },
        items: options
            .map(
              (int value) => DropdownMenuItem<int>(
                value: value,
                child: Text(value == 0 ? 'never'.tr : '$value ${'minutes'.tr}'),
              ),
            )
            .toList(),
      ),
    ).marginOnly(right: 12);
  }

  Widget _buildEnableCustomReadBrightness() {
    return SwitchListTile(
      title: Text('enableCustomReadBrightness'.tr),
      value: readSetting.enableCustomReadBrightness.value,
      onChanged: readSetting.saveEnableCustomReadBrightness,
    );
  }

  Widget _buildShowThumbnails() {
    return SwitchListTile(
      title: Text('showThumbnails'.tr),
      value: readSetting.showThumbnails.value,
      onChanged: readSetting.saveShowThumbnails,
    );
  }

  Widget _buildShowScrollBar() {
    return SwitchListTile(
      title: Text('showScrollBar'.tr),
      value: readSetting.showScrollBar.value,
      onChanged: readSetting.saveShowScrollBar,
    );
  }

  Widget _buildCustomReadBrightness() {
    return Row(
      children: [
        const SizedBox(width: 16),
        const Icon(Icons.brightness_6),
        const SizedBox(width: 16),
        Text(readSetting.customBrightness.value.toString()),
        Expanded(
          child: Slider(
            value: readSetting.customBrightness.value.toDouble(),
            onChanged: (double value) => readSetting.saveCustomBrightness(value.toInt()),
            min: 0,
            max: 100,
          ),
        ),
        const SizedBox(width: 16),
      ],
    );
  }

  Widget _buildImageSpace() {
    return ListTile(
      title: Text('spaceBetweenImages'.tr),
      trailing: DropdownButton<int>(
        value: readSetting.imageSpace.value,
        elevation: 4,
        onChanged: (int? newValue) {
          readSetting.saveImageSpace(newValue!);
        },
        items: const [
          DropdownMenuItem(
            value: 0,
            child: Text('0'),
          ),
          DropdownMenuItem(
            value: 2,
            child: Text('2'),
          ),
          DropdownMenuItem(
            value: 4,
            child: Text('4'),
          ),
          DropdownMenuItem(
            value: 6,
            child: Text('6'),
          ),
          DropdownMenuItem(
            value: 7,
            child: Text('8'),
          ),
          DropdownMenuItem(
            value: 10,
            child: Text('10'),
          ),
        ],
      ),
    ).marginOnly(right: 12);
  }

  Widget _buildShowStatusInfo() {
    return SwitchListTile(
      title: Text('showStatusInfo'.tr),
      value: readSetting.showStatusInfo.value,
      onChanged: readSetting.saveShowStatusInfo,
    );
  }

  Widget _buildEnablePageTurnByVolumeKeys() {
    return SwitchListTile(
      title: Text('enablePageTurnByVolumeKeys'.tr),
      value: readSetting.enablePageTurnByVolumeKeys.value,
      onChanged: readSetting.saveEnablePageTurnByVolumeKeys,
    );
  }

  Widget _buildEnablePageTurnAnime() {
    return SwitchListTile(
      title: Text('enablePageTurnAnime'.tr),
      value: readSetting.enablePageTurnAnime.value,
      onChanged: readSetting.saveEnablePageTurnAnime,
    );
  }

  Widget _buildEnableDoubleTapToScaleUp() {
    return SwitchListTile(
      title: Text('enableDoubleTapToScaleUp'.tr),
      value: readSetting.enableDoubleTapToScaleUp.value,
      onChanged: readSetting.saveEnableDoubleTapToScaleUp,
    );
  }

  Widget _buildEnableTapDragToScaleUp() {
    return SwitchListTile(
      title: Text('enableTapDragToScaleUp'.tr),
      value: readSetting.enableTapDragToScaleUp.value,
      onChanged: readSetting.saveEnableTapDragToScaleUp,
    );
  }

  Widget _buildEnableBottomMenu() {
    return SwitchListTile(
      title: Text('enableBottomMenu'.tr),
      value: readSetting.enableBottomMenu.value,
      onChanged: readSetting.saveEnableBottomMenu,
    );
  }

  Widget _buildReverseTurnPageDirection() {
    return SwitchListTile(
      title: Text('reverseTurnPageDirection'.tr),
      value: readSetting.reverseTurnPageDirection.value,
      onChanged: readSetting.saveReverseTurnPageDirection,
    );
  }

  Widget _buildDisableTurnPageOnTap() {
    return SwitchListTile(
      title: Text('disablePageTurningOnTap'.tr),
      value: readSetting.disablePageTurningOnTap.value,
      onChanged: readSetting.saveDisablePageTurningOnTap,
    );
  }

  Widget _buildSmartScaling() {
    return SwitchListTile(
      title: Text('smartScaling'.tr),
      subtitle: Text('smartScalingHint'.tr),
      value: readSetting.smartScaling.value,
      onChanged: readSetting.saveSmartScaling,
    );
  }

  Widget _buildSmartScalingThreshold() {
    return Column(
      children: [
        ListTile(
          title: Text('smartScalingThreshold'.tr),
          subtitle: Text('smartScalingThresholdHint'.tr),
          trailing: Text('${readSetting.smartScalingThreshold.value}%'),
        ),
        Slider(
          value: readSetting.smartScalingThreshold.value.toDouble(),
          min: 0,
          max: 100,
          divisions: 100,
          label: '${readSetting.smartScalingThreshold.value}%',
          onChanged: (double value) => readSetting.saveSmartScalingThreshold(value.round()),
        ).marginSymmetric(horizontal: 12),
      ],
    );
  }

  Widget _buildEnableImageMaxKilobytes() {
    return SwitchListTile(
      title: Text('enableImageMaxKilobytes'.tr),
      value: readSetting.enableMaxImageKilobyte.value,
      onChanged: readSetting.saveEnableMaxImageKilobyte,
    );
  }

  Widget _buildImageMaxKilobytes(BuildContext context) {
    return ListTile(
      title: Text('imageMaxKilobytes'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: imageMaxKilobytesController,
              decoration: const InputDecoration(isDense: true, labelStyle: TextStyle(fontSize: 12)),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 1)
              ],
            ),
          ),
          Text('KB', style: UIConfig.settingPageListTileTrailingTextStyle(context)),
          IconButton(
            onPressed: () {
              int? value = int.tryParse(imageMaxKilobytesController.value.text);
              if (value == null) {
                return;
              }
              readSetting.saveMaxImageKilobyte(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceDirection() {
    return ListTile(
      title: Text('deviceOrientation'.tr),
      trailing: DropdownButton<DeviceDirection>(
        value: readSetting.deviceDirection.value,
        elevation: 4,
        onChanged: (DeviceDirection? newValue) => readSetting.saveDeviceDirection(newValue!),
        items: [
          DropdownMenuItem(value: DeviceDirection.followSystem, child: Text('followSystem'.tr)),
          DropdownMenuItem(value: DeviceDirection.landscape, child: Text('landscape'.tr)),
          DropdownMenuItem(value: DeviceDirection.portrait, child: Text('portrait'.tr)),
        ],
      ).marginOnly(right: 12),
    );
  }

  Widget _buildReadDirection() {
    return ListTile(
      title: Text('readDirection'.tr),
      trailing: DropdownButton<ReadDirection>(
        value: readSetting.readDirection.value,
        elevation: 4,
        onChanged: (ReadDirection? newValue) => readSetting.saveReadDirection(newValue!),
        items: ReadDirection.values
            .map((e) => DropdownMenuItem(value: e, child: Text(e.name.tr)))
            .toList(),
      ).marginOnly(right: 12),
    );
  }

  Widget _buildNotchOptimization() {
    return ListTile(
      title: Text('notchOptimization'.tr),
      subtitle: Text('notchOptimizationHint'.tr),
      trailing: Switch(
          value: readSetting.notchOptimization.value, onChanged: readSetting.saveNotchOptimization),
    );
  }

  Widget _buildImageRegionWidthRatio(BuildContext context) {
    return ListTile(
      title: Text('imageRegionWidthRatio'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: imageRegionWidthRatioController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, labelStyle: TextStyle(fontSize: 12)),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 1, maxValue: 100),
              ],
              onSubmitted: (_) {
                _saveImageRegionWidthRatio();
              },
            ),
          ),
          const Text('%'),
          IconButton(
            onPressed: _saveImageRegionWidthRatio,
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    ).marginOnly(right: 12);
  }

  void _saveImageRegionWidthRatio() {
    int? value = int.tryParse(imageRegionWidthRatioController.value.text);
    if (value == null) {
      return;
    }
    readSetting.saveImageRegionWidthRatio(value);
    toast('saveSuccess'.tr);
  }

  Widget _buildGestureRegionWidthRatio(BuildContext context) {
    return ListTile(
      title: Text('gestureRegionWidthRatio'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: gestureRegionWidthRatioController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, labelStyle: TextStyle(fontSize: 12)),
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                IntRangeTextInputFormatter(minValue: 0, maxValue: 100),
              ],
              onSubmitted: (_) {
                _saveGestureRegionWidthRatio();
              },
            ),
          ),
          const Text('%'),
          IconButton(
            onPressed: _saveGestureRegionWidthRatio,
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    ).marginOnly(right: 12);
  }

  void _saveGestureRegionWidthRatio() {
    int? value = int.tryParse(gestureRegionWidthRatioController.value.text);
    if (value == null) {
      return;
    }

    if (value <= 0) {
      value = 1;
    }
    if (value >= 100) {
      value = 99;
    }

    readSetting.saveGestureRegionWidthRatio(value);
    toast('saveSuccess'.tr);
  }

  Widget _buildUseThirdPartyViewer() {
    return SwitchListTile(
      title: Text('useThirdPartyViewer'.tr),
      value: readSetting.useThirdPartyViewer.value,
      onChanged: readSetting.saveUseThirdPartyViewer,
    );
  }

  Widget _buildThirdPartyViewerPath() {
    return ListTile(
      title: Text('thirdPartyViewerPath'.tr),
      subtitle: Text(readSetting.thirdPartyViewerPath.value ?? ''),
      trailing: const Icon(Icons.keyboard_arrow_right),
      onTap: () async {
        FilePickerResult? result;
        try {
          result = await FilePicker.platform.pickFiles();
        } on Exception catch (e) {
          log.error('Pick 3-rd party viewer failed', e);
          log.uploadError(e);
        }

        if (result == null || result.files.single.path == null) {
          return;
        }

        readSetting.saveThirdPartyViewerPath(result.files.single.path!);
      },
    );
  }

  Widget _buildPreloadDistanceInOnlineMode(BuildContext context) {
    return ListTile(
      title: Text('preloadDistanceInOnlineMode'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<int>(
            value: readSetting.preloadDistance.value,
            elevation: 4,
            onChanged: (int? newValue) {
              readSetting.savePreloadDistance(newValue!);
            },
            items: const [
              DropdownMenuItem(value: 0, child: Text('0')),
              DropdownMenuItem(value: 1, child: Text('1')),
              DropdownMenuItem(value: 2, child: Text('2')),
              DropdownMenuItem(value: 3, child: Text('3')),
              DropdownMenuItem(value: 5, child: Text('5')),
              DropdownMenuItem(value: 8, child: Text('8')),
              DropdownMenuItem(value: 10, child: Text('10')),
            ],
          ),
          Text('ScreenHeight'.tr, style: UIConfig.settingPageListTileTrailingTextStyle(context))
              .marginSymmetric(horizontal: 12),
        ],
      ),
    );
  }

  Widget _buildPreloadDistanceInLocalMode(BuildContext context) {
    return ListTile(
      title: Text('preloadDistanceInLocalMode'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<int>(
            value: readSetting.preloadDistanceLocal.value,
            elevation: 4,
            onChanged: (int? newValue) {
              readSetting.savePreloadDistanceLocal(newValue!);
            },
            items: const [
              DropdownMenuItem(value: 0, child: Text('0')),
              DropdownMenuItem(value: 1, child: Text('1')),
              DropdownMenuItem(value: 2, child: Text('2')),
              DropdownMenuItem(value: 3, child: Text('3')),
              DropdownMenuItem(value: 5, child: Text('5')),
              DropdownMenuItem(value: 8, child: Text('8')),
              DropdownMenuItem(value: 10, child: Text('10')),
            ],
          ),
          Text('ScreenHeight'.tr, style: UIConfig.settingPageListTileTrailingTextStyle(context))
              .marginSymmetric(horizontal: 12),
        ],
      ),
    );
  }

  Widget _buildPreloadPageCount() {
    return ListTile(
      title: Text('preloadPageCount'.tr),
      trailing: DropdownButton<int>(
        value: readSetting.preloadPageCount.value,
        elevation: 4,
        onChanged: (int? newValue) {
          readSetting.savePreloadPageCount(newValue!);
        },
        items: const [
          DropdownMenuItem(value: 0, child: Text('0')),
          DropdownMenuItem(value: 1, child: Text('1')),
          DropdownMenuItem(value: 2, child: Text('2')),
          DropdownMenuItem(value: 3, child: Text('3')),
          DropdownMenuItem(value: 5, child: Text('5')),
          DropdownMenuItem(value: 8, child: Text('8')),
          DropdownMenuItem(value: 10, child: Text('10')),
        ],
      ).marginOnly(right: 12),
    );
  }

  Widget _buildPreloadPageCountInLocalMode() {
    return ListTile(
      title: Text('preloadPageCountInLocalMode'.tr),
      trailing: DropdownButton<int>(
        value: readSetting.preloadPageCountLocal.value,
        elevation: 4,
        onChanged: (int? newValue) {
          readSetting.savePreloadPageCountLocal(newValue!);
        },
        items: const [
          DropdownMenuItem(value: 0, child: Text('0')),
          DropdownMenuItem(value: 1, child: Text('1')),
          DropdownMenuItem(value: 2, child: Text('2')),
          DropdownMenuItem(value: 3, child: Text('3')),
          DropdownMenuItem(value: 5, child: Text('5')),
          DropdownMenuItem(value: 8, child: Text('8')),
          DropdownMenuItem(value: 10, child: Text('10')),
        ],
      ).marginOnly(right: 12),
    );
  }

  Widget _buildDisplayFirstPageAlone() {
    return SwitchListTile(
      title: Text('displayFirstPageAloneGlobally'.tr),
      value: readSetting.displayFirstPageAlone.value,
      onChanged: readSetting.saveDisplayFirstPageAlone,
    );
  }

  Widget _buildAutoModeStyle() {
    return ListTile(
      title: Text('autoModeStyle'.tr),
      trailing: DropdownButton<AutoModeStyle>(
        value: readSetting.autoModeStyle.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (AutoModeStyle? newValue) => readSetting.saveAutoModeStyle(newValue!),
        items: [
          DropdownMenuItem(value: AutoModeStyle.scroll, child: Text('scroll'.tr)),
          DropdownMenuItem(value: AutoModeStyle.turnPage, child: Text('turnPage'.tr)),
        ],
      ).marginOnly(right: 12),
    );
  }

  Widget _buildTurnPageMode() {
    return ListTile(
      title: Text('turnPageMode'.tr),
      subtitle: Text('turnPageModeHint'.tr),
      trailing: DropdownButton<TurnPageMode>(
        value: readSetting.turnPageMode.value,
        elevation: 4,
        onChanged: (TurnPageMode? newValue) => readSetting.saveTurnPageMode(newValue!),
        items: [
          DropdownMenuItem(value: TurnPageMode.image, child: Text('image'.tr)),
          DropdownMenuItem(value: TurnPageMode.screen, child: Text('screen'.tr)),
          DropdownMenuItem(value: TurnPageMode.adaptive, child: Text('adaptive'.tr)),
        ],
      ).marginOnly(right: 12),
    );
  }
}
