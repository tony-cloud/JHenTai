import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/setting/rpc_setting.dart';

import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/rpc_service.dart';
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
  final TextEditingController timeoutRetryTimesController =
      TextEditingController(text: networkSetting.timeoutRetryTimes.value.toString());
  final TextEditingController serverErrorRetryTimesController =
      TextEditingController(text: networkSetting.serverErrorRetryTimes.value.toString());
  final TextEditingController dnsOverHttpsController =
      TextEditingController(text: networkSetting.dnsOverHttpsEndpoint.value);
  final TextEditingController rpcServerAddressController =
      TextEditingController(text: rpcSetting.serverAddress.value);
  final TextEditingController rpcAccessTokenController =
      TextEditingController(text: rpcSetting.accessToken.value);

  SettingNetworkPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('networkSetting'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildEnableRpcMode(),
            _buildRpcServerProfile(),
            _buildRpcServerAddress(context),
            _buildRpcAccessToken(context),
            _buildAllowSelfSignedCertificate(),
            _buildRpcBackendStatus(context),
            _buildRpcCapabilities(),
            if (!GetPlatform.isWeb) _buildEnableDnsOverHttps(),
            if (!GetPlatform.isWeb) _buildDnsOverHttpsEndpoint(context),
            if (!GetPlatform.isWeb) _buildEnableDomainFronting(),
            if (!GetPlatform.isWeb) _buildProxyAddress(),
            if (!GetPlatform.isWeb) _buildPageCacheMaxAge(),
            if (!GetPlatform.isWeb) _buildCacheImageExpireDuration(),
            if (!GetPlatform.isWeb) _buildConnectTimeout(context),
            if (!GetPlatform.isWeb) _buildReceiveTimeout(context),
            if (!GetPlatform.isWeb) _buildTimeoutRetryTimes(context),
            if (!GetPlatform.isWeb) _buildServerErrorRetryTimes(context),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildEnableRpcMode() {
    final bool isWebRpcOnly = GetPlatform.isWeb;

    return SwitchListTile(
      title: Text('enableRpcMode'.tr),
      subtitle: Text('enableRpcModeHint'.tr),
      value: rpcSetting.enableRpcMode.value,
      onChanged: isWebRpcOnly
          ? null
          : (bool value) async {
              await rpcSetting.saveEnableRpcMode(value);
              if (!value) {
                rpcService.isBackendReachable.value = false;
                return;
              }

              await rpcService.checkHealth();
            },
    );
  }

  Widget _buildRpcServerProfile() {
    return ListTile(
      title: Text('rpcServerProfile'.tr),
      subtitle: Text('rpcServerProfileHint'.tr),
      trailing: DropdownButton<RPCServerProfile>(
        value: rpcSetting.serverProfile.value,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: rpcSetting.enableRpcMode.isFalse
            ? null
            : (RPCServerProfile? newValue) async {
                if (newValue == null) {
                  return;
                }

                await rpcSetting.saveServerProfile(newValue);
                if (newValue != RPCServerProfile.custom) {
                  rpcServerAddressController.text = rpcSetting.serverAddress.value;
                }
                toast('saveSuccess'.tr);
              },
        items: RPCServerProfile.values
            .map(
              (profile) => DropdownMenuItem(
                value: profile,
                child: Text(_rpcServerProfileText(profile)),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildRpcServerAddress(BuildContext context) {
    return ListTile(
      title: Text('rpcServerAddress'.tr),
      subtitle: Text('rpcServerAddressHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 210,
            child: TextField(
              controller: rpcServerAddressController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              enabled: rpcSetting.enableRpcMode.value,
              onSubmitted: (_) => _saveRpcServerAddress(),
            ),
          ),
          IconButton(
            onPressed: rpcSetting.enableRpcMode.isFalse
                ? null
                : () {
                    _saveRpcServerAddress();
                    toast('saveSuccess'.tr);
                  },
            icon: Icon(
              Icons.check,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRpcAccessToken(BuildContext context) {
    return ListTile(
      title: Text('rpcAccessToken'.tr),
      subtitle: Text('rpcAccessTokenHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 160,
            child: TextField(
              controller: rpcAccessTokenController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              obscureText: true,
              enabled: rpcSetting.enableRpcMode.value,
              onSubmitted: (_) => _saveRpcAccessToken(),
            ),
          ),
          IconButton(
            onPressed: rpcSetting.enableRpcMode.isFalse
                ? null
                : () {
                    _saveRpcAccessToken();
                    toast('saveSuccess'.tr);
                  },
            icon: Icon(
              Icons.check,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllowSelfSignedCertificate() {
    return SwitchListTile(
      title: Text('allowSelfSignedCertificate'.tr),
      subtitle: Text('allowSelfSignedCertificateHint'.tr),
      value: rpcSetting.allowSelfSignedCertificate.value,
      onChanged:
          rpcSetting.enableRpcMode.isFalse ? null : rpcSetting.saveAllowSelfSignedCertificate,
    );
  }

  Widget _buildRpcBackendStatus(BuildContext context) {
    return ListTile(
      title: Text('rpcBackendStatus'.tr),
      subtitle: Text(
        rpcSetting.enableRpcMode.isFalse
            ? 'rpcBackendDisabled'.tr
            : rpcService.isBackendReachable.value
                ? 'rpcBackendReachable'.tr
                : 'rpcBackendUnreachable'.tr,
      ),
      isThreeLine: true,
      dense: true,
      trailing: IconButton(
        onPressed: rpcSetting.enableRpcMode.isFalse
            ? null
            : () async {
                final bool success = await rpcService.checkHealth();
                toast(success ? 'rpcHealthCheckSuccess'.tr : 'rpcHealthCheckFailed'.tr);
              },
        icon: Icon(
          Icons.refresh,
          color: UIConfig.resumePauseButtonColor(context),
        ),
      ),
    );
  }

  Widget _buildRpcCapabilities() {
    final bool enabled = rpcSetting.enableRpcMode.isTrue;
    final bool reachable = rpcService.isBackendReachable.value;
    final String capabilityText;

    if (!enabled) {
      capabilityText = 'rpcBackendDisabled'.tr;
    } else if (!reachable) {
      capabilityText = 'rpcBackendUnreachable'.tr;
    } else if (rpcService.capabilities.isEmpty) {
      capabilityText = 'rpcCapabilitiesEmpty'.tr;
    } else {
      capabilityText = rpcService.capabilities.join(', ');
    }

    final String name = rpcService.backendName.value ?? '-';
    final String version = rpcService.backendVersion.value ?? '-';

    return ListTile(
      title: Text('rpcCapabilities'.tr),
      subtitle: Text(
        'rpcCapabilitiesHint'.trArgs([name, version, capabilityText]),
      ),
      isThreeLine: true,
      dense: true,
    );
  }

  void _saveRpcServerAddress() {
    rpcSetting.saveServerAddress(rpcServerAddressController.text.trim());
    rpcServerAddressController.text = rpcSetting.serverAddress.value;
  }

  void _saveRpcAccessToken() {
    final String token = rpcAccessTokenController.text.trim();
    rpcSetting.saveAccessToken(token.isEmpty ? null : token);
  }

  String _rpcServerProfileText(RPCServerProfile profile) {
    return switch (profile) {
      RPCServerProfile.local => 'rpcProfileLocal'.tr,
      RPCServerProfile.lan => 'rpcProfileLan'.tr,
      RPCServerProfile.cloud => 'rpcProfileCloud'.tr,
      RPCServerProfile.custom => 'rpcProfileCustom'.tr,
    };
  }

  Widget _buildEnableDomainFronting() {
    return SwitchListTile(
      title: Text('enableDomainFronting'.tr),
      subtitle: Text('bypassSNIBlocking'.tr),
      value: networkSetting.enableDomainFronting.value,
      onChanged: networkSetting.saveEnableDomainFronting,
    );
  }

  Widget _buildEnableDnsOverHttps() {
    return SwitchListTile(
      title: Text('enableDnsOverHttps'.tr),
      subtitle: Text('enableDnsOverHttpsHint'.tr),
      value: networkSetting.enableDnsOverHttps.value,
      onChanged: networkSetting.saveEnableDnsOverHttps,
    );
  }

  Widget _buildDnsOverHttpsEndpoint(BuildContext context) {
    return ListTile(
      title: Text('dnsOverHttpsEndpoint'.tr),
      subtitle: Text('dnsOverHttpsEndpointHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 210,
            child: TextField(
              controller: dnsOverHttpsController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              enabled: networkSetting.enableDnsOverHttps.value,
              onSubmitted: (_) => _saveDnsOverHttps(),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'dnsOverHttpsPreset'.tr,
            onSelected: (value) {
              dnsOverHttpsController.text = value;
              _saveDnsOverHttps();
            },
            itemBuilder: (_) => NetworkSetting.defaultDohEndpoints
                .map((e) => PopupMenuItem(value: e, child: Text(e)))
                .toList(),
          ),
          IconButton(
            onPressed: networkSetting.enableDnsOverHttps.isFalse
                ? null
                : () {
                    _saveDnsOverHttps();
                    toast('saveSuccess'.tr);
                  },
            icon: Icon(
              Icons.check,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
        ],
      ),
    );
  }

  void _saveDnsOverHttps() {
    networkSetting.saveDnsOverHttpsEndpoint(dnsOverHttpsController.text.trim());
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

  Widget _buildTimeoutRetryTimes(BuildContext context) {
    return ListTile(
      title: Text('timeoutRetryTimes'.tr),
      subtitle: Text('timeoutRetryTimesHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: timeoutRetryTimesController,
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
              int? value = int.tryParse(timeoutRetryTimesController.value.text);
              if (value == null) {
                return;
              }
              networkSetting.saveTimeoutRetryTimes(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildServerErrorRetryTimes(BuildContext context) {
    return ListTile(
      title: Text('serverErrorRetryTimes'.tr),
      subtitle: Text('serverErrorRetryTimesHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 50,
            child: TextField(
              controller: serverErrorRetryTimesController,
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
              int? value = int.tryParse(serverErrorRetryTimesController.value.text);
              if (value == null) {
                return;
              }
              networkSetting.saveServerErrorRetryTimes(value);
              toast('saveSuccess'.tr);
            },
            icon: Icon(Icons.check, color: UIConfig.resumePauseButtonColor(context)),
          ),
        ],
      ),
    );
  }
}
