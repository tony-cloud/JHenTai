import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';

import 'package:jhentai/model/gallery_metadata.dart';

class DetailsPageState with Scroll2TopStateMixin {
  /// initial param
  late GalleryUrl galleryUrl;

  /// initial param
  /// may be null if we don't enter detail page from gallery list
  /// may be updated after we get the gallery details
  Gallery? gallery;

  GalleryDetail? galleryDetails;

  /// used for rating
  String? apikey;

  /// If the gallery is deleted due to copyright, we use metadata to render page
  GalleryMetadata? galleryMetadata;
  String? copyRighter;

  int nextPageIndexToLoadThumbnails = 1;
  LoadingState loadingState = LoadingState.idle;
  LoadingState loadingThumbnailsState = LoadingState.idle;
  LoadingState favoriteState = LoadingState.idle;
  LoadingState ratingState = LoadingState.idle;

  String? errorMessage;
}
