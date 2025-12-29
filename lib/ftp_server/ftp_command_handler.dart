import 'dart:async';
import 'dart:io';
import 'package:jhentai/ftp_server/ftp_session.dart';
import 'package:jhentai/ftp_server/server_type.dart';

typedef SiteCommandCallback = FutureOr<SiteCommandResult> Function(String args, FtpSession session);

class SiteCommandResult {
  const SiteCommandResult({required this.success, required this.message});

  final bool success;
  final String message;

  static SiteCommandResult ok([String message = '']) =>
      SiteCommandResult(success: true, message: message);

  static SiteCommandResult fail([String message = '']) =>
      SiteCommandResult(success: false, message: message);
}

class _SiteCommandRegistration {
  const _SiteCommandRegistration({required this.callback, required this.timeout});

  final SiteCommandCallback callback;
  final Duration timeout;
}

class FTPCommandHandler {
  final Socket controlSocket;

  static final Map<String, _SiteCommandRegistration> _siteCommands =
      <String, _SiteCommandRegistration>{};

  FTPCommandHandler(this.controlSocket);

  static void registerSiteCommand(
    String name,
    SiteCommandCallback callback, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) {
      throw ArgumentError('SITE command name must be a single token');
    }
    _siteCommands[trimmed.toUpperCase()] = _SiteCommandRegistration(
      callback: callback,
      timeout: timeout,
    );
  }

  static void unregisterSiteCommand(String name) {
    _siteCommands.remove(name.trim().toUpperCase());
  }

  static void clearSiteCommands() {
    _siteCommands.clear();
  }

  Future<void> handleCommand(String commandLine, FtpSession session) async {
    List<String> parts = commandLine.split(' ');
    String command = parts[0].toUpperCase();
    String argument = parts.length > 1 ? parts.sublist(1).join(' ').trim() : '';

    session.logger.logCommand(command, argument); // Updated to use session.logger

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
      case 'APPE':
        await handleAppe(argument, session);
        break;
      case 'REST':
        handleRest(argument, session);
        break;
      case 'CLNT':
        handleClnt(argument, session);
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
      case 'HELP':
        await handleHelp(argument, session);
        break;
      case 'TYPE':
        handleType(argument, session);
        break;
      case 'MODE':
        handleMode(argument, session);
        break;
      case 'STRU':
        handleStru(argument, session);
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
      case 'STAT':
        await handleStat(argument, session);
        break;
      case 'SITE':
        await handleSite(argument, session);
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
        session.logger
            .warning('Unsupported command: $commandLine'); // Updated to use session.logger
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
      session.logger.warning(
          'Authentication failed for user: ${session.cachedUsername}'); // Updated to use session.logger
    }
  }

  Future<void> handleQuit(FtpSession session) async {
    session.sendResponse('221 Service closing control connection');
    session.logger.info('Client disconnected: ${session.controlSocket.remoteAddress.address}'
        ':${session.controlSocket.remotePort}');
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

  Future<void> handleAppe(String argument, FtpSession session) async {
    if (session.serverType == ServerType.readOnly) {
      session.sendResponse('550 Command not allowed in read-only mode');
    } else {
      await session.appendFile(argument);
    }
  }

  void handleMode(String argument, FtpSession session) {
    session.handleMode(argument);
  }

  void handleStru(String argument, FtpSession session) {
    session.handleStru(argument);
  }

  Future<void> handleStat(String argument, FtpSession session) async {
    await session.handleStat(argument);
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

  Future<void> handleHelp(String argument, FtpSession session) async {
    final String topic = argument.trim().toUpperCase();
    if (topic.isNotEmpty && topic != 'SITE') {
      session.sendResponse('502 HELP for $topic not implemented');
      return;
    }

    final List<String> lines = <String>[
      '214-Commands supported:',
      '214 USER PASS QUIT',
      '214 PASV EPSV PORT',
      '214 LIST NLST MLSD MLST',
      '214 RETR STOR APPE REST',
      '214 RNFR RNTO RENAME',
      '214 CWD CDUP MKD RMD DELE',
      '214 SIZE PWD XPWD SYST NOOP TYPE',
      '214  MODE STRU STAT',
      '214 HELP',
    ];
    lines.add('214 End');

    if (topic == 'SITE') {
      lines.clear();
      if (_siteCommands.isEmpty) {
        lines.add('502 No SITE subcommands registered');
      } else {
        lines.add('214-SITE commands:');
        final List<String> names = _siteCommands.keys.toList()..sort();
        lines.add(names.join(' '));
        lines.add('214 End');
      }
    }
    session.sendMultiLineResponse(lines);
  }

  Future<void> handleSite(String argument, FtpSession session) async {
    final String trimmed = argument.trim();
    if (trimmed.isEmpty) {
      session.sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    final List<String> parts = trimmed.split(RegExp(r'\s+'));
    final String subcommand = parts.first.toUpperCase();
    final String args =
        trimmed.length > parts.first.length ? trimmed.substring(parts.first.length).trimLeft() : '';

    final _SiteCommandRegistration? registration = _siteCommands[subcommand];
    if (registration == null) {
      session.sendResponse('500 SITE command not understood');
      return;
    }

    try {
      final Future<SiteCommandResult> future = Future<SiteCommandResult>.sync(
        () => registration.callback(args, session),
      ).then((value) => value);

      final SiteCommandResult result = await future.timeout(registration.timeout);
      final String message = result.message.isEmpty
          ? (result.success ? 'SITE $subcommand ok' : 'SITE $subcommand failed')
          : result.message;

      session.sendResponse(result.success ? '200 $message' : '550 $message');
    } on TimeoutException {
      session.sendResponse('550 SITE $subcommand timed out');
    } catch (e) {
      session.sendResponse('550 SITE $subcommand failed: $e');
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
        session.sendResponse('502 Command not implemented handleOptions $argument');
        session.logger
            .warning('Unsupported OPTS command: $argument'); // Updated to use session.logger
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
      ' REST STREAM',
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

  void handleClnt(String argument, FtpSession session) {
    // Client name (RFC 959 extension). Some clients (e.g. QNAP HBS) require this.
    session.clientName = argument.isEmpty ? null : argument;
    session.sendResponse('200 CLNT command successful');
  }

  void handleRest(String argument, FtpSession session) {
    final String trimmed = argument.trim();
    final int? offset = int.tryParse(trimmed);
    if (trimmed.isEmpty || offset == null || offset < 0) {
      session.sendResponse('501 Syntax error in parameters or arguments');
      return;
    }

    session.restartOffset = offset;
    session.sendResponse('350 Restarting at $offset. Send RETR or STOR to initiate transfer.');
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
