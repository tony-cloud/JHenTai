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
    final TextStyle baseStyle = TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.bold,
      fontFamily: Platform.isAndroid ? 'monospace' : 'PingFang HK',
      color: Theme.of(context).textTheme.bodyMedium?.color,
    );

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
        child: SelectableText.rich(
          TextSpan(children: _buildAnsiSpans(logText, baseStyle, context)),
          scrollPhysics: const ClampingScrollPhysics(),
          style: baseStyle,
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

  List<InlineSpan> _buildAnsiSpans(String text, TextStyle baseStyle, BuildContext context) {
    final Color defaultColor = baseStyle.color ?? Theme.of(context).colorScheme.onSurface;
    final RegExp ansiRegex = RegExp(r"\x1B\[(?<code>[0-9;]+)m");

    final List<InlineSpan> spans = [];
    int lastMatchEnd = 0;
    Color currentColor = defaultColor;

    for (final RegExpMatch match in ansiRegex.allMatches(text)) {
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(
          text: text.substring(lastMatchEnd, match.start),
          style: baseStyle.copyWith(color: currentColor),
        ));
      }

      final String codeGroup = match.namedGroup('code') ?? '';
      for (final String code in codeGroup.split(';')) {
        if (code.isEmpty) {
          continue;
        }
        final int? value = int.tryParse(code);
        if (value == null) {
          continue;
        }
        if (value == 0 || value == 39) {
          currentColor = defaultColor;
          continue;
        }

        final Color? mapped = _ansiColorForCode(value);
        if (mapped != null) {
          currentColor = mapped;
        }
      }

      lastMatchEnd = match.end;
    }

    if (lastMatchEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastMatchEnd),
        style: baseStyle.copyWith(color: currentColor),
      ));
    }

    return spans;
  }

  Color? _ansiColorForCode(int code) {
    switch (code) {
      case 30:
        return Colors.black;
      case 31:
        return Colors.red;
      case 32:
        return Colors.green;
      case 33:
        return Colors.yellow.shade700;
      case 34:
        return Colors.blue;
      case 35:
        return Colors.purple;
      case 36:
        return Colors.cyan;
      case 37:
        return Colors.grey.shade300;
      case 90:
        return Colors.grey;
      case 91:
        return Colors.redAccent;
      case 92:
        return Colors.lightGreen;
      case 93:
        return Colors.amber;
      case 94:
        return Colors.lightBlue;
      case 95:
        return Colors.pinkAccent;
      case 96:
        return Colors.cyanAccent;
      case 97:
        return Colors.white;
      default:
        return null;
    }
  }
}
