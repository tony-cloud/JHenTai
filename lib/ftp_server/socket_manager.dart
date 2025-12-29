import 'dart:async';
import 'dart:io';

import 'data_connection_pool.dart';
import 'logger_handler.dart';

class FtpDataChannel {
  FtpDataChannel(this.socket);

  final Socket socket;

  StreamSubscription<List<int>>? socketSubscription;
  StreamSubscription<List<int>>? fileSubscription;

  Future<void> cancelSubscriptions(LoggerHandler logger) async {
    final StreamSubscription<List<int>>? fileSub = fileSubscription;
    fileSubscription = null;
    if (fileSub != null) {
      try {
        await fileSub.cancel();
      } catch (e) {
        logger.warning('Error cancelling file subscription', e);
      }
    }

    final StreamSubscription<List<int>>? sockSub = socketSubscription;
    socketSubscription = null;
    if (sockSub != null) {
      try {
        await sockSub.cancel();
      } catch (e) {
        logger.warning('Error cancelling socket subscription', e);
      }
    }
  }

  Future<void> close(LoggerHandler logger) async {
    await cancelSubscriptions(logger);

    try {
      await socket.flush().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      logger.warning('Data socket flush timeout; destroying socket');
      try {
        socket.destroy();
      } catch (e) {
        logger.warning('Error destroying socket after flush timeout', e);
      }
      return;
    } catch (e) {
      logger.warning('Error flushing data socket', e);
    }

    try {
      await socket.close().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      logger.warning('Data socket close timeout; destroying socket');
      try {
        socket.destroy();
      } catch (e) {
        logger.warning('Error destroying socket after close timeout', e);
      }
    } catch (e) {
      logger.warning('Error closing data socket', e);
    } finally {
      // Best-effort force close.
      try {
        socket.destroy();
      } catch (e) {
        logger.warning('Error destroying data socket', e);
      }
    }
  }
}

/// Owns all state related to an FTP session data connection.
///
/// RFC 959 expects at most one data connection per command channel (session).
/// This manager centralizes creation/accept, subscriptions, and teardown to
/// avoid scattered lifecycle operations.
class FtpSocketManager {
  FtpSocketManager({required this.logger, required this.pool, required this.dataTimeout});

  final LoggerHandler logger;
  final DataConnectionPool pool;
  final Duration dataTimeout;

  PooledDataConnection? _pendingPassive;
  FtpDataChannel? _active;

  Future<void> dispose() async {
    await closeActive();
    await _releasePendingPassive();
  }

  Future<void> _releasePendingPassive() async {
    final PooledDataConnection? pending = _pendingPassive;
    _pendingPassive = null;
    if (pending != null) {
      try {
        await pending.release();
      } catch (e) {
        logger.warning('Error releasing pending passive listener', e);
      }
    }
  }

  Future<int> preparePassive({Duration? timeout, void Function()? onWaitTick}) async {
    // RFC 959: only one data connection at a time; discard any stale passive listener.
    await _releasePendingPassive();

    final PooledDataConnection conn = await pool.acquire(
      timeout: timeout,
      onWaitTick: onWaitTick,
      keepAliveInterval: const Duration(seconds: 2),
    );

    _pendingPassive = conn;
    return conn.port;
  }

  Future<void> prepareActive(String host, int port) async {
    await closeActive();
    await _releasePendingPassive();

    final Socket socket = await Socket.connect(host, port);
    _active = FtpDataChannel(socket);
  }

  Future<FtpDataChannel?> openDataChannel() async {
    // Active mode: already connected.
    if (_active != null) {
      return _active;
    }

    final PooledDataConnection? pending = _pendingPassive;
    _pendingPassive = null;
    if (pending == null) {
      return null;
    }

    try {
      final Socket socket = await pending.listener.first.timeout(
        dataTimeout,
        onTimeout: () => throw TimeoutException('Timeout waiting for client data connection'),
      );
      _active = FtpDataChannel(socket);
      return _active;
    } finally {
      // Always release the passive listener (closes the ServerSocket and frees the pool slot).
      try {
        await pending.release();
      } catch (e) {
        logger.warning('Error releasing passive listener after accept', e);
      }
    }
  }

  Future<void> closeActive() async {
    final FtpDataChannel? channel = _active;
    _active = null;
    if (channel != null) {
      await channel.close(logger);
    }
  }

  Future<void> abortActive() async {
    final FtpDataChannel? channel = _active;
    _active = null;
    if (channel != null) {
      await channel.cancelSubscriptions(logger);
      try {
        channel.socket.destroy();
      } catch (e) {
        logger.warning('Error destroying data socket during abort', e);
      }
    }
  }
}
