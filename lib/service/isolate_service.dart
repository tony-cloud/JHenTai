import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:integral_isolates/integral_isolates.dart';

import 'package:jhentai/service/jh_service.dart';

IsolateService isolateService = IsolateService();

class IsolateService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final StatefulIsolate _isolate;
  bool _isolateInitialized = false;

  bool get isInitialized => _isolateInitialized;

  @override
  Future<void> doInitBean() async {
    if (kIsWeb) {
      return;
    }

    _isolate = StatefulIsolate();
    await _isolate.init();
    _isolateInitialized = true;
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<String> jsonEncodeAsync(Object object) async {
    return run(jsonEncode, object);
  }

  Future<dynamic> jsonDecodeAsync(String string) async {
    return run(jsonDecode, string);
  }

  Future<R> run<Q, R>(IsolateCallback<Q, R> callback, Q message, {String? debugLabel}) {
    if (!_isolateInitialized) {
      return Future<R>.value(callback(message));
    }

    return _isolate.compute(callback, message, debugLabel: debugLabel);
  }
}
