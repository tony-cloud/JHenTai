class RPCConsts {
  static const String rpcEndpoint = '/rpc';
  static const String rpcMediaEndpoint = '/rpc/media';
  static const String rpcDownloadedGalleryImageEndpoint = '/rpc/downloaded-gallery-image';

  const RPCConsts._();
}

class RPCMethods {
  static const String systemHealth = 'system.health';
  static const String systemCapabilities = 'system.capabilities';
  static const String galleryPage = 'gallery.page';
  static const String galleryDetail = 'gallery.detail';
  static const String galleryMetadata = 'gallery.metadata';
  static const String galleryMetadatas = 'gallery.metadatas';
  static const String galleryImagePage = 'gallery.imagePage';
  static const String downloadGalleryList = 'download.galleryList';
  static const String downloadGalleryImages = 'download.galleryImages';
  static const String newsEvent = 'news.event';
  static const String authSetCookie = 'auth.setCookie';

  const RPCMethods._();
}

class RPCCapabilities {
  static const String gallerySearch = 'gallery.search';
  static const String galleryDetail = 'gallery.detail';
  static const String galleryImage = 'gallery.image';
  static const String downloadGalleryList = 'download.gallery.list';
  static const String downloadGalleryRead = 'download.gallery.read';
  static const String newsEvent = 'news.event';
  static const String archiveResolve = 'archive.resolve';

  const RPCCapabilities._();
}
