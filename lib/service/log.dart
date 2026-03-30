import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/service/printer/error_text_printer.dart';
import 'package:jhentai/service/rolling_file_output.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;

import 'package:jhentai/exception/upload_exception.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/utils/byte_util.dart';

final LogService log = LogService();

class LogService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  String? logDirPath;

  Logger? _consoleLogger;
  Logger? _verboseFileLogger;
  Logger? _errorFileLogger;
  Logger? _downloadFileLogger;
  Future<void>? _initFuture;
  String? _baseFileName;

  static const int _maxLogLinesPerFile = 1000;
  final DateTime _startupTime = DateTime.now();
  PackageInfo? _packageInfo;
  Duration? _startupToFirstFrame;
  bool _firstFrameLogged = false;
  Level? _lastSelectedLevel;
  bool? _lastVerboseEnabled;

  LogPrinter get devPrinter {
    if (kIsWeb) {
      return SimplePrinter(printTime: true);
    }

    return PrettyPrinter(
      stackTraceBeginIndex: 0,
      methodCount: 6,
      levelEmojis: {Level.trace: '✔ '},
    );
  }

  final FileLogPrinter fileLogPrinter = FileLogPrinter(printTime: true, useAnsiColor: true);
  final LogPrinter _errorTextPrinter = ErrorTextPrinter();

  @override
  List<JHLifeCircleBean> get initDependencies => [pathService];

  @override
  Future<void> doInitBean() async {
    _packageInfo = await _resolvePackageInfo();

    PlatformDispatcher.instance.onError = (error, stack) {
      if (error is NotUploadException) {
        return true;
      }

      log.error('Global Error', error, stack);
      return false;
    };

    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exception is NotUploadException) {
        return;
      }

      log.error(
        'Global Error',
        details.exception,
        details.stack ?? StackTrace.current,
      );
    };
  }

  @override
  Future<void> doAfterBeanReady() async {}

  /// For actions that print params
  void trace(Object msg, [bool withStack = false]) async {
    await _initLogger();
    _consoleLogger?.t(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.t(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  /// For actions that is invisible to user
  void debug(Object msg, [bool withStack = false]) async {
    await _initLogger();
    _consoleLogger?.d(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.d(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  /// For actions that is visible to user
  void info(Object msg, [bool withStack = false]) async {
    await _initLogger();
    _consoleLogger?.i(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.i(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  void warning(Object msg, [Object? error, bool withStack = false]) async {
    await _initLogger();
    _consoleLogger?.w(msg, error: error, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.w(msg, error: error, stackTrace: withStack ? null : StackTrace.empty);
  }

  void error(Object msg, [Object? error, StackTrace? stackTrace]) async {
    await _initLogger();
    final StackTrace? effectiveStackTrace = stackTrace ?? (kIsWeb ? StackTrace.current : null);
    _consoleLogger?.e(msg, error: error, stackTrace: effectiveStackTrace);
    _verboseFileLogger?.e(msg, error: error, stackTrace: effectiveStackTrace);
    _errorFileLogger?.e(msg, error: error, stackTrace: effectiveStackTrace);
  }

  void download(Object msg,
      {Level level = Level.trace, Object? error, StackTrace? stackTrace}) async {
    await _initLogger();
    final StackTrace effectiveStack = stackTrace ?? StackTrace.empty;
    _consoleLogger?.log(level, msg, error: error, stackTrace: effectiveStack);
    _downloadFileLogger?.log(level, msg, error: error, stackTrace: effectiveStack);
  }

  Future<void> uploadError(dynamic throwable,
      {dynamic stackTrace, Map<String, dynamic>? extraInfos}) async {
    /// sentry is removed
  }

  Future<String> getSize() async {
    if (logDirPath == null) {
      return byte2String(0);
    }

    return compute(
      (logDirPath) {
        Directory logDirectory = Directory(logDirPath!);
        return logDirectory.exists().then<int>((exist) {
          if (!exist) {
            return 0;
          }

          return logDirectory.list().fold<int>(
              0, (previousValue, element) => previousValue += (element as File).lengthSync());
        }).then<String>((totalBytes) => byte2String(totalBytes.toDouble()));
      },
      logDirPath,
    );
  }

  Future<void> clear() async {
    await _verboseFileLogger?.close();
    await _errorFileLogger?.close();
    await _downloadFileLogger?.close();

    _verboseFileLogger = null;
    _errorFileLogger = null;
    _downloadFileLogger = null;

    if (kIsWeb || logDirPath == null) {
      return;
    }

    if (await Directory(logDirPath!).exists()) {
      await Directory(logDirPath!).delete(recursive: true);
    }
  }

  Future<void> _initLogDir() async {
    if (kIsWeb) {
      return;
    }

    logDirPath ??= path.join(pathService.getVisibleDir().path, 'logs');

    final Directory logDirectory = Directory(logDirPath!);
    if (!await logDirectory.exists()) {
      await logDirectory.create(recursive: true);
    }
  }

  Future<void> _initLogger() async {
    final Future<void>? inFlight = _initFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final Future<void> initTask = _initLoggerUnsafe();
    _initFuture = initTask;
    try {
      await initTask;
    } finally {
      if (identical(_initFuture, initTask)) {
        _initFuture = null;
      }
    }
  }

  Future<void> _initLoggerUnsafe() async {
    final bool verboseEnabled = advancedSetting.enableVerboseLogging.isTrue;
    // Verbose logging toggles additional log channels/files, but must not
    // override the user-selected minimum log level.
    final Level selectedLevel = advancedSetting.logLevel.value;

    final bool needsReinit =
        _lastSelectedLevel != selectedLevel || _lastVerboseEnabled != verboseEnabled;
    if (needsReinit) {
      await _disposeLoggers();
      _lastSelectedLevel = selectedLevel;
      _lastVerboseEnabled = verboseEnabled;
    }

    _consoleLogger ??= Logger(printer: devPrinter, level: selectedLevel);

    if (kIsWeb) {
      return;
    }

    await _initLogDir();
    final String fileName = baseFileName;

    _verboseFileLogger ??= Logger(
      level: selectedLevel,
      printer: fileLogPrinter,
      filter: EHLogFilter.withLevel(selectedLevel),
      output: RollingFileOutput(
        baseFilePath: path.join(logDirPath!, '$fileName.log'),
        headerBuilder: () => _buildLogHeader('Main'),
        maxLines: _maxLogLinesPerFile,
        append: true,
      ),
    );
    if (verboseEnabled) {
      _errorFileLogger ??= Logger(
        level: Level.warning,
        printer: _errorTextPrinter,
        filter: ProductionFilter(),
        output: RollingFileOutput(
          baseFilePath: path.join(logDirPath!, '${fileName}_error.log'),
          headerBuilder: () => _buildLogHeader('Errors'),
          maxLines: _maxLogLinesPerFile,
          append: true,
        ),
      );
      _downloadFileLogger ??= Logger(
        level: selectedLevel,
        printer: fileLogPrinter,
        filter: ProductionFilter(),
        output: RollingFileOutput(
          baseFilePath: path.join(logDirPath!, '${fileName}_download.log'),
          headerBuilder: () => _buildLogHeader('Downloads'),
          maxLines: _maxLogLinesPerFile,
          append: true,
        ),
      );
    }

    await Future.wait([
      _consoleLogger!.init,
      _verboseFileLogger!.init,
      if (_errorFileLogger != null) _errorFileLogger!.init,
      if (_downloadFileLogger != null) _downloadFileLogger!.init,
    ]);
  }

  Future<void> _disposeLoggers() async {
    await _verboseFileLogger?.close();
    await _errorFileLogger?.close();
    await _downloadFileLogger?.close();

    _consoleLogger = null;
    _verboseFileLogger = null;
    _errorFileLogger = null;
    _downloadFileLogger = null;
  }

  /// Resolve per-process base file name so all isolates can align without
  /// temporary marker files.
  String get baseFileName => _baseFileName ??= _defaultBaseFileName();

  /// Adopt a base file name propagated from another isolate. Safe no-op if
  /// already set.
  void adoptBaseFileName(String? name) {
    if (_baseFileName != null || name == null || name.isEmpty) {
      return;
    }
    _baseFileName = name;
  }

  String _defaultBaseFileName() => DateFormat('yyyy-MM-dd_HH-mm-ss').format(_startupTime);

  Future<PackageInfo?> _resolvePackageInfo() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (_) {
      return null;
    }
  }

  Future<void> markFirstFrameRendered() async {
    if (_firstFrameLogged) {
      return;
    }
    _firstFrameLogged = true;

    final DateTime firstFrameTime = DateTime.now();
    _startupToFirstFrame = firstFrameTime.difference(_startupTime);

    final String startupTs = _formatDateTime(_startupTime);
    final String firstFrameTs = _formatDateTime(firstFrameTime);
    final String payload = jsonEncode(_packageInfoAsMap());

    final String message = [
      'First UI frame rendered.',
      'Startup timestamp: $startupTs',
      'First-frame timestamp: $firstFrameTs',
      'Startup duration(ms): ${_startupToFirstFrame!.inMilliseconds}',
      'PackageInfo snapshot: $payload',
    ].join('\n');

    await _initLogger();
    _consoleLogger?.i(message);
    _verboseFileLogger?.i(message);
  }

  String _buildLogHeader(String channelLabel) {
    final PackageInfo? info = _packageInfo;
    final Locale? locale = Get.locale ?? Get.deviceLocale;
    final String localeTag = locale == null
        ? 'unknown'
        : locale.countryCode?.isNotEmpty == true
            ? '${locale.languageCode}-${locale.countryCode}'
            : locale.languageCode;

    final StringBuffer buffer = StringBuffer()
      ..writeln('========== JHenTai Log ($channelLabel) ==========');

    if (info != null) {
      buffer
        ..writeln('App: ${info.appName}')
        ..writeln('Package: ${info.packageName}')
        ..writeln('Version: ${info.version} (build ${info.buildNumber})');
      if (info.buildSignature.isNotEmpty) {
        buffer.writeln('Build signature: ${info.buildSignature}');
      }
      if (info.installerStore?.isNotEmpty == true) {
        buffer.writeln('Installer store: ${info.installerStore}');
      }
      buffer.writeln('PackageInfo JSON: ${jsonEncode(_packageInfoAsMap())}');
    }

    buffer
      ..writeln('Build mode: ${kReleaseMode ? 'release' : 'debug'}')
      ..writeln(
          'Startup: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(_startupTime)} ${_startupTime.timeZoneName}')
      ..writeln(
          'Startup duration to first frame: ${_startupToFirstFrame?.inMilliseconds ?? -1} ms (logged later if -1)')
      ..writeln('Locale: $localeTag')
      ..writeln('Platform: ${_platformDescription()}')
      ..writeln('===============================================');

    return buffer.toString();
  }

  Map<String, dynamic> _packageInfoAsMap() {
    final PackageInfo? info = _packageInfo;
    if (info == null) {
      return {};
    }
    final map = <String, dynamic>{
      'appName': info.appName,
      'packageName': info.packageName,
      'version': info.version,
      'buildNumber': info.buildNumber,
      'buildSignature': info.buildSignature,
      'installerStore': info.installerStore,
    };
    map.removeWhere((key, value) => value == null || (value is String && value.isEmpty));
    return map;
  }

  String _formatDateTime(DateTime time) =>
      '${DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(time)} ${time.timeZoneName}';

  String _platformDescription() {
    if (kIsWeb) {
      return 'web';
    }

    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }
}

class EHLogFilter extends LogFilter {
  EHLogFilter({Level level = Level.debug}) {
    this.level = level;
  }

  factory EHLogFilter.withLevel(Level level) => EHLogFilter(level: level);

  @override
  bool shouldLog(LogEvent event) {
    final Level effectiveLevel = level ?? Level.debug;
    return event.level.index >= effectiveLevel.index;
  }
}

class FileLogPrinter extends LogPrinter {
  FileLogPrinter({this.printTime = true, this.useAnsiColor = false});

  final bool printTime;
  final bool useAnsiColor;
  static final DateFormat _timeFormat = DateFormat('yyyy-MM-ddTHH:mm:ss.SSS');

  static const Map<Level, String> _levelLabels = {
    Level.trace: 'TRACE',
    Level.debug: 'DEBUG',
    Level.info: 'INFO',
    Level.warning: 'WARN',
    Level.error: 'ERROR',
    Level.fatal: 'FATAL',
  };

  static const Map<Level, String> _levelAnsi = {
    Level.trace: '\u001b[90m', // bright black
    Level.debug: '\u001b[36m', // cyan
    Level.info: '\u001b[32m', // green
    Level.warning: '\u001b[33m', // yellow
    Level.error: '\u001b[31m', // red
    Level.fatal: '\u001b[35m', // magenta
  };
  static const String _ansiReset = '\u001b[0m';

  @override
  List<String> log(LogEvent event) {
    final StringBuffer buffer = StringBuffer();
    if (printTime) {
      buffer
        ..write(_timeFormat.format(DateTime.now()))
        ..write(' ');
    }

    final String levelLabel = _levelLabels[event.level] ?? event.level.name.toUpperCase();
    if (useAnsiColor) {
      final String color = _levelAnsi[event.level] ?? _ansiReset;
      buffer
        ..write(color)
        ..write('[')
        ..write(levelLabel)
        ..write('] ')
        ..write(_ansiReset);
    } else {
      buffer
        ..write('[')
        ..write(levelLabel)
        ..write('] ');
    }

    buffer.write(event.message);

    final List<String> lines = [buffer.toString()];

    if (event.error != null) {
      lines.add('Error: ${event.error}');
    }
    final String? stack = event.stackTrace?.toString();
    if (stack != null && stack.isNotEmpty && stack != StackTrace.empty.toString()) {
      lines.add('Stack: $stack');
    }

    return lines;
  }
}

T callWithParamsUploadIfErrorOccurs<T>(T Function() func, {dynamic params, T? defaultValue}) {
  try {
    return func.call();
  } on Exception catch (e) {
    if (e is DioException || e is EHSiteException) {
      rethrow;
    }

    log.error('operationFailed'.tr, e);
    log.uploadError(e, extraInfos: {'params': params});
    if (defaultValue == null) {
      throw NotUploadException(e);
    }
    return defaultValue;
  } on Error catch (e) {
    log.error('operationFailed'.tr, e);
    log.uploadError(e, extraInfos: {'params': params});
    if (defaultValue == null) {
      throw NotUploadException(e);
    }
    return defaultValue;
  }
}
