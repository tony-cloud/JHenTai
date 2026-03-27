import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/service/rpc_bridge_server_service.dart';
import 'package:jhentai/service/rpc_service.dart';
import 'package:jhentai/setting/rpc_setting.dart';
import 'package:jhentai/utils/text_input_formatter.dart';
import 'package:jhentai/utils/toast_util.dart';

class SettingRPCServerPage extends StatefulWidget {
  const SettingRPCServerPage({super.key});

  @override
  State<SettingRPCServerPage> createState() => _SettingRPCServerPageState();
}

class _SettingRPCServerPageState extends State<SettingRPCServerPage> {
  late final TextEditingController rpcServerAddressController;
  late final TextEditingController rpcAccessTokenController;
  late final TextEditingController embeddedHostController;
  late final TextEditingController embeddedPortController;
  late final TextEditingController embeddedTokenController;
  bool showRpcAccessToken = false;
  bool showEmbeddedToken = false;

  @override
  void initState() {
    super.initState();

    rpcServerAddressController = TextEditingController(text: rpcSetting.serverAddress.value);
    rpcAccessTokenController = TextEditingController(text: rpcSetting.accessToken.value);
    embeddedHostController = TextEditingController(text: rpcSetting.embeddedHost.value);
    embeddedPortController = TextEditingController(text: rpcSetting.embeddedPort.value.toString());
    embeddedTokenController = TextEditingController(text: rpcSetting.embeddedToken.value);
  }

  @override
  void dispose() {
    rpcServerAddressController.dispose();
    rpcAccessTokenController.dispose();
    embeddedHostController.dispose();
    embeddedPortController.dispose();
    embeddedTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('rpcSettings'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: <Widget>[
            _buildEnableRpcMode(),
            _buildRpcServerProfile(),
            _buildRpcServerAddress(context),
            _buildRpcAccessToken(context),
            _buildAllowSelfSignedCertificate(),
            _buildRpcBackendStatus(context),
            _buildRpcCapabilities(),
            if (!kIsWeb) _buildEmbeddedServerDivider(),
            if (!kIsWeb) _buildEnableEmbeddedServer(),
            if (!kIsWeb) _buildEmbeddedServerAuthRequired(),
            if (!kIsWeb) _buildEmbeddedServerHost(context),
            if (!kIsWeb) _buildEmbeddedServerPort(context),
            if (!kIsWeb) _buildEmbeddedServerToken(context),
            if (!kIsWeb) _buildEmbeddedServerStatus(),
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
              (RPCServerProfile profile) => DropdownMenuItem<RPCServerProfile>(
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
        children: <Widget>[
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
        children: <Widget>[
          SizedBox(
            width: 160,
            child: TextField(
              controller: rpcAccessTokenController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              obscureText: !showRpcAccessToken,
              enabled: rpcSetting.enableRpcMode.value,
              onSubmitted: (_) => _saveRpcAccessToken(),
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() => showRpcAccessToken = !showRpcAccessToken);
            },
            icon: Icon(
              showRpcAccessToken ? Icons.visibility_off : Icons.visibility,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
          IconButton(
            onPressed: () => _copyToken(rpcAccessTokenController.text),
            icon: Icon(
              Icons.copy,
              color: UIConfig.resumePauseButtonColor(context),
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
        'rpcCapabilitiesHint'.trArgs(<String>[name, version, capabilityText]),
      ),
      isThreeLine: true,
      dense: true,
    );
  }

  Widget _buildEmbeddedServerDivider() {
    return ListTile(
      title: Text('embeddedRpcServer'.tr),
      subtitle: Text('embeddedRpcServerHint'.tr),
    );
  }

  Widget _buildEnableEmbeddedServer() {
    return SwitchListTile(
      title: Text('enableEmbeddedRpcServer'.tr),
      subtitle: Text('enableEmbeddedRpcServerHint'.tr),
      value: rpcSetting.enableEmbeddedServer.value,
      onChanged: (bool value) async {
        await rpcSetting.saveEnableEmbeddedServer(value);
        embeddedTokenController.text = rpcSetting.embeddedToken.value;
        rpcServerAddressController.text = rpcSetting.serverAddress.value;
        rpcAccessTokenController.text = rpcSetting.accessToken.value ?? '';
      },
    );
  }

  Widget _buildEmbeddedServerAuthRequired() {
    return SwitchListTile(
      title: Text('embeddedRpcServerAuthRequired'.tr),
      subtitle: Text('embeddedRpcServerAuthRequiredHint'.tr),
      value: rpcSetting.embeddedAuthRequired.value,
      onChanged: rpcSetting.enableEmbeddedServer.isFalse
          ? null
          : (bool value) async {
              await rpcSetting.saveEmbeddedAuthRequired(value);
              embeddedTokenController.text = rpcSetting.embeddedToken.value;
              rpcAccessTokenController.text = rpcSetting.accessToken.value ?? '';
              toast('saveSuccess'.tr);
            },
    );
  }

  Widget _buildEmbeddedServerHost(BuildContext context) {
    return ListTile(
      title: Text('embeddedRpcServerHost'.tr),
      subtitle: Text('embeddedRpcServerHostHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: TextField(
              controller: embeddedHostController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              enabled: rpcSetting.enableEmbeddedServer.value,
              onSubmitted: (_) => _saveEmbeddedHost(),
            ),
          ),
          IconButton(
            onPressed: rpcSetting.enableEmbeddedServer.isFalse
                ? null
                : () async {
                    await _saveEmbeddedHost();
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

  Widget _buildEmbeddedServerPort(BuildContext context) {
    return ListTile(
      title: Text('embeddedRpcServerPort'.tr),
      subtitle: Text('embeddedRpcServerPortHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: TextField(
              controller: embeddedPortController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              enabled: rpcSetting.enableEmbeddedServer.value,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                IntRangeTextInputFormatter(minValue: 1, maxValue: 65535),
              ],
              onSubmitted: (_) => _saveEmbeddedPort(),
            ),
          ),
          IconButton(
            onPressed: rpcSetting.enableEmbeddedServer.isFalse
                ? null
                : () async {
                    await _saveEmbeddedPort();
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

  Widget _buildEmbeddedServerToken(BuildContext context) {
    return ListTile(
      title: Text('embeddedRpcServerToken'.tr),
      subtitle: Text('embeddedRpcServerTokenHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 160,
            child: TextField(
              controller: embeddedTokenController,
              decoration: const InputDecoration(
                isDense: true,
                labelStyle: TextStyle(fontSize: 12),
              ),
              obscureText: !showEmbeddedToken,
              enabled:
                  rpcSetting.enableEmbeddedServer.value && rpcSetting.embeddedAuthRequired.value,
              onSubmitted: (_) => _saveEmbeddedToken(),
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() => showEmbeddedToken = !showEmbeddedToken);
            },
            icon: Icon(
              showEmbeddedToken ? Icons.visibility_off : Icons.visibility,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
          IconButton(
            onPressed: () => _copyToken(embeddedTokenController.text),
            icon: Icon(
              Icons.copy,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
          IconButton(
            onPressed:
                rpcSetting.enableEmbeddedServer.isFalse || rpcSetting.embeddedAuthRequired.isFalse
                    ? null
                    : () async {
                        await _saveEmbeddedToken();
                        toast('saveSuccess'.tr);
                      },
            icon: Icon(
              Icons.check,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
          IconButton(
            onPressed:
                rpcSetting.enableEmbeddedServer.isFalse || rpcSetting.embeddedAuthRequired.isFalse
                    ? null
                    : () async {
                        await rpcSetting.regenerateEmbeddedToken();
                        embeddedTokenController.text = rpcSetting.embeddedToken.value;
                        rpcAccessTokenController.text = rpcSetting.accessToken.value ?? '';
                        toast('saveSuccess'.tr);
                      },
            tooltip: 'regenerateToken'.tr,
            icon: Icon(
              Icons.refresh,
              color: UIConfig.resumePauseButtonColor(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmbeddedServerStatus() {
    final String status = rpcSetting.enableEmbeddedServer.isFalse
        ? 'rpcEmbeddedServerDisabled'.tr
        : rpcBridgeServerService.serverRunning.isTrue
            ? 'rpcEmbeddedServerRunning'.tr
            : 'rpcEmbeddedServerStarting'.tr;

    final String? error = rpcBridgeServerService.serverError.value;

    return ListTile(
      title: Text('rpcEmbeddedServerStatus'.tr),
      subtitle: Text(error == null ? status : '$status\n$error'),
      isThreeLine: error != null,
      dense: true,
    );
  }

  Future<void> _saveRpcServerAddress() async {
    await rpcSetting.saveServerAddress(rpcServerAddressController.text.trim());
    rpcServerAddressController.text = rpcSetting.serverAddress.value;
  }

  Future<void> _saveRpcAccessToken() async {
    final String token = rpcAccessTokenController.text.trim();
    await rpcSetting.saveAccessToken(token.isEmpty ? null : token);
  }

  Future<void> _saveEmbeddedHost() async {
    await rpcSetting.saveEmbeddedHost(embeddedHostController.text);
    embeddedHostController.text = rpcSetting.embeddedHost.value;
  }

  Future<void> _saveEmbeddedPort() async {
    final int? value = int.tryParse(embeddedPortController.text.trim());
    if (value == null) {
      return;
    }

    await rpcSetting.saveEmbeddedPort(value);
    embeddedPortController.text = rpcSetting.embeddedPort.value.toString();
    if (rpcSetting.enableEmbeddedServer.isTrue) {
      rpcServerAddressController.text = rpcSetting.serverAddress.value;
    }
  }

  Future<void> _saveEmbeddedToken() async {
    await rpcSetting.saveEmbeddedToken(embeddedTokenController.text);
    embeddedTokenController.text = rpcSetting.embeddedToken.value;
    if (rpcSetting.enableEmbeddedServer.isTrue) {
      rpcAccessTokenController.text = rpcSetting.accessToken.value ?? '';
    }
  }

  Future<void> _copyToken(String token) async {
    await Clipboard.setData(ClipboardData(text: token));
    toast('hasCopiedToClipboard'.tr);
  }

  String _rpcServerProfileText(RPCServerProfile profile) {
    return switch (profile) {
      RPCServerProfile.local => 'rpcProfileLocal'.tr,
      RPCServerProfile.lan => 'rpcProfileLan'.tr,
      RPCServerProfile.cloud => 'rpcProfileCloud'.tr,
      RPCServerProfile.custom => 'rpcProfileCustom'.tr,
    };
  }
}
