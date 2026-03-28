class RPCConsts {
  static const String rpcEndpoint = '/rpc';
  static const String rpcMediaEndpoint = '/rpc/media';
  static const String rpcDownloadedGalleryImageEndpoint = '/rpc/downloaded-gallery-image';
  static const String rpcDownloadedGalleryThumbnailEndpoint = '/rpc/downloaded-gallery-thumbnail';

  const RPCConsts._();
}

class RPCMethods {
  static const String systemHealth = 'system.health';
  static const String systemCapabilities = 'system.capabilities';
  static const String systemFetchUrl = 'system.fetchUrl';
  static const String galleryPage = 'gallery.page';
  static const String galleryDetail = 'gallery.detail';
  static const String galleryMetadata = 'gallery.metadata';
  static const String galleryMetadatas = 'gallery.metadatas';
  static const String galleryImagePage = 'gallery.imagePage';
  static const String forumUser = 'forum.user';
  static const String settingPage = 'setting.page';
  static const String favoritePopup = 'favorite.popup';
  static const String favoritePage = 'favorite.page';
  static const String favoriteSort = 'favorite.sort';
  static const String favoriteAdd = 'favorite.add';
  static const String favoriteRemove = 'favorite.remove';
  static const String torrentPage = 'torrent.page';
  static const String myTagsPage = 'myTags.page';
  static const String myTagsAdd = 'myTags.add';
  static const String myTagsDelete = 'myTags.delete';
  static const String myTagsUpdateSet = 'myTags.updateSet';
  static const String commentVote = 'comment.vote';
  static const String commentSend = 'comment.send';
  static const String commentUpdate = 'comment.update';
  static const String ratingSubmit = 'rating.submit';
  static const String tagSuggestion = 'tag.suggestion';
  static const String lookupImage = 'lookup.image';
  static const String archiveUnlock = 'archive.unlock';
  static const String archiveCancel = 'archive.cancel';
  static const String archiveHathDownload = 'archive.hathDownload';
  static const String downloadGalleryList = 'download.galleryList';
  static const String downloadGalleryImages = 'download.galleryImages';
  static const String historyPage = 'history.page';
  static const String historyRecord = 'history.record';
  static const String historyDelete = 'history.delete';
  static const String historyDeleteAll = 'history.deleteAll';
  static const String newsEvent = 'news.event';
  static const String authLogin = 'auth.login';
  static const String authSetCookie = 'auth.setCookie';
  static const String downloadGalleryStart = 'download.gallery.start';
  static const String downloadGalleryPause = 'download.gallery.pause';
  static const String downloadGalleryResume = 'download.gallery.resume';
  static const String downloadGalleryDelete = 'download.gallery.delete';
  static const String downloadGalleryAssignPriority = 'download.gallery.assignPriority';
  static const String downloadGalleryPauseAll = 'download.gallery.pauseAll';
  static const String downloadGalleryResumeAll = 'download.gallery.resumeAll';

  const RPCMethods._();
}

class RPCCapabilities {
  static const String gallerySearch = 'gallery.search';
  static const String galleryDetail = 'gallery.detail';
  static const String galleryImage = 'gallery.image';
  static const String forumRead = 'forum.read';
  static const String settingRead = 'setting.read';
  static const String favoriteRead = 'favorite.read';
  static const String favoriteWrite = 'favorite.write';
  static const String commentWrite = 'comment.write';
  static const String ratingWrite = 'rating.write';
  static const String tagRead = 'tag.read';
  static const String tagWrite = 'tag.write';
  static const String lookupWrite = 'lookup.write';
  static const String torrentRead = 'torrent.read';
  static const String archiveWrite = 'archive.write';
  static const String downloadGalleryList = 'download.gallery.list';
  static const String downloadGalleryRead = 'download.gallery.read';
  static const String downloadGalleryThumbnail = 'download.gallery.thumbnail';
  static const String historyRead = 'history.read';
  static const String historyWrite = 'history.write';
  static const String newsEvent = 'news.event';
  static const String externalForward = 'external.forward';
  static const String archiveResolve = 'archive.resolve';
  static const String authLogin = 'auth.login';
  static const String downloadGalleryControl = 'download.gallery.control';

  const RPCCapabilities._();
}
