import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '/ftp_server/server_type.dart';
import 'package:intl/intl.dart';
import 'ftp_command_handler.dart';
import 'logger_handler.dart';
import 'file_operations/file_operations.dart';
import 'data_connection_pool.dart';
import 'socket_manager.dart';

class FtpSession {
  final Socket controlSocket;
  bool isAuthenticated = false;
  final FTPCommandHandler commandHandler;
  String? clientName;
  int? restartOffset;
  final String? username;
  final String? password;
  String? cachedUsername;
  String? pendingRenameFrom;

  // RFC 959 defaults: MODE S (Stream), STRU F (File)
  String _transferMode = 'S';
  String _fileStructure = 'F';

  final FileOperations fileOperations;
  final ServerType serverType;
  final LoggerHandler logger;
  final DataConnectionPool dataConnectionPool;
  final Duration dataConnectionTimeout;

  late final FtpSocketManager socketManager;
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
        commandHandler = FTPCommandHandler(controlSocket) {
    socketManager = FtpSocketManager(
      logger: logger,
      pool: dataConnectionPool,
      dataTimeout: dataConnectionTimeout,
    );
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
    transferInProgress = false;
    try {
      await socketManager.dispose();
    } catch (e) {
      logger.warning('Error disposing socket manager during session shutdown', e);
    }

    try {
      await controlSocket.close();
    } catch (e) {
      logger.warning('Error closing control socket during session shutdown', e);
    }

    logger.info('Connection closed');
  }

  Future<FtpDataChannel?> _openDataChannel() async {
    try {
      final FtpDataChannel? channel = await socketManager.openDataChannel();
      if (channel == null) {
        sendResponse('425 No passive data connection available');
        return null;
      }
      sendResponse('150 Opening data connection');
      return channel;
    } on TimeoutException catch (e) {
      sendResponse('425 Data connection timeout');
      logger.warning('Data connection timeout while opening data channel', e);
      return null;
    } catch (e) {
      sendResponse('425 Can\'t open data connection');
      logger.warning('Error while opening data connection', e);
      return null;
    }
  }

  Future<void> enterPassiveMode() async {
    try {
      final int port = await socketManager.preparePassive(
        timeout: dataConnectionTimeout,
        onWaitTick: () => sendResponse('120 Waiting for available data connection'),
      );
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

      await socketManager.prepareActive(ip, port);
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

  Future<void> listDirectory(String path) async {
    final FtpDataChannel? channel = await _openDataChannel();
    if (channel == null) {
      return;
    }

    try {
      transferInProgress = true;

      var dirContents = await fileOperations.listDirectory(path);
      logger.debug('Listing directory: $path, for ${fileOperations.resolvePath(path)}');

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

          if (!transferInProgress) {
            break;
          }

          try {
            channel.socket.write(entry);
          } catch (socketError) {
            logger.error('Socket write error during directory listing', socketError);
            transferInProgress = false;
            break;
          }
        } catch (entityError) {
          logger.error('Error processing entity during directory listing', entityError);
          // Continue with next entity
          continue;
        }
      }

      if (transferInProgress) {
        transferInProgress = false;
        await socketManager.closeActive();
        sendResponse('226 Transfer complete');
      } else {
        await socketManager.closeActive();
        sendResponse('426 Transfer aborted');
      }
    } catch (e) {
      logger.error('Error listing directory', e);
      sendResponse('550 Failed to list directory');
      transferInProgress = false;
      await socketManager.closeActive();
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

  int _consumeRestartOffset() {
    final int offset = restartOffset ?? 0;
    restartOffset = null;
    return offset;
  }

  void handleMode(String argument) {
    final String mode = argument.trim().toUpperCase();
    if (mode.isEmpty) {
      sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    // Only Stream mode is supported.
    if (mode == 'S') {
      _transferMode = 'S';
      sendResponse('200 Mode set to S');
      return;
    }

    sendResponse('504 MODE $mode not implemented');
  }

  void handleStru(String argument) {
    final String stru = argument.trim().toUpperCase();
    if (stru.isEmpty) {
      sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    // Only File structure is supported.
    if (stru == 'F') {
      _fileStructure = 'F';
      sendResponse('200 Structure set to F');
      return;
    }

    sendResponse('504 STRU $stru not implemented');
  }

  Future<void> appendFile(String filename) async {
    final String target = filename.trim();
    if (target.isEmpty) {
      sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    // APPE always appends. If REST was provided, reject to avoid ambiguous behavior.
    if ((restartOffset ?? 0) != 0) {
      restartOffset = null;
      sendResponse('503 Bad sequence of commands');
      return;
    }

    final FtpDataChannel? channel = await _openDataChannel();
    if (channel == null) {
      return;
    }

    IOSink? fileSink;
    try {
      final String fullPath = fileOperations.resolvePath(target);
      transferInProgress = true;

      final Directory directory = Directory(fullPath).parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final File file = File(fullPath);
      fileSink = file.openWrite(mode: FileMode.append);

      await channel.socketSubscription?.cancel().catchError((_) {});
      channel.socketSubscription = channel.socket.listen(
        (data) {
          if (!transferInProgress) {
            return;
          }
          try {
            fileSink!.add(data);
          } catch (e) {
            logger.warning('Error writing to file (append)', e);
            unawaited(_handleTransferError(fileSink));
          }
        },
        onDone: () async {
          channel.socketSubscription = null;
          if (transferInProgress) {
            try {
              await fileSink?.flush();
              await fileSink?.close();
              fileSink = null;
              transferInProgress = false;
              await socketManager.closeActive();
              sendResponse('226 Transfer complete');
              logger.info('File append complete: $target to $fullPath');
            } catch (e) {
              logger.warning('Error closing file after append', e);
              unawaited(_handleTransferError(fileSink));
            }
          }
        },
        onError: (error) async {
          channel.socketSubscription = null;
          logger.warning('Socket error during file append', error);
          unawaited(_handleTransferError(fileSink));
        },
        cancelOnError: true,
      );
    } catch (e) {
      logger.error('Exception in appendFile', e);
      sendResponse('550 Error appending file: $e');
      transferInProgress = false;
      fileSink?.close().catchError((e) => logger.warning('Error closing file sink', e));
      await socketManager.abortActive();
    }
  }

  Future<void> handleStat(String argument) async {
    final String trimmed = argument.trim();
    if (trimmed.isEmpty) {
      sendMultiLineResponse([
        '211-Status',
        ' Logged in: ${isAuthenticated ? 'yes' : 'no'}',
        ' CWD: ${fileOperations.getCurrentDirectory()}',
        ' Transfer: ${transferInProgress ? 'in progress' : 'idle'}',
        ' MODE: $_transferMode',
        ' STRU: $_fileStructure',
        if (clientName != null) ' CLNT: $clientName',
        '211 End',
      ]);
      return;
    }

    final String cleanArgument = _sanitizePathArgument(trimmed);
    final String resolvedPath = cleanArgument.isEmpty
        ? fileOperations.currentDirectory
        : fileOperations.resolvePath(cleanArgument);

    try {
      final FileSystemEntityType entityType = FileSystemEntity.typeSync(resolvedPath);
      if (entityType == FileSystemEntityType.notFound) {
        sendResponse('550 File not found');
        return;
      }

      final List<String> lines = <String>['213-Status of $cleanArgument'];

      if (entityType == FileSystemEntityType.directory) {
        final List<FileSystemEntity> dirContents = await fileOperations.listDirectory(resolvedPath);
        for (final entity in dirContents) {
          try {
            final FileStat stat = await entity.stat();
            final String permissions = _formatPermissions(stat);
            final String fileSize = stat.size.toString();
            final String modificationTime = _formatModificationTime(stat.modified);
            final String fileName = entity.path.split(Platform.pathSeparator).last;
            lines.add('$permissions 1 ftp ftp $fileSize $modificationTime $fileName');
          } catch (e) {
            // Best-effort STAT output; skip entries that fail.
            logger.warning('Error building STAT entry', e);
          }
        }
      } else {
        final FileStat stat = await FileStat.stat(resolvedPath);
        final String permissions = _formatPermissions(stat);
        final String fileSize = stat.size.toString();
        final String modificationTime = _formatModificationTime(stat.modified);
        final String fileName = resolvedPath.split(Platform.pathSeparator).last;
        lines.add('$permissions 1 ftp ftp $fileSize $modificationTime $fileName');
      }

      lines.add('213 End');
      sendMultiLineResponse(lines);
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 24) {
        sendResponse('451 Requested action aborted: too many open files');
      } else {
        sendResponse('550 Could not get status: $e');
      }
      logger.warning('Error handling STAT', e);
    } catch (e) {
      sendResponse('550 Could not get status: $e');
      logger.warning('Error handling STAT', e);
    }
  }

// Method to retrieve a file from the server
  Future<void> retrieveFile(String filename) async {
    final FtpDataChannel? channel = await _openDataChannel();
    if (channel == null) {
      return;
    }

    try {
      transferInProgress = true;

      if (!fileOperations.exists(filename)) {
        sendResponse('550 File not found $filename');
        transferInProgress = false;
        await socketManager.closeActive();
        return;
      }
      String fullPath = fileOperations.resolvePath(filename);

      File file = File(fullPath);
      if (await file.exists()) {
        final int startOffset = _consumeRestartOffset();
        final int fileLength = await file.length();
        if (startOffset > fileLength) {
          sendResponse('554 Invalid restart position');
          transferInProgress = false;
          await socketManager.closeActive();
          return;
        }

        Stream<List<int>> fileStream = file.openRead(startOffset);

        // Handle potential socket errors during file transfer
        await channel.fileSubscription?.cancel().catchError((_) {});
        channel.fileSubscription = fileStream.listen(
          (data) {
            if (transferInProgress) {
              try {
                channel.socket.add(data);
              } catch (e) {
                logger.warning('Error writing to data socket', e);
                transferInProgress = false;
                final sub = channel.fileSubscription;
                channel.fileSubscription = null;
                sub?.cancel().catchError((_) {});
                unawaited(socketManager.abortActive());
              }
            }
          },
          onDone: () async {
            channel.fileSubscription = null;
            if (transferInProgress) {
              transferInProgress = false;
              await socketManager.closeActive();
              sendResponse('226 Transfer complete');
            }
          },
          onError: (error) async {
            channel.fileSubscription = null;
            logger.warning('Error reading from file', error);
            if (transferInProgress) {
              sendResponse('426 Connection closed; transfer aborted');
              transferInProgress = false;
              await socketManager.abortActive();
            }
          },
          cancelOnError: true,
        );
      } else {
        sendResponse('550 File not found $fullPath');
        transferInProgress = false;
        await socketManager.closeActive();
      }
    } catch (e) {
      logger.error('Exception in retrieveFile', e);
      sendResponse('550 File transfer failed');
      transferInProgress = false;
      await socketManager.abortActive();
    }
  }

// Method to store a file on the server
  Future<void> storeFile(String filename) async {
    final FtpDataChannel? channel = await _openDataChannel();
    if (channel == null) {
      return;
    }

    File? file;
    IOSink? fileSink;
    RandomAccessFile? raf;

    try {
      String fullPath = fileOperations.resolvePath(filename);
      transferInProgress = true;

      // Create the directory if it doesn't exist
      final directory = Directory(fullPath).parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      file = File(fullPath);
      final int startOffset = _consumeRestartOffset();

      if (startOffset > 0) {
        // Resume upload at a specific offset.
        raf = await file.open(mode: FileMode.write);
        final int currentLength = await raf.length();
        if (currentLength < startOffset) {
          // truncate() also extends the file with zeros if needed.
          await raf.truncate(startOffset);
        }
        await raf.setPosition(startOffset);

        Future<void> writeChain = Future.value();

        await channel.socketSubscription?.cancel().catchError((_) {});
        channel.socketSubscription = channel.socket.listen(
          (data) {
            if (!transferInProgress) {
              return;
            }
            writeChain = writeChain.then((_) async {
              await raf!.writeFrom(data);
            }).catchError((e) {
              logger.warning('Error writing to file (resume upload)', e);
              unawaited(_handleTransferErrorWithRaf(fileSink: null, raf: raf));
            });
          },
          onDone: () async {
            channel.socketSubscription = null;
            if (transferInProgress) {
              try {
                await writeChain;
                await raf?.close();
                raf = null;
                transferInProgress = false;
                await socketManager.closeActive();
                sendResponse('226 Transfer complete');
                logger.info('File transfer complete (resume): $filename to $fullPath');
              } catch (e) {
                logger.warning('Error closing file after resume upload', e);
                unawaited(_handleTransferErrorWithRaf(fileSink: null, raf: raf));
              }
            }
          },
          onError: (error) async {
            channel.socketSubscription = null;
            logger.warning('Socket error during resume file upload', error);
            unawaited(_handleTransferErrorWithRaf(fileSink: null, raf: raf));
          },
          cancelOnError: true,
        );

        return;
      }

      fileSink = file.openWrite();

      // Handle socket errors during file upload
      await channel.socketSubscription?.cancel().catchError((_) {});
      channel.socketSubscription = channel.socket.listen(
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
          channel.socketSubscription = null;
          if (transferInProgress) {
            try {
              await fileSink?.flush();
              await fileSink?.close();
              transferInProgress = false;
              await socketManager.closeActive();
              sendResponse('226 Transfer complete');
              logger.info('File transfer complete: $filename to $fullPath');
            } catch (e) {
              logger.warning('Error closing file after transfer', e);
              unawaited(_handleTransferError(fileSink));
            }
          }
        },
        onError: (error) async {
          channel.socketSubscription = null;
          logger.warning('Socket error during file upload', error);
          unawaited(_handleTransferError(fileSink));
        },
        cancelOnError: true,
      );
    } catch (e) {
      logger.error('Exception in storeFile', e);
      sendResponse('550 Error creating file or directory: $e');
      transferInProgress = false;
      try {
        await raf?.close();
      } catch (e) {
        logger.warning('Error closing random access file sink', e);
      }
      fileSink?.close().catchError((e) => logger.warning('Error closing file sink', e));
      await socketManager.abortActive();
    }
  }

  Future<void> _handleTransferErrorWithRaf({IOSink? fileSink, RandomAccessFile? raf}) async {
    sendResponse('426 Connection closed; transfer aborted');

    if (fileSink != null) {
      try {
        await fileSink.close();
      } catch (e) {
        logger.warning('Error closing file sink during error handling', e);
      }
    }

    if (raf != null) {
      try {
        await raf.close();
      } catch (e) {
        logger.warning('Error closing random access file during error handling', e);
      }
    }

    transferInProgress = false;
    await socketManager.abortActive();
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
    await socketManager.abortActive();
  }

// Method to abort a file transfer
  Future<void> abortTransfer() async {
    if (transferInProgress) {
      transferInProgress = false;
      await socketManager.abortActive();
      sendResponse('426 Transfer aborted');
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
      final int port = await socketManager.preparePassive(
        timeout: dataConnectionTimeout,
        onWaitTick: () => sendResponse('120 Waiting for available data connection'),
      );
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
    final FtpDataChannel? channel = await _openDataChannel();
    if (channel == null) {
      return;
    }

    try {
      transferInProgress = true;
      final String cleanArgument = _sanitizePathArgument(argument);
      final String resolvedPath = cleanArgument.isEmpty
          ? fileOperations.currentDirectory
          : fileOperations.resolvePath(cleanArgument);
      var dirContents = await fileOperations.listDirectory(resolvedPath);
      logger.debug('Listing directory with MLSD: $resolvedPath');

      for (FileSystemEntity entity in dirContents) {
        if (!transferInProgress) {
          break;
        }

        try {
          var stat = await entity.stat();
          String facts = _formatMlsdFacts(entity, stat);

          try {
            channel.socket.write(facts);
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
        await socketManager.closeActive();
        sendResponse('226 Transfer complete.');
      } else {
        await socketManager.closeActive();
        sendResponse('426 Transfer aborted');
      }
    } catch (e) {
      logger.error('Error listing directory with MLSD', e);
      sendResponse('550 Failed to list directory: $e');
      transferInProgress = false;
      await socketManager.closeActive();
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

      logger.debug('Listing directory with MLST: $resolvedPath');

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
