import 'dart:async';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;

typedef LogHeaderBuilder = String Function();

class RollingFileOutput extends LogOutput {
  RollingFileOutput({
    required String baseFilePath,
    required this.headerBuilder,
    this.maxLines = 1000,
  })  : assert(maxLines > 0),
        _baseFile = File(baseFilePath);

  final File _baseFile;
  final int maxLines;
  final LogHeaderBuilder headerBuilder;

  IOSink? _sink;
  int _fileIndex = 0;
  int _lineCount = 0;
  Future<void> _ioChain = Future.value();
  bool _destroyed = false;

  @override
  Future<void> init() async {
    _destroyed = false;
    // Lazily create the file on first output.
    // This avoids generating 0-byte log files at startup when a logger is
    // initialized but never emits any lines (or only emits buffered header).
  }

  @override
  void output(OutputEvent event) {
    if (_destroyed) {
      return;
    }

    // Serialize all IO to avoid opening many file descriptors during rapid rotation.
    _ioChain = _ioChain.then((_) async {
      if (_destroyed) {
        return;
      }
      _ensureSink();
      for (final line in event.lines) {
        if (_lineCount >= maxLines) {
          await _rotate();
        }
        _sink!.writeln(line);
        _lineCount++;
      }
    });
  }

  @override
  Future<void> destroy() async {
    _destroyed = true;
    await _ioChain;
    await _closeSink(awaitCompletion: true);
  }

  void _ensureSink() {
    _sink ??= _openSink();
  }

  IOSink _openSink({bool incrementIndex = false}) {
    if (incrementIndex) {
      _fileIndex++;
    }
    final File file = _fileIndex == 0 ? _baseFile : _fileWithIndex(_fileIndex);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    _lineCount = 0;
    final IOSink sink = file.openWrite(mode: FileMode.write);
    final String header = headerBuilder().trimRight();
    if (header.isNotEmpty) {
      sink.writeln(header);
      sink.writeln('');
    }
    _sink = sink;
    return sink;
  }

  Future<void> _rotate() async {
    await _closeSink(awaitCompletion: true);
    _openSink(incrementIndex: true);
  }

  Future<void> _closeSink({required bool awaitCompletion}) async {
    final IOSink? sink = _sink;
    _sink = null;
    if (sink == null) {
      return;
    }
    Future<void> doClose() async {
      try {
        await sink.flush();
      } catch (_) {
        // ignore flush errors when closing
      }
      try {
        await sink.close();
      } catch (_) {
        // Ignore state errors such as "StreamSink is bound to a stream" to avoid crashing logging.
      }
    }

    if (awaitCompletion) {
      await doClose();
    } else {
      unawaited(doClose());
    }
  }

  File _fileWithIndex(int index) {
    final String dir = _baseFile.parent.path;
    final String name = p.basenameWithoutExtension(_baseFile.path);
    final String ext = p.extension(_baseFile.path);
    return File(p.join(dir, '${name}_$index$ext'));
  }
}
