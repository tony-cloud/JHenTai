import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import '/ftp_server/server_type.dart';
import 'package:intl/intl.dart';
import 'ftp_command_handler.dart';
import 'logger_handler.dart';
import 'file_operations/file_operations.dart';
import 'data_connection_pool.dart';

class _DataConnectionReservation {
  _DataConnectionReservation(this.connection);

  final PooledDataConnection connection;
  Socket? socket;
}

class FtpSession {
  final Socket controlSocket;
  bool isAuthenticated = false;
  final FTPCommandHandler commandHandler;
  Socket? dataSocket;
  StreamSubscription<List<int>>? _dataSocketSubscription;
  StreamSubscription<List<int>>? _fileReadSubscription;
  final String? username;
  final String? password;
  String? cachedUsername;
  String? pendingRenameFrom;

  final FileOperations fileOperations;
  final ServerType serverType;
  final LoggerHandler logger;
  final DataConnectionPool dataConnectionPool;
  final Duration dataConnectionTimeout;
  final Queue<_DataConnectionReservation> _pendingDataConnections = Queue();
  _DataConnectionReservation? _activeDataConnection;
  bool transferInProgress = false;
  Future<void> _commandChain = Future.value();
  bool _isClosing = false;

  /// Creates an FTP session with the provided file operations backend.
  ///
  /// [fileOperations] handles all file/directory logic (virtual, physical, or custom).
  /// [serverType] determines the mode (read-only or read and write).
  /// Optional parameters include [username], [password], and [logger].
  ///
  /// BREAKING CHANGE: `sharedDirectories` and `startingDirectory` are removed. All directory logic is now handled by the provided [fileOperations].
  FtpSession(this.controlSocket,
      {this.username,
      this.password,
      required FileOperations fileOperations,
      required this.serverType,
      required this.logger,
      required this.dataConnectionPool,
      required this.dataConnectionTimeout})
      : fileOperations = fileOperations.copy(),
        commandHandler = FTPCommandHandler(controlSocket, logger) {
    sendResponse('220 Welcome to the FTP server');
    logger.info('FtpSession created. Ready to process commands.');
    controlSocket.listen(processCommand, onDone: () {
      unawaited(closeConnection());
    });
  }

  void processCommand(List<int> data) {
    if (_isClosing) {
      return;
    }

    final String commandLine;
    try {
      commandLine = utf8.decode(data).trim();
      if (commandLine.isEmpty) {
        return;
      }
    } catch (e, s) {
      logger.error('Command decode error', e, s);
      sendResponse('500 Internal server error');
      return;
    }

    // Serialize commands to prevent uncontrolled async concurrency.
    _commandChain = _commandChain.then((_) async {
      if (_isClosing) {
        return;
      }
      try {
        await commandHandler.handleCommand(commandLine, this);
      } catch (e, s) {
        logger.error('Command processing error', e, s);
        sendResponse('500 Internal server error');
      }
    });
  }

  void sendResponse(String message) {
    logger.logResponse(message);
    try {
      controlSocket.write('$message\r\n');
    } catch (e) {
      logger.warning('Error sending response', e);
    }
  }

  void sendMultiLineResponse(List<String> lines) {
    final String payload = lines.join('\r\n');
    logger.logResponse(payload);
    try {
      controlSocket.write('$payload\r\n');
    } catch (e) {
      logger.warning('Error sending multi-line response', e);
    }
  }

  String _sanitizePathArgument(String argument) {
    final String trimmed = argument.trim();
    if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  Future<void> closeConnection() async {
    if (_isClosing) {
      return;
    }
    _isClosing = true;

    // Ensure all resources are released before returning. This is important for
    // iOS where FD limits are low and users may stop/restart the server without
    // restarting the whole app.
    try {
      await _closeDataSocket();
    } catch (e) {
      logger.warning('Error closing data socket during session shutdown', e);
    }

    try {
      await _cancelTransferSubscriptions();
    } catch (e) {
      logger.warning('Error cancelling transfer subscriptions during session shutdown', e);
    }

    try {
      await _clearPendingDataReservations();
    } catch (e) {
      logger.warning('Error clearing pending data reservations during session shutdown', e);
    }

    try {
      await controlSocket.close();
    } catch (e) {
      logger.warning('Error closing control socket during session shutdown', e);
    }

    logger.info('Connection closed');
  }

  Future<void> _cancelTransferSubscriptions() async {
    final StreamSubscription<List<int>>? fileSub = _fileReadSubscription;
    _fileReadSubscription = null;
    if (fileSub != null) {
      try {
        await fileSub.cancel();
      } catch (e) {
        logger.warning('Error cancelling file read subscription', e);
      }
    }

    final StreamSubscription<List<int>>? dataSub = _dataSocketSubscription;
    _dataSocketSubscription = null;
    if (dataSub != null) {
      try {
        await dataSub.cancel();
      } catch (e) {
        logger.warning('Error cancelling data socket subscription', e);
      }
    }
  }

  Future<bool> openDataConnection() async {
    // If an active-mode data socket is already established (via PORT), reuse it.
    if (dataSocket != null) {
      sendResponse('150 Opening data connection');
      return true;
    }

    final _DataConnectionReservation? reservation =
        _pendingDataConnections.isNotEmpty ? _pendingDataConnections.removeFirst() : null;

    if (reservation == null) {
      sendResponse('425 No passive data connection available');
      return false;
    }

    _activeDataConnection = reservation;

    try {
      dataSocket = await _waitForClientDataSocket(reservation);
    } on TimeoutException catch (e) {
      sendResponse('425 Data connection timeout');
      logger.warning('Data connection timeout on port ${reservation.connection.port}', e);
      await _releaseActiveDataConnection();
      return false;
    } catch (e) {
      sendResponse('425 Can\'t open data connection');
      logger.warning('Error while opening data connection', e);
      await _releaseActiveDataConnection();
      return false;
    }

    if (dataSocket == null) {
      sendResponse('425 Can\'t open data connection');
      await _releaseActiveDataConnection();
      return false;
    }

    sendResponse('150 Opening data connection');
    return true;
  }

  Future<Socket> _waitForClientDataSocket(_DataConnectionReservation reservation) async {
    logger.debug('Waiting for client data socket on ${reservation.connection.port}');

    try {
      final Future<Socket> socketFuture = reservation.connection.listener.first.timeout(
        dataConnectionTimeout,
        onTimeout: () =>
            throw TimeoutException('Timeout reached while waiting for client data socket'),
      );

      reservation.socket = await socketFuture;
      logger.debug('Client data socket accepted on ${reservation.connection.port}');
      return reservation.socket!;
    } finally {
      await _closeServerSocket(reservation.connection.listener);
    }
  }

  Future<void> enterPassiveMode() async {
    try {
      await _resetPendingPassiveListeners();
      final _DataConnectionReservation reservation = await _createPassiveReservation();

      final int port = reservation.connection.port;
      logger.debug('Passive listener bound on port $port');
      int p1 = port >> 8;
      int p2 = port & 0xFF;
      var address = (await _getIpAddress()).replaceAll('.', ',');
      sendResponse('227 Entering Passive Mode ($address,$p1,$p2)');
    } on TimeoutException catch (e) {
      sendResponse('425 Can\'t enter passive mode: no available data port');
      logger.warning('Timeout acquiring passive data listener', e);
    } catch (e) {
      sendResponse('425 Can\'t enter passive mode');
      logger.warning('Error entering passive mode', e);
    }
  }

  Future<void> enterActiveMode(String parameters) async {
    try {
      List<String> parts = parameters.split(',');
      String ip = parts.take(4).join('.');
      int port = int.parse(parts[4]) * 256 + int.parse(parts[5]);
      // Close any existing data socket before establishing a new active connection.
      if (dataSocket != null) {
        try {
          await dataSocket!.close();
        } catch (_) {}
        dataSocket = null;
      }

      dataSocket = await Socket.connect(ip, port);
      sendResponse('200 Active mode connection established');
    } catch (e) {
      sendResponse('425 Can\'t enter active mode');
      logger.warning('Error entering active mode', e);
    }
  }

  Future<String> _getIpAddress() async {
    try {
      final networkInterfaces = await NetworkInterface.list();
      final ipList = networkInterfaces
          .map((interface) => interface.addresses)
          .expand((ip) => ip)
          .where((ip) => ip.type == InternetAddressType.IPv4)
          .toList();

      // Filter IPs that start with '192'
      final wifiIp = ipList.firstWhere(
        (address) => address.address.startsWith('192'),
        orElse: () => ipList.first,
      );

      return wifiIp.address;
    } catch (e) {
      logger.warning('Error getting IP address', e);
    }
    return '0.0.0.0';
  }

  Future<_DataConnectionReservation> _createPassiveReservation() async {
    final PooledDataConnection connection =
        await dataConnectionPool.acquire(timeout: dataConnectionTimeout);
    final _DataConnectionReservation reservation = _DataConnectionReservation(connection);
    _pendingDataConnections.add(reservation);
    return reservation;
  }

  Future<void> _closeServerSocket(ServerSocket listener) async {
    try {
      await listener.close();
    } catch (e) {
      logger.warning('Error closing data listener', e);
    }
  }

  Future<void> _releaseActiveDataConnection() async {
    final _DataConnectionReservation? active = _activeDataConnection;
    _activeDataConnection = null;

    if (active != null) {
      await active.connection.release();
    }
  }

  Future<void> _clearPendingDataReservations() async {
    while (_pendingDataConnections.isNotEmpty) {
      final _DataConnectionReservation reservation = _pendingDataConnections.removeFirst();
      await reservation.connection.release();
    }
  }

  Future<void> _resetPendingPassiveListeners() async {
    // Release any passive listeners that were advertised but not consumed to avoid FD leaks.
    await _clearPendingDataReservations();
  }

  Future<void> listDirectory(String path) async {
    if (!await openDataConnection()) {
      return;
    }

    try {
      transferInProgress = true;

      var dirContents = await fileOperations.listDirectory(path);
      logger.info('Listing directory: $path, for ${fileOperations.resolvePath(path)}');

      for (FileSystemEntity entity in dirContents) {
        if (!transferInProgress) {
          break; // Abort if transfer is cancelled
        }

        try {
          var stat = await entity.stat();
          String permissions = _formatPermissions(stat);
          String fileSize = stat.size.toString();
          String modificationTime = _formatModificationTime(stat.modified);
          String fileName = entity.path.split(Platform.pathSeparator).last;
          String entry = '$permissions 1 ftp ftp $fileSize $modificationTime $fileName\r\n';

          if (dataSocket == null || !transferInProgress) {
            break;
          }

          try {
            dataSocket!.write(entry);
          } catch (socketError) {
            logger.warning('Socket write error during directory listing', socketError);
            transferInProgress = false;
            break;
          }
        } catch (entityError) {
          logger.warning('Error processing entity during directory listing', entityError);
          // Continue with next entity
          continue;
        }
      }

      if (transferInProgress) {
        transferInProgress = false;
        await _closeDataSocket();
        sendResponse('226 Transfer complete');
      } else {
        await _closeDataSocket();
        sendResponse('426 Transfer aborted');
      }
    } catch (e) {
      logger.error('Error listing directory', e);
      sendResponse('550 Failed to list directory');
      transferInProgress = false;
      await _closeDataSocket();
    }
  }

  String _formatPermissions(FileStat stat) {
    String type = stat.type == FileSystemEntityType.directory ? 'd' : '-';
    String owner = _permissionToString(stat.mode >> 6);
    String group = _permissionToString((stat.mode >> 3) & 7);
    String others = _permissionToString(stat.mode & 7);
    return '$type$owner$group$others';
  }

  String _permissionToString(int permission) {
    String read = (permission & 4) != 0 ? 'r' : '-';
    String write = (permission & 2) != 0 ? 'w' : '-';
    String execute = (permission & 1) != 0 ? 'x' : '-';
    return '$read$write$execute';
  }

  String _formatModificationTime(DateTime dateTime) {
    return DateFormat('MMM dd HH:mm').format(dateTime);
  }

// Method to retrieve a file from the server
  Future<void> retrieveFile(String filename) async {
    if (!await openDataConnection()) {
      return;
    }

    try {
      transferInProgress = true;

      if (!fileOperations.exists(filename)) {
        sendResponse('550 File not found $filename');
        transferInProgress = false;
        await _closeDataSocket();
        return;
      }
      String fullPath = fileOperations.resolvePath(filename);

      File file = File(fullPath);
      if (await file.exists()) {
        Stream<List<int>> fileStream = file.openRead();

        // Handle potential socket errors during file transfer
        await _fileReadSubscription?.cancel().catchError((_) {});
        _fileReadSubscription = fileStream.listen(
          (data) {
            if (transferInProgress && dataSocket != null) {
              try {
                dataSocket!.add(data);
              } catch (e) {
                logger.warning('Error writing to data socket', e);
                transferInProgress = false;
                final sub = _fileReadSubscription;
                _fileReadSubscription = null;
                if (sub != null) {
                  unawaited(sub.cancel());
                }
                unawaited(_closeDataSocket());
              }
            }
          },
          onDone: () async {
            _fileReadSubscription = null;
            if (transferInProgress) {
              transferInProgress = false;
              await _closeDataSocket();
              sendResponse('226 Transfer complete');
            }
          },
          onError: (error) async {
            _fileReadSubscription = null;
            logger.warning('Error reading from file', error);
            if (transferInProgress) {
              sendResponse('426 Connection closed; transfer aborted');
              transferInProgress = false;
              await _closeDataSocket();
            }
          },
          cancelOnError: true,
        );
      } else {
        sendResponse('550 File not found $fullPath');
        transferInProgress = false;
        await _closeDataSocket();
      }
    } catch (e) {
      logger.error('Exception in retrieveFile', e);
      sendResponse('550 File transfer failed');
      transferInProgress = false;
      await _closeDataSocket();
    }
  }

// Method to store a file on the server
  Future<void> storeFile(String filename) async {
    if (!await openDataConnection()) {
      return;
    }

    File? file;
    IOSink? fileSink;

    try {
      String fullPath = fileOperations.resolvePath(filename);
      transferInProgress = true;

      // Create the directory if it doesn't exist
      final directory = Directory(fullPath).parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      file = File(fullPath);
      fileSink = file.openWrite();

      // Handle socket errors during file upload
      await _dataSocketSubscription?.cancel().catchError((_) {});
      _dataSocketSubscription = dataSocket!.listen(
        (data) {
          if (transferInProgress) {
            try {
              fileSink?.add(data);
            } catch (e) {
              logger.warning('Error writing to file', e);
              unawaited(_handleTransferError(fileSink));
            }
          }
        },
        onDone: () async {
          _dataSocketSubscription = null;
          if (transferInProgress) {
            try {
              await fileSink?.flush();
              await fileSink?.close();
              transferInProgress = false;
              await _closeDataSocket();
              sendResponse('226 Transfer complete');
              logger.info('File transfer complete: $filename to $fullPath');
            } catch (e) {
              logger.warning('Error closing file after transfer', e);
              unawaited(_handleTransferError(fileSink));
            }
          }
        },
        onError: (error) async {
          _dataSocketSubscription = null;
          logger.warning('Socket error during file upload', error);
          unawaited(_handleTransferError(fileSink));
        },
        cancelOnError: true,
      );
    } catch (e) {
      logger.error('Exception in storeFile', e);
      sendResponse('550 Error creating file or directory: $e');
      transferInProgress = false;
      fileSink?.close().catchError((e) => logger.warning('Error closing file sink', e));
      await _cancelTransferSubscriptions();
      await _closeDataSocket();
    }
  }

  // Helper method to handle transfer errors
  Future<void> _handleTransferError(IOSink? fileSink) async {
    sendResponse('426 Connection closed; transfer aborted');
    if (fileSink != null) {
      try {
        await fileSink.close();
      } catch (e) {
        logger.warning('Error closing file sink during error handling', e);
      }
    }
    transferInProgress = false;
    await _closeDataSocket();
  }

  Future<void> _closeDataSocket() async {
    final Socket? socketToClose = dataSocket;
    // Null out early to prevent concurrent close attempts from callbacks.
    dataSocket = null;

    // Stop any in-flight stream processing that might keep file/socket resources alive.
    await _cancelTransferSubscriptions();

    if (socketToClose != null) {
      try {
        await socketToClose.flush().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            logger.warning('Data socket flush timeout; proceeding to close/destroy');
          },
        );
      } catch (e) {
        logger.warning('Error flushing data socket', e);
      }

      try {
        await socketToClose.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            logger.warning('Data socket close timeout; destroying socket');
          },
        );
      } catch (e) {
        logger.warning('Error closing data socket', e);
      } finally {
        // Always attempt destroy() as a last resort. On some iOS stacks, close()
        // may complete while the underlying handle lingers; destroy() forces it.
        try {
          socketToClose.destroy();
        } catch (e) {
          logger.warning('Error destroying data socket', e);
        }
      }
    }

    await _releaseActiveDataConnection();
  }

// Method to abort a file transfer
  Future<void> abortTransfer() async {
    if (transferInProgress) {
      transferInProgress = false;
      unawaited(_cancelTransferSubscriptions());
      dataSocket?.destroy(); // Forcefully close the data socket
      sendResponse('426 Transfer aborted');
      dataSocket = null;
      await _releaseActiveDataConnection();
    } else {
      sendResponse('226 No transfer in progress');
    }
  }

  void changeDirectory(String dirname) {
    try {
      fileOperations.changeDirectory(dirname);
      final String cwd = fileOperations.getCurrentDirectory();
      sendResponse('250 Directory changed to $cwd');
    } catch (e) {
      sendResponse('550 Access denied or directory not found $e');
      logger.warning('Error changing directory', e);
    }
  }

  void changeToParentDirectory() {
    try {
      fileOperations.changeToParentDirectory();
      final String cwd = fileOperations.getCurrentDirectory();
      sendResponse('250 Directory changed to $cwd');
    } catch (e) {
      sendResponse('550 Access denied or directory not found $e');
      logger.warning('Error changing to parent directory', e);
    }
  }

  Future<void> makeDirectory(String dirname) async {
    try {
      await fileOperations.createDirectory(dirname);
      sendResponse('257 "$dirname" created');
    } catch (e) {
      sendResponse('550 Failed to create directory, error: $e');
      logger.warning('Error creating directory', e);
    }
  }

  Future<void> removeDirectory(String dirname) async {
    try {
      await fileOperations.deleteDirectory(dirname);
      sendResponse('250 Directory deleted');
    } catch (e) {
      sendResponse('550 Failed to delete directory $e');
      logger.warning('Error deleting directory', e);
    }
  }

  Future<void> deleteFile(String filePath) async {
    try {
      await fileOperations.deleteFile(filePath);
      sendResponse('250 File deleted');
    } catch (e) {
      sendResponse('550 Failed to delete file $e');
      logger.warning('Error deleting file', e);
    }
  }

  Future<void> fileSize(String filePath) async {
    try {
      int size = await fileOperations.fileSize(filePath);
      sendResponse('213 $size');
    } catch (e) {
      sendResponse('550 Failed to get file size');
      logger.warning('Error getting file size', e);
    }
  }

  Future<void> enterExtendedPassiveMode() async {
    try {
      await _resetPendingPassiveListeners();
      final _DataConnectionReservation reservation = await _createPassiveReservation();

      int port = reservation.connection.port;
      logger.debug('Extended passive listener bound on port $port');
      sendResponse('229 Entering Extended Passive Mode (|||$port|)');
    } on TimeoutException catch (e) {
      sendResponse('425 Can\'t enter extended passive mode: no available data port');
      logger.warning('Timeout acquiring extended passive listener', e);
    } catch (e) {
      sendResponse('425 Can\'t enter extended passive mode');
      logger.warning('Error entering extended passive mode', e);
    }
  }

  Future<void> handleMlsd(String argument, FtpSession session) async {
    if (!await openDataConnection()) {
      return;
    }

    try {
      transferInProgress = true;
      final String cleanArgument = _sanitizePathArgument(argument);
      final String resolvedPath = cleanArgument.isEmpty
          ? fileOperations.currentDirectory
          : fileOperations.resolvePath(cleanArgument);
      var dirContents = await fileOperations.listDirectory(resolvedPath);
      logger.info('Listing directory with MLSD: $resolvedPath');

      for (FileSystemEntity entity in dirContents) {
        if (!transferInProgress || dataSocket == null) {
          break;
        }

        try {
          var stat = await entity.stat();
          String facts = _formatMlsdFacts(entity, stat);

          try {
            dataSocket!.write(facts);
          } catch (socketError) {
            logger.warning('Socket write error during MLSD', socketError);
            transferInProgress = false;
            break;
          }
        } catch (entityError) {
          logger.warning('Error processing entity during MLSD', entityError);
          // Continue with next entity
          continue;
        }
      }

      if (transferInProgress) {
        transferInProgress = false;
        await _closeDataSocket();
        sendResponse('226 Transfer complete.');
      } else {
        await _closeDataSocket();
        sendResponse('426 Transfer aborted');
      }
    } catch (e) {
      logger.error('Error listing directory with MLSD', e);
      sendResponse('550 Failed to list directory: $e');
      transferInProgress = false;
      await _closeDataSocket();
    }
  }

// Method to abort a file transfer
  String _formatMlsdFacts(FileSystemEntity entity, FileStat stat) {
    String type = stat.type == FileSystemEntityType.directory ? "dir" : "file";
    String modify = DateFormat("yyyyMMddHHmmss").format(stat.modified.toUtc()); // Use UTC time
    String size = stat.size.toString();
    String name = entity.path.split(Platform.pathSeparator).last;

    return "type=$type;modify=$modify;size=$size; $name\r\n";
  }

  void handleMdtm(String argument, FtpSession session) {
    try {
      if (!fileOperations.exists(argument)) {
        sendResponse('550 File not found');
        return;
      }

      String fullPath = fileOperations.resolvePath(argument);
      File file = File(fullPath);
      if (file.existsSync()) {
        var stat = file.statSync();
        String modificationTime = _formatMdtmTimestamp(stat.modified);
        sendResponse('213 $modificationTime');
      } else {
        sendResponse('550 File not found');
      }
    } catch (e) {
      sendResponse('550 Could not get modification time: $e');
      logger.warning('Error getting modification time', e);
    }
  }

  Future<void> handleMfmt(String argument, FtpSession session) async {
    final int separatorIndex = argument.indexOf(' ');
    if (separatorIndex <= 0 || separatorIndex == argument.length - 1) {
      sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    final String timestamp = argument.substring(0, separatorIndex).trim();
    final String targetPath = argument.substring(separatorIndex + 1).trim();

    if (!RegExp(r'^\d{14}$').hasMatch(timestamp)) {
      sendResponse('501 Invalid time format');
      return;
    }

    DateTime modifiedTime;
    try {
      modifiedTime = DateFormat('yyyyMMddHHmmss').parseUtc(timestamp);
    } catch (_) {
      sendResponse('501 Invalid time format');
      return;
    }

    try {
      await fileOperations.setModificationTime(targetPath, modifiedTime);
      sendResponse('213 $timestamp');
    } on FileSystemException catch (e) {
      sendResponse('550 $e');
      logger.warning('Error updating modification time', e);
    } catch (e) {
      sendResponse('550 Could not set modification time: $e');
      logger.warning('Unexpected error updating modification time', e);
    }
  }

  Future<void> handleMlst(String argument) async {
    try {
      final String cleanArgument = _sanitizePathArgument(argument);
      final String resolvedPath = cleanArgument.isEmpty
          ? fileOperations.currentDirectory
          : fileOperations.resolvePath(cleanArgument);

      logger.info('Listing directory with MLST: $resolvedPath');

      final FileSystemEntityType entityType = FileSystemEntity.typeSync(resolvedPath);
      if (entityType == FileSystemEntityType.notFound) {
        sendResponse('550 File not found');
        logger.warning('MLST requested for non-existent path: $resolvedPath');
        return;
      }

      final FileStat stat = await FileStat.stat(resolvedPath);
      final String facts = _formatMlstFacts(resolvedPath, stat);

      sendMultiLineResponse([
        '250- Listing',
        ' $facts',
        '250 End',
      ]);
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 24) {
        sendResponse('451 Requested action aborted: too many open files');
      } else {
        sendResponse('550 Could not get status: $e');
      }
      logger.warning('Error handling MLST', e);
    } catch (e) {
      sendResponse('550 Could not get status: $e');
      logger.warning('Error handling MLST', e);
    }
  }

  String _formatMlstFacts(String path, FileStat stat) {
    final String type = stat.type == FileSystemEntityType.directory ? "dir" : "file";
    final String modify = DateFormat("yyyyMMddHHmmss").format(stat.modified.toUtc());
    final String size = stat.size.toString();
    final String name = path.split(Platform.pathSeparator).last;

    return "type=$type;modify=$modify;size=$size; $name";
  }

  String _formatMdtmTimestamp(DateTime dateTime) {
    return DateFormat('yyyyMMddHHmmss').format(dateTime.toUtc()); // Use UTC
  }

  Future<void> renameFileOrDirectory(String oldPath, String newPath) async {
    try {
      await fileOperations.renameFileOrDirectory(oldPath, newPath);
      pendingRenameFrom = null; // Clear the pending state on success
      sendResponse('250 Requested file action completed successfully');
    } catch (e) {
      pendingRenameFrom = null; // Clear the pending state on error
      sendResponse('550 Failed to rename: $e');
      logger.error('Error renaming $oldPath to $newPath', e);
    }
  }
}
