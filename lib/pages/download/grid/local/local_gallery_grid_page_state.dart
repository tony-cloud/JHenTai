import 'package:jhentai/service/local_gallery_service.dart';

import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/grid/mixin/grid_download_page_state_mixin.dart';

class LocalGalleryGridPageState
    with Scroll2TopStateMixin, MultiSelectDownloadPageStateMixin, GridBasePageState {
  @override
  List<String> get allRootGroups => localGalleryService.rootDirectories;

  @override
  List<LocalGallery> galleryObjectsWithGroup(String groupName) {
    return localGalleryService.path2GalleryDir[groupName] ?? [];
  }
}
