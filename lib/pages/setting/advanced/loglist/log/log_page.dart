import 'dart:async';
import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/utils/screen_size_util.dart';
import 'package:jhentai/utils/string_uril.dart';
import 'package:path/path.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../../utils/toast_util.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  late final File log;
  String logText = '';
  Timer? _refreshTimer;
  DateTime? _lastModified;

  @override
  void initState() {
    super.initState();

    log = Get.arguments;
    unawaited(_loadLog(initial: true));
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_loadLog());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(basename(log.path)),
        centerTitle: true,
        elevation: 1,
        titleTextStyle:
            Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        actions: [
          if (!GetPlatform.isDesktop)
            IconButton(onPressed: _shareLog, icon: const Icon(Icons.share)),
          IconButton(onPressed: _copyLog, icon: const Icon(Icons.copy)),
        ],
      ),
      body: SizedBox.expand(
        child: SelectableText(
          logText,
          scrollPhysics: const ClampingScrollPhysics(),
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            fontFamily: Platform.isAndroid ? 'monospace' : 'PingFang HK',
          ),
        ),
      ).marginSymmetric(horizontal: 4),
    );
  }

  void _shareLog() {
    SharePlus.instance.share(
      ShareParams(
        files: [XFile(log.path)],
        text: basename(log.path),
        sharePositionOrigin: Rect.fromLTWH(0, 0, fullScreenWidth, screenHeight * 2 / 3),
      ),
    );
  }

  Future<void> _copyLog() async {
    if (isEmptyOrNull(logText)) {
      return;
    }
    await FlutterClipboard.copy(logText);
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _loadLog({bool initial = false}) async {
    try {
      if (!await log.exists()) {
        if (initial && mounted) {
          setState(() {
            logText = '';
            _lastModified = null;
          });
        }
        return;
      }

      final DateTime latestModified = await log.lastModified();
      if (!initial && _lastModified != null && !latestModified.isAfter(_lastModified!)) {
        return;
      }

      final String content = await log.readAsString();
      if (!mounted) {
        return;
      }

      setState(() {
        logText = content;
        _lastModified = latestModified;
      });
    } on Exception {
      // ignore intermittent read issues (e.g., file rotation)
    }
  }
}
