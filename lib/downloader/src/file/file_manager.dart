import 'dart:async';
import 'dart:io';
import 'package:jhentai/downloader/src/util/lock.dart';
import 'package:jhentai/service/log.dart';

typedef AsyncValueCallback<T> = Future<T> Function();

class FileManager {
  final String path;

  File? _file;

  bool _readReady = false;
  RandomAccessFile? _readRaf;
  Lock? _readLock;

  bool _writeReady = false;
  RandomAccessFile? _writeRaf;
  Lock? _writeLock;

  FileManager({required this.path});

  Future<void> truncate(int length) async {
    await _writeOperation(() => _writeRaf!.truncate(length));
  }

  Future<void> writeFrom(List<int> buffer, {int? position}) async {
    await _writeOperation(() async {
      if (position != null) {
        await _writeRaf!.setPosition(position);
      }
      await _writeRaf!.writeFrom(buffer);
    });
  }

  Future<void> close() async {
    await _closeRead();
    await _closeWrite();
  }

  Future<T> _writeOperation<T>(AsyncValueCallback<T> operation) async {
    await _initWrite();
    T result = await _writeLock!.lock(operation);
    return result;
  }

  Future<void> _initWrite() async {
    if (_writeReady) {
      return;
    }

    log.debug('init write file');

    _file ??= File(path);
    _writeRaf = await File(path).open(mode: FileMode.writeOnlyAppend);
    _writeLock = Lock();
    _writeReady = true;
  }

  Future<void> _closeRead() async {
    if (!_readReady) {
      return;
    }

    await _readLock!.dispose();
    await _readRaf!.flush();
    await _readRaf!.close();

    _readLock = null;
    _readReady = false;
    _readRaf = null;

    log.debug('close read file');
  }

  Future<void> _closeWrite() async {
    if (!_writeReady) {
      return;
    }

    await _writeLock!.dispose();
    await _writeRaf!.flush();
    await _writeRaf!.close();

    _writeLock = null;
    _writeReady = false;
    _writeRaf = null;

    log.debug('close write file');
  }
}
