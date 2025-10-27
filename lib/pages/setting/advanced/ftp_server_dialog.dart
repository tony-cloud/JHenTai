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
    _usernameController = TextEditingController(text: ftpServerSetting.username.value);
    _passwordController = TextEditingController(text: ftpServerSetting.password.value);
  }

  @override
  void dispose() {
    _portController.dispose();
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
    final String username = _usernameController.text.trim();
    final String password = _passwordController.text;

    setState(() => _saving = true);

    try {
      await ftpServerSetting.savePort(port);
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
