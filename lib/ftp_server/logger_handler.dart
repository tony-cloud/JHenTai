import 'package:jhentai/service/log.dart';

class LoggerHandler {
  LoggerHandler() : _logService = log;

  final LogService _logService;

  void trace(String message) {
    _logService.trace(message);
  }

  void debug(String message) {
    _logService.debug(message);
  }

  void info(String message) {
    _logService.info(message);
  }

  void warning(String message, [Object? error]) {
    _logService.warning(message, error);
  }

  void error(String message, [Object? error, StackTrace? stackTrace]) {
    _logService.error(message, error, stackTrace);
  }

  void logCommand(String command, String argument) {
    _logService.trace('Command: $command, Argument: $argument');
  }

  void logResponse(String response) {
    _logService.trace('Response: $response');
  }
}
