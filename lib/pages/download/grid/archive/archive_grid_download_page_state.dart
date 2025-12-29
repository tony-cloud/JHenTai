import 'package:jhentai/service/archive_download_service.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/grid/mixin/grid_download_page_state_mixin.dart';

class ArchiveGridDownloadPageState
    with
        Scroll2TopStateMixin,
        MultiSelectDownloadPageStateMixin,
        ArchiveDownloadPageStateMixin,
        GridBasePageState {
  @override
  List<String> get allRootGroups => archiveDownloadService.allGroups;

  @override
  List<ArchiveDownloadedData> galleryObjectsWithGroup(String groupName) => archiveDownloadService
      .archives
      .where(
          (archive) => archiveDownloadService.archiveDownloadInfos[archive.gid]?.group == groupName)
      .toList();
}
