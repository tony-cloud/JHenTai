import 'dart:io';

void init() {}

Future<bool> getProxyEnable() async {
  if (Platform.isMacOS) {
    return _MacosSystemProxy().getProxyEnable();
  }
  if (Platform.isLinux) {
    return _LinuxSystemProxy().getProxyEnable();
  }
  if (Platform.isWindows) {
    return _WindowsSystemProxy().getProxyEnable();
  }
  return false;
}

Future<bool> setProxyEnable(bool proxyEnable) async {
  if (Platform.isMacOS) {
    return _MacosSystemProxy().setProxyEnable(proxyEnable);
  }
  if (Platform.isLinux) {
    return _LinuxSystemProxy().setProxyEnable(proxyEnable);
  }
  if (Platform.isWindows) {
    return _WindowsSystemProxy().setProxyEnable(proxyEnable);
  }
  return false;
}

Future<String> getProxyServer() async {
  if (Platform.isMacOS) {
    return _MacosSystemProxy().getProxyServer();
  }
  if (Platform.isLinux) {
    return _LinuxSystemProxy().getProxyServer();
  }
  if (Platform.isWindows) {
    return _WindowsSystemProxy().getProxyServer();
  }
  return '';
}

Future<bool> setProxyServer(String proxyServer) async {
  if (Platform.isMacOS) {
    return _MacosSystemProxy().setProxyServer(proxyServer);
  }
  if (Platform.isLinux) {
    return _LinuxSystemProxy().setProxyServer(proxyServer);
  }
  if (Platform.isWindows) {
    return _WindowsSystemProxy().setProxyServer(proxyServer);
  }
  return false;
}

abstract interface class _SystemProxy {
  Future<bool> getProxyEnable();

  Future<bool> setProxyEnable(bool proxyEnable);

  Future<String> getProxyServer();

  Future<bool> setProxyServer(String proxyServer);
}

class _MacosSystemProxy implements _SystemProxy {
  static const List<String> _preferredServices = <String>['Wi-Fi', 'wi-fi'];

  @override
  Future<bool> getProxyEnable() async {
    final String service = await _networkService();
    final ProcessResult result = await _run(
      'networksetup',
      <String>['-getwebproxy', service],
    );
    if (result.exitCode != 0) {
      return false;
    }
    return _lineValue(result.stdout as String, 'Enabled') == 'Yes';
  }

  @override
  Future<bool> setProxyEnable(bool proxyEnable) async {
    final String service = await _networkService();
    final ProcessResult result = await _run(
      'networksetup',
      <String>['-setwebproxystate', service, proxyEnable ? 'on' : 'off'],
    );
    return result.exitCode == 0;
  }

  @override
  Future<String> getProxyServer() async {
    final String service = await _networkService();
    final ProcessResult result = await _run(
      'networksetup',
      <String>['-getwebproxy', service],
    );
    if (result.exitCode != 0) {
      return '';
    }

    final String server = _lineValue(result.stdout as String, 'Server');
    final String port = _lineValue(result.stdout as String, 'Port');
    return server.isEmpty ? '' : '$server:$port';
  }

  @override
  Future<bool> setProxyServer(String proxyServer) async {
    final _ProxyEndpoint? endpoint = _parseProxyEndpoint(proxyServer);
    if (endpoint == null) {
      return false;
    }

    final String service = await _networkService();
    final ProcessResult result = await _run(
      'networksetup',
      <String>['-setwebproxy', service, endpoint.host, endpoint.port],
    );
    return result.exitCode == 0;
  }

  Future<String> _networkService() async {
    final ProcessResult result = await _run(
      'networksetup',
      <String>['-listallhardwareports'],
    );
    if (result.exitCode != 0) {
      return _preferredServices.first;
    }

    final Iterable<String> services = (result.stdout as String)
        .split('\n')
        .where((String line) => line.startsWith('Hardware Port: '))
        .map((String line) => line.substring('Hardware Port: '.length).trim());
    for (final String preferred in _preferredServices) {
      for (final String service in services) {
        if (service.toLowerCase() == preferred.toLowerCase()) {
          return service;
        }
      }
    }
    return _preferredServices.first;
  }
}

class _LinuxSystemProxy implements _SystemProxy {
  @override
  Future<bool> getProxyEnable() async {
    final ProcessResult result = await _gsettings(
      <String>['get', 'org.gnome.system.proxy', 'mode'],
    );
    if (result.exitCode != 0) {
      return false;
    }
    return _normalizeGsettingsValue(result.stdout as String) != 'none';
  }

  @override
  Future<bool> setProxyEnable(bool proxyEnable) async {
    final ProcessResult result = await _gsettings(
      <String>[
        'set',
        'org.gnome.system.proxy',
        'mode',
        proxyEnable ? 'manual' : 'none',
      ],
    );
    return result.exitCode == 0;
  }

  @override
  Future<String> getProxyServer() async {
    final ProcessResult hostResult = await _gsettings(
      <String>['get', 'org.gnome.system.proxy.http', 'host'],
    );
    if (hostResult.exitCode != 0) {
      return '';
    }

    final ProcessResult portResult = await _gsettings(
      <String>['get', 'org.gnome.system.proxy.http', 'port'],
    );
    if (portResult.exitCode != 0) {
      return '';
    }

    final String host = _normalizeGsettingsValue(hostResult.stdout as String);
    final String port = _normalizeGsettingsValue(portResult.stdout as String);
    return host.isEmpty ? '' : '$host:$port';
  }

  @override
  Future<bool> setProxyServer(String proxyServer) async {
    final _ProxyEndpoint? endpoint = _parseProxyEndpoint(proxyServer);
    if (endpoint == null) {
      return false;
    }

    return _runAll(<Future<ProcessResult> Function()>[
      () => _gsettings(<String>[
            'set',
            'org.gnome.system.proxy',
            'mode',
            'manual',
          ]),
      () => _gsettings(<String>[
            'set',
            'org.gnome.system.proxy.http',
            'host',
            endpoint.host,
          ]),
      () => _gsettings(<String>[
            'set',
            'org.gnome.system.proxy.http',
            'port',
            endpoint.port,
          ]),
      () => _gsettings(<String>[
            'set',
            'org.gnome.system.proxy',
            'use-same-proxy',
            'true',
          ]),
    ]);
  }

  Future<ProcessResult> _gsettings(List<String> args) {
    return _run('gsettings', args);
  }
}

class _WindowsSystemProxy implements _SystemProxy {
  static const String _internetSettingsKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  @override
  Future<bool> getProxyEnable() async {
    final ProcessResult result = await _reg(
      <String>['query', _internetSettingsKey, '/v', 'ProxyEnable'],
    );
    if (result.exitCode != 0) {
      return false;
    }
    return _registryValue(result.stdout as String, 'ProxyEnable') == '0x1';
  }

  @override
  Future<bool> setProxyEnable(bool proxyEnable) async {
    final ProcessResult result = await _reg(<String>[
      'add',
      _internetSettingsKey,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/f',
      '/d',
      proxyEnable ? '1' : '0',
    ]);
    return result.exitCode == 0;
  }

  @override
  Future<String> getProxyServer() async {
    final ProcessResult result = await _reg(
      <String>['query', _internetSettingsKey, '/v', 'ProxyServer'],
    );
    if (result.exitCode != 0) {
      return '';
    }
    return _registryValue(result.stdout as String, 'ProxyServer');
  }

  @override
  Future<bool> setProxyServer(String proxyServer) async {
    final ProcessResult result = await _reg(<String>[
      'add',
      _internetSettingsKey,
      '/v',
      'ProxyServer',
      '/f',
      '/d',
      proxyServer,
    ]);
    return result.exitCode == 0;
  }

  Future<ProcessResult> _reg(List<String> args) {
    return _run('reg', args);
  }
}

class _ProxyEndpoint {
  const _ProxyEndpoint(this.host, this.port);

  final String host;
  final String port;
}

Future<bool> _runAll(List<Future<ProcessResult> Function()> commands) async {
  for (final Future<ProcessResult> Function() command in commands) {
    final ProcessResult result = await command();
    if (result.exitCode != 0) {
      return false;
    }
  }
  return true;
}

Future<ProcessResult> _run(String executable, List<String> arguments) {
  return Process.run(executable, arguments);
}

String _lineValue(String output, String key) {
  final String prefix = '$key:';
  for (final String line in output.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.startsWith(prefix)) {
      return trimmed.substring(prefix.length).trim();
    }
  }
  return '';
}

String _normalizeGsettingsValue(String output) {
  return output.trim().replaceAll("'", '');
}

String _registryValue(String output, String key) {
  for (final String line in output.split(RegExp(r'\r?\n'))) {
    final List<String> parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 3 && parts.first == key) {
      return parts.sublist(2).join(' ');
    }
  }
  return '';
}

_ProxyEndpoint? _parseProxyEndpoint(String proxyServer) {
  final RegExpMatch? match =
      RegExp(r'^(?:http://)?(?<host>.+):(?<port>\d+)$').firstMatch(proxyServer);
  if (match == null) {
    return null;
  }
  return _ProxyEndpoint(match.namedGroup('host')!, match.namedGroup('port')!);
}
