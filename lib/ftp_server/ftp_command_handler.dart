import 'dart:io';
import '/ftp_server/ftp_session.dart';
import '/ftp_server/server_type.dart';
import 'logger_handler.dart';

class FTPCommandHandler {
  final Socket controlSocket;
  final LoggerHandler logger;

  FTPCommandHandler(this.controlSocket, this.logger);

  Future<void> handleCommand(String commandLine, FtpSession session) async {
    List<String> parts = commandLine.split(' ');
    String command = parts[0].toUpperCase();
    String argument = parts.length > 1 ? parts.sublist(1).join(' ').trim() : '';

    logger.logCommand(command, argument);

    switch (command) {
      case 'USER':
        handleUser(argument, session);
        break;
      case 'PASS':
        handlePass(argument, session);
        break;
      case 'QUIT':
        await handleQuit(session);
        break;
      case 'PASV':
        await handlePasv(session);
        break;
      case 'PORT':
        await handlePort(argument, session);
        break;
      case 'LIST':
      case 'NLST':
        await handleList(argument, session);
        break;
      case 'RETR':
        await handleRetr(argument, session);
        break;
      case 'STOR':
        await handleStor(argument, session);
        break;
      case 'CWD':
        handleCwd(argument, session);
        break;
      case 'CDUP':
        handleCdup(session);
        break;
      case 'MKD':
      case 'XMKD':
        await handleMkd(argument, session);
        break;
      case 'RMD':
      case 'XRMD':
        await handleRmd(argument, session);
        break;
      case 'DELE':
        await handleDele(argument, session);
        break;
      case 'SYST':
        handleSyst(session);
        break;
      case 'NOOP':
        handleNoop(session);
        break;
      case 'TYPE':
        handleType(argument, session);
        break;
      case 'SIZE':
        await handleSize(argument, session);
        break;
      case 'PWD':
      case 'XPWD':
        handleCurPath(session);
        break;
      case 'OPTS':
        handleOptions(argument, session);
        break;
      case 'FEAT':
        handleFeat(session);
        break;
      case 'EPSV':
        await handleEpsv(session);
        break;
      case 'ABOR':
        await handleAbort(session);
        break;
      case 'MLSD':
        await handleMlsd(argument, session);
        break;
      case 'MLST':
        await handleMlst(argument, session);
        break;
      case 'MDTM':
        await handleMdtm(argument, session);
        break;
      case 'MFMT':
        await handleMfmt(argument, session);
        break;
      case 'RNFR':
        await handleRnfr(argument, session);
        break;
      case 'RNTO':
        await handleRnto(argument, session);
        break;
      case 'RENAME':
        await handleRename(argument, session);
        break;
      default:
        session.sendResponse('502 Command not implemented $command $argument');
        break;
    }
  }

  void handleUser(String argument, FtpSession session) {
    session.cachedUsername = argument;
    session.isAuthenticated = false;
    session.sendResponse('331 Password required for $argument');
  }

  void handlePass(String argument, FtpSession session) {
    if ((session.username == null && session.password == null) ||
        (session.cachedUsername == session.username && argument == session.password)) {
      session.isAuthenticated = true;
      session.sendResponse('230 User logged in, proceed');
    } else {
      session.sendResponse('530 Not logged in');
    }
  }

  Future<void> handleQuit(FtpSession session) async {
    session.sendResponse('221 Service closing control connection');
    await session.controlSocket.close();
  }

  Future<void> handlePasv(FtpSession session) async {
    await session.enterPassiveMode();
  }

  Future<void> handlePort(String argument, FtpSession session) async {
    await session.enterActiveMode(argument);
  }

  Future<void> handleList(String argument, FtpSession session) async {
    await session.listDirectory(argument);
  }

  Future<void> handleRetr(String argument, FtpSession session) async {
    await session.retrieveFile(argument);
  }

  Future<void> handleMlsd(String argument, FtpSession session) async {
    await session.handleMlsd(argument, session);
  }

  Future<void> handleMlst(String argument, FtpSession session) async {
    await session.handleMlst(argument);
  }

  Future<void> handleMdtm(String argument, FtpSession session) async {
    session.handleMdtm(argument, session);
  }

  Future<void> handleMfmt(String argument, FtpSession session) async {
    await session.handleMfmt(argument, session);
  }

  Future<void> handleStor(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
    } else {
      await session.storeFile(argument);
    }
  }

  void handleCwd(String argument, FtpSession session) {
    session.changeDirectory(argument);
  }

  void handleCdup(FtpSession session) {
    session.changeToParentDirectory();
  }

  Future<void> handleMkd(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
    } else {
      await session.makeDirectory(argument);
    }
  }

  Future<void> handleRmd(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
    } else {
      await session.removeDirectory(argument);
    }
  }

  Future<void> handleDele(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
    } else {
      await session.deleteFile(argument);
    }
  }

  void handleSyst(FtpSession session) {
    session.sendResponse('215 UNIX Type: L8');
  }

  void handleNoop(FtpSession session) {
    session.sendResponse('200 NOOP command successful');
  }

  void handleType(String argument, FtpSession session) {
    if (argument == 'A' || argument == 'I') {
      session.sendResponse('200 Type set to $argument');
    } else {
      session.sendResponse('500 Syntax error, command unrecognized');
    }
  }

  Future<void> handleSize(String argument, FtpSession session) async {
    await session.fileSize(argument);
  }

  void handleCurPath(FtpSession session) {
    String currentPath = session.fileOperations.getCurrentDirectory();
    session.sendResponse('257 "$currentPath" is current directory');
  }

  void handleOptions(String argument, FtpSession session) {
    var args = argument.split(" ");
    var option = args[0].toUpperCase();
    switch (option) {
      case "UTF8":
        var mode = args[1].toUpperCase() == "ON";
        session.sendResponse("200 UTF8 mode ${mode ? 'enable' : 'disable'}");
        break;
      default:
        session.sendResponse('502 Command not implemented handleOptions');
        break;
    }
  }

  void handleFeat(FtpSession session) {
    const List<String> features = [
      '211-Features:',
      ' SIZE',
      ' MDTM',
      ' MFMT',
      ' MLSD',
      ' EPSV',
      ' PASV',
      ' UTF8',
      ' MLST modify*;size*;type*;',
      '211 End',
    ];

    session.sendMultiLineResponse(features);
  }

  Future<void> handleEpsv(FtpSession session) async {
    await session.enterExtendedPassiveMode();
  }

  Future<void> handleAbort(FtpSession session) async {
    await session.abortTransfer();
  }

  Future<void> handleRnfr(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
      return;
    }

    if (argument.isEmpty) {
      session.sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    // Check if the file/directory exists
    if (!session.fileOperations.exists(argument)) {
      session.sendResponse('550 File not found');
      return;
    }

    // Store the source path for the rename operation
    session.pendingRenameFrom = argument;
    session.sendResponse('350 Requested file action pending further information');
  }

  Future<void> handleRnto(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
      return;
    }

    if (argument.isEmpty) {
      session.sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    // Check if RNFR was called first
    if (session.pendingRenameFrom == null) {
      session.sendResponse('503 Bad sequence of commands');
      return;
    }

    try {
      // Perform the rename operation
      await session.renameFileOrDirectory(session.pendingRenameFrom!, argument);
    } catch (e) {
      // Clear the pending rename state on error
      session.pendingRenameFrom = null;
      rethrow;
    }
  }

  Future<void> handleRename(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
      return;
    }

    if (argument.isEmpty) {
      session.sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    // Parse the rename command arguments (oldname newname)
    final parts = argument.split(' ');
    if (parts.length != 2) {
      session.sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    final oldName = parts[0];
    final newName = parts[1];

    // Check if the file/directory exists
    if (!session.fileOperations.exists(oldName)) {
      session.sendResponse('550 File not found');
      return;
    }

    try {
      // Perform the rename operation directly
      await session.renameFileOrDirectory(oldName, newName);
    } catch (e) {
      // Error handling is done in the session method
    }
  }
}
