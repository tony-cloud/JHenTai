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

  Future<PooledDataConnection> acquire({Duration? timeout}) async {
    final Duration effectiveTimeout = timeout ?? waitTimeout;
    final DateTime deadline = DateTime.now().add(effectiveTimeout);

    while (true) {
      final PooledDataConnection? connection = await _tryAcquireOnce();
      if (connection != null) {
        return connection;
      }

      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw TimeoutException('No available passive data listener within $effectiveTimeout');
      }

      try {
        await _availabilityController.stream.first.timeout(remaining);
      } on TimeoutException {
        throw TimeoutException('No available passive data listener within $effectiveTimeout');
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
    final ServerSocket? listener = _activeListenersByPort.remove(connection.port);
    try {
      await (listener ?? connection.listener).close();
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
    final List<ServerSocket> listeners = _activeListenersByPort.values.toList(growable: false);
    _activeListenersByPort.clear();
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
