import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jhentai/database/database.dart';

class LocalConfig {
  ConfigEnum configKey;
  String subConfigKey;
  String value;
  String utime;

  LocalConfig({
    required this.configKey,
    required this.subConfigKey,
    required this.value,
    required this.utime,
  });

  Map<String, dynamic> toJson() {
    return {
      "configKey": configKey.key,
      "subConfigKey": subConfigKey,
      "value": value,
      "utime": utime,
    };
  }

  factory LocalConfig.fromJson(Map<String, dynamic> json) {
    return LocalConfig(
      configKey: ConfigEnum.from(json["configKey"]),
      subConfigKey: json["subConfigKey"],
      value: json["value"],
      utime: json["utime"],
    );
  }
}

LocalConfigService localConfigService = LocalConfigService();

class LocalConfigService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String defaultSubConfigKey = '';
  Future<SharedPreferences>? _preferencesFuture;

  @override
  Future<void> doInitBean() async {
    if (kIsWeb) {
      _preferencesFuture = SharedPreferences.getInstance();
      await _preferencesFuture;
    }
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<int> write(
      {required ConfigEnum configKey,
      String subConfigKey = defaultSubConfigKey,
      required String value}) {
    if (kIsWeb) {
      return _prefs().then((prefs) async {
        await prefs.setString(_composeWebKey(configKey, subConfigKey), value);
        return 1;
      });
    }

    return appDb.managers.localConfig.create(
      (l) => l(
          configKey: configKey.key,
          subConfigKey: subConfigKey,
          value: value,
          utime: DateTime.now().toString()),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<void> batchWrite(List<LocalConfigCompanion> localConfigs) async {
    if (kIsWeb) {
      final SharedPreferences prefs = await _prefs();
      for (final LocalConfigCompanion config in localConfigs) {
        await prefs.setString(
          _composeWebKey(
            ConfigEnum.from(config.configKey.value),
            config.subConfigKey.value,
          ),
          config.value.value,
        );
      }
      return;
    }

    return appDb.managers.localConfig.bulkCreate(
      (l) => localConfigs
          .map((i) => l(
                configKey: i.configKey.value,
                subConfigKey: i.subConfigKey.value,
                value: i.value.value,
                utime: DateTime.now().toString(),
              ))
          .toList(),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<String?> read({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey}) {
    if (kIsWeb) {
      return _prefs().then((prefs) => prefs.getString(_composeWebKey(configKey, subConfigKey)));
    }

    return appDb.managers.localConfig
        .filter((config) =>
            config.configKey.equals(configKey.key) & config.subConfigKey.equals(subConfigKey))
        .getSingleOrNull()
        .then((value) => value?.value);
  }

  Future<List<LocalConfig>> readWithAllSubKeys({required ConfigEnum configKey}) {
    if (kIsWeb) {
      final String prefix = '${configKey.key}::';
      return _prefs().then((prefs) {
        return prefs
            .getKeys()
            .where((key) => key.startsWith(prefix))
            .map((key) => LocalConfig(
                  configKey: configKey,
                  subConfigKey: key.substring(prefix.length),
                  value: prefs.getString(key) ?? '',
                  utime: DateTime.now().toString(),
                ))
            .toList();
      });
    }

    return appDb.managers.localConfig
        .filter((config) => config.configKey.equals(configKey.key))
        .get()
        .then((value) {
      return value
          .map((e) => LocalConfig(
                configKey: ConfigEnum.from(e.configKey),
                subConfigKey: e.subConfigKey,
                value: e.value,
                utime: e.utime,
              ))
          .toList();
    });
  }

  Future<bool> delete({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey}) {
    if (kIsWeb) {
      return _prefs().then((prefs) => prefs.remove(_composeWebKey(configKey, subConfigKey)));
    }

    return appDb.managers.localConfig
        .filter((config) =>
            config.configKey.equals(configKey.key) & config.subConfigKey.equals(subConfigKey))
        .delete()
        .then((value) => value > 0);
  }

  Future<int> deleteAll({required ConfigEnum configKey}) {
    if (kIsWeb) {
      final String prefix = '${configKey.key}::';
      return _prefs().then((prefs) async {
        final List<String> keys =
            prefs.getKeys().where((key) => key.startsWith(prefix)).toList();
        for (final String key in keys) {
          await prefs.remove(key);
        }
        return keys.length;
      });
    }

    return appDb.managers.localConfig
        .filter((config) => config.configKey.equals(configKey.key))
        .delete();
  }

  String _composeWebKey(ConfigEnum configKey, String subConfigKey) {
    return '${configKey.key}::$subConfigKey';
  }

  Future<SharedPreferences> _prefs() {
    return _preferencesFuture ??= SharedPreferences.getInstance();
  }
}
