import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/widget/eh_wheel_speed_controller.dart';
import 'package:path/path.dart';

import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/utils/route_util.dart';

class LogListPage extends StatefulWidget {
  const LogListPage({super.key});

  @override
  State<LogListPage> createState() => _LogListPageState();
}

class _LogListPageState extends State<LogListPage> {
  List<File> logs = [];

  ScrollController scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    if (log.logDirPath != null) {
      Directory logDir = Directory(log.logDirPath!);
      if (logDir.existsSync()) {
        logs = logDir.listSync().whereType<File>().toList();
        logs.sort((a, b) => b.path.compareTo(a.path));
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    scrollController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('logList'.tr)),
      body: EHWheelSpeedController(
        controller: scrollController,
        child: ListView(
          controller: scrollController,
          children: logs
              .map(
                (log) => ListTile(
                    title: Text(basename(log.path)),
                    onTap: () => toRoute(Routes.log, arguments: log)),
              )
              .toList(),
        ).withListTileTheme(context).enableMouseDrag(withScrollBar: true),
      ),
    );
  }
}
