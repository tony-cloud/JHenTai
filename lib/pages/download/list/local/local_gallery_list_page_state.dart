import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';

import 'package:jhentai/service/local_gallery_service.dart';

class LocalGalleryListPageState with Scroll2TopStateMixin {
  String currentPath = LocalGalleryService.rootPath;

  final Set<String> removedGalleryTitles = {};
}
