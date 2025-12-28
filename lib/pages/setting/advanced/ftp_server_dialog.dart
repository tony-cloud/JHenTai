import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/ftp_server_setting.dart';

class FtpServerDialog extends StatefulWidget {
  const FtpServerDialog({super.key});

  @override
  State<FtpServerDialog> createState() => _FtpServerDialogState();
}

class _FtpServerDialogState extends State<FtpServerDialog> {
  late final TextEditingController _portController;
  late final TextEditingController _poolSizeController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _portRangeStartController;
  late final TextEditingController _portRangeEndController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _enableServer = ftpServerSetting.enableServer.value;
  bool _allowReadWrite = ftpServerSetting.allowReadAndWrite.value;
  bool _keepScreenOn = ftpServerSetting.keepScreenOn.value;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: ftpServerSetting.port.value.toString());
    _poolSizeController =
        TextEditingController(text: ftpServerSetting.passivePoolSize.value.toString());
    _timeoutController =
        TextEditingController(text: ftpServerSetting.passiveTimeoutSeconds.value.toString());
    _portRangeStartController =
        TextEditingController(text: ftpServerSetting.passivePortRangeStart.value.toString());
    _portRangeEndController =
        TextEditingController(text: ftpServerSetting.passivePortRangeEnd.value.toString());
    _usernameController = TextEditingController(text: ftpServerSetting.username.value);
    _passwordController = TextEditingController(text: ftpServerSetting.password.value);
  }

  @override
  void dispose() {
    _portController.dispose();
    _poolSizeController.dispose();
    _timeoutController.dispose();
    _portRangeStartController.dispose();
    _portRangeEndController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('ftpServerDialogTitle'.tr),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'ftpServerPort'.tr),
                validator: (value) {
                  final String trimmed = value?.trim() ?? '';
                  final int? port = int.tryParse(trimmed);
                  if (port == null || port < 1 || port > 65535) {
                    return 'ftpServerInvalidPort'.tr;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _poolSizeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'ftpServerPassivePoolSize'.tr),
                validator: (value) {
                  final String trimmed = value?.trim() ?? '';
                  final int? poolSize = int.tryParse(trimmed);
                  if (poolSize == null || poolSize < 1) {
                    return 'ftpServerInvalidPoolSize'.tr;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _timeoutController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'ftpServerPassiveTimeout'.tr),
                validator: (value) {
                  final String trimmed = value?.trim() ?? '';
                  final int? timeout = int.tryParse(trimmed);
                  if (timeout == null || timeout < 1) {
                    return 'ftpServerInvalidTimeout'.tr;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _portRangeStartController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'ftpServerPassivePortStart'.tr),
                validator: (value) {
                  final int? start = int.tryParse((value ?? '').trim());
                  if (start == null || start < 1 || start > 65535) {
                    return 'ftpServerInvalidPort'.tr;
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _portRangeEndController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'ftpServerPassivePortEnd'.tr),
                validator: (value) {
                  final int? start = int.tryParse(_portRangeStartController.text.trim());
                  final int? end = int.tryParse((value ?? '').trim());
                  final int? poolSize = int.tryParse(_poolSizeController.text.trim());

                  if (end == null || end < 1 || end > 65535) {
                    return 'ftpServerInvalidPort'.tr;
                  }
                  if (start != null && end < start) {
                    return 'ftpServerInvalidPortRange'.tr;
                  }
                  if (start != null && poolSize != null && (end - start + 1) < poolSize) {
                    return 'ftpServerPoolExceedsRange'.tr;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: 'ftpServerUsername'.tr,
                  helperText: ' ',
                ),
              ),
              TextFormField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: 'ftpServerPassword'.tr,
                  helperText: ' ',
                ),
                obscureText: true,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('downloadPath'.tr),
                subtitle: Text(downloadSetting.downloadPath.value,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text('ftpServerEnable'.tr),
                value: _enableServer,
                onChanged: (value) => setState(() => _enableServer = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text('ftpServerAllowReadWrite'.tr),
                subtitle: Text('ftpServerReadOnlyAccess'.tr),
                value: _allowReadWrite,
                onChanged: (value) => setState(() => _allowReadWrite = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text('ftpServerKeepScreenAwake'.tr),
                value: _keepScreenOn,
                onChanged: (value) => setState(() => _keepScreenOn = value),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'ftpServerChangesApplied'.tr,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text('ftpServerCancel'.tr),
        ),
        TextButton(
          onPressed: _saving ? null : _onSave,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('ftpServerSave'.tr),
        ),
      ],
    );
  }

  Future<void> _onSave() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final int port = int.parse(_portController.text.trim());
    final int poolSize = int.parse(_poolSizeController.text.trim());
    final int timeoutSeconds = int.parse(_timeoutController.text.trim());
    final int portRangeStart = int.parse(_portRangeStartController.text.trim());
    final int portRangeEnd = int.parse(_portRangeEndController.text.trim());
    final String username = _usernameController.text.trim();
    final String password = _passwordController.text;

    setState(() => _saving = true);

    try {
      await ftpServerSetting.savePort(port);
      await ftpServerSetting.savePassivePoolSize(poolSize);
      await ftpServerSetting.savePassiveTimeoutSeconds(timeoutSeconds);
      await ftpServerSetting.savePassivePortRange(start: portRangeStart, end: portRangeEnd);
      await ftpServerSetting.saveUsername(username);
      await ftpServerSetting.savePassword(password);
      await ftpServerSetting.saveAllowReadAndWrite(_allowReadWrite);
      await ftpServerSetting.saveKeepScreenOn(_keepScreenOn);
      await ftpServerSetting.saveEnableServer(_enableServer);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}
