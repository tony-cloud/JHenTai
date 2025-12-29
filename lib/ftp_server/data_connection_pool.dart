import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'logger_handler.dart';

class PooledDataConnection {
  PooledDataConnection(
      {required this.listener, required this.port, required DataConnectionPool pool})
      : _pool = pool;

  final ServerSocket listener;
  final int port;

  final DataConnectionPool _pool;
  bool _released = false;

  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    await _pool._release(this);
  }
}

class DataConnectionPool {
  DataConnectionPool({
    required this.logger,
    required this.poolSize,
    required this.portRangeStart,
    required this.portRangeEnd,
    required this.waitTimeout,
  }) : _maxAllocations = min(poolSize, max(0, portRangeEnd - portRangeStart + 1));

  final LoggerHandler logger;
  final int poolSize;
  final int portRangeStart;
  final int portRangeEnd;
  final Duration waitTimeout;

  final int _maxAllocations;
  final Map<int, ServerSocket> _activeListenersByPort = {};
  final StreamController<void> _availabilityController = StreamController.broadcast();

  final _AsyncLock _lock = _AsyncLock();

  Future<PooledDataConnection> acquire({
    Duration? timeout,
    Duration keepAliveInterval = const Duration(seconds: 2),
    void Function()? onWaitTick,
  }) async {
    final Duration effectiveTimeout = timeout ?? waitTimeout;
    final DateTime deadline = DateTime.now().add(effectiveTimeout);

    while (true) {
      final PooledDataConnection? connection = await _lock.synchronized(_tryAcquireOnce);
      if (connection != null) {
        return connection;
      }

      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw TimeoutException('No available passive data listener within $effectiveTimeout');
      }

      final Duration waitSlice = remaining < keepAliveInterval ? remaining : keepAliveInterval;
      final Future<bool> availability = _availabilityController.stream.first.then((_) => true);
      final Future<bool> tick = Future.delayed(waitSlice, () => false);

      final bool gotAvailability = await Future.any([availability, tick]);
      if (!gotAvailability) {
        onWaitTick?.call();
      }
    }
  }

  Future<PooledDataConnection?> _tryAcquireOnce() async {
    if (_activeListenersByPort.length >= _maxAllocations) {
      return null;
    }

    for (int port = portRangeStart; port <= portRangeEnd; port++) {
      if (_activeListenersByPort.containsKey(port)) {
        continue;
      }
      try {
        final ServerSocket listener = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        _activeListenersByPort[port] = listener;
        return PooledDataConnection(listener: listener, port: port, pool: this);
      } on SocketException catch (e) {
        // If the process is out of file descriptors, further bind attempts will also fail.
        if (e.osError?.errorCode == 24) {
          logger.warning('Failed to bind passive listener on $port: too many open files', e);
          return null;
        }
        logger.warning('Failed to bind passive listener on $port', e);
      } catch (e) {
        logger.warning('Unexpected error binding passive listener on $port', e);
      }
    }

    return null;
  }

  Future<void> _release(PooledDataConnection connection) async {
    final ServerSocket? listenerToClose = await _lock.synchronized(() async {
      return _activeListenersByPort.remove(connection.port) ?? connection.listener;
    });

    try {
      await listenerToClose?.close();
    } catch (e) {
      logger.warning('Error closing passive listener on ${connection.port}', e);
    }

    if (!_availabilityController.isClosed) {
      _availabilityController.add(null);
    }
  }

  Future<void> dispose() async {
    if (_availabilityController.isClosed) {
      return;
    }

    // Force-close any listeners that might still be held by in-flight sessions.
    // This is important when the FTP server is stopped/restarted without app restart.
    final List<ServerSocket> listeners = await _lock.synchronized(() async {
      final List<ServerSocket> snapshot = _activeListenersByPort.values.toList(growable: false);
      _activeListenersByPort.clear();
      return snapshot;
    });

    for (final listener in listeners) {
      try {
        await listener.close();
      } catch (e) {
        logger.warning('Error closing passive listener during pool dispose', e);
      }
    }

    await _availabilityController.close();
  }
}

class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final Completer<T> completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        final T result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
