import 'dart:async';

import 'package:jhentai/downloader/src/file/file_manager.dart';

/// Serializes operations and drains every accepted operation before disposal.
class Lock {
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  Future<T> lock<T>(AsyncValueCallback<T> operation) {
    if (_disposed) {
      return Future<T>.error(StateError('Lock is disposed'));
    }
    final Future<T> result = _tail.then((_) => operation());
    // One failed operation must not poison subsequent cleanup operations.
    _tail = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> dispose() {
    _disposed = true;
    return _tail;
  }
}
