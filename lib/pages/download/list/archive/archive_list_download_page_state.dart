import 'dart:async';

import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_state_mixin.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/widget/grouped_list.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_state_mixin.dart';

class ArchiveListDownloadPageState
    with Scroll2TopStateMixin, MultiSelectDownloadPageStateMixin, ArchiveDownloadPageStateMixin {
  Set<String> displayGroups = {};
  Completer<void> displayGroupsCompleter = Completer<void>();

  final GroupedListController<String, ArchiveDownloadedData> groupedListController =
      GroupedListController<String, ArchiveDownloadedData>();
}
