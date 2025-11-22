import 'package:intl/intl.dart';
import 'package:logger/logger.dart';

class ErrorTextPrinter extends LogPrinter {
  ErrorTextPrinter({DateFormat? timestampFormat})
      : _timestampFormat = timestampFormat ?? DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  final DateFormat _timestampFormat;

  @override
  List<String> log(LogEvent event) {
    final String timestamp = _timestampFormat.format(DateTime.now());
    final String levelLabel = event.level.name.toUpperCase().padRight(5);

    final List<String> lines = [];
    final List<String> messageLines = event.message.toString().split('\n');
    final String firstLine = messageLines.isNotEmpty ? messageLines.first : '';
    lines.add('[$timestamp][$levelLabel] $firstLine');
    for (final extra in messageLines.skip(1)) {
      lines.add(' ' * (timestamp.length + levelLabel.length + 4) + extra);
    }

    if (event.error != null) {
      lines.add('Error: ${event.error}');
    }

    if (event.stackTrace != null) {
      lines.add('Stacktrace:');
      lines.addAll(event.stackTrace.toString().trimRight().split('\n'));
    }

    return lines;
  }
}
