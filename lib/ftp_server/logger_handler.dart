import 'package:jhentai/service/log.dart';

class LoggerHandler {
  void trace(String message) {
    log.trace(message);
  }

  void debug(String message) {
    log.debug(message);
  }

  void info(String message) {
    log.info(message);
  }

  void warning(String message, [Object? error]) {
    log.warning(message, error);
  }

  void error(String message, [Object? error, StackTrace? stackTrace]) {
    log.error(message, error, stackTrace);
  }

  void logCommand(String command, String argument) {
    log.trace('Command: $command, Argument: $argument');
  }

  void logResponse(String response) {
    log.trace('Response: $response');
  }
}
