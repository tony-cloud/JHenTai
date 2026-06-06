import 'dart:collection';

import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_url.dart';

import 'package:jhentai/model/gallery_comment.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/gallery_tag.dart';
import 'package:jhentai/model/gallery_thumbnail.dart';

class GalleryDetail {
  GalleryUrl galleryUrl;
  String rawTitle;
  String? japaneseTitle;
  String category;
  GalleryImage cover;
  int pageCount;
  double rating;

  /// real rating, not the one we rated
  double realRating;
  bool hasRated;
  int ratingCount;
  int? favoriteTagIndex;
  String? favoriteTagName;

  int favoriteCount;
  String language;

  /// null for disowned gallery
  String? uploader;
  String publishTime;
  bool isExpunged;

  /// full tags: tags in Gallery may be incomplete
  LinkedHashMap<String, List<GalleryTag>> tags;

  String size;
  String torrentCount;
  String torrentPageUrl;
  String archivePageUrl;
  GalleryUrl? parentGalleryUrl;
  List<({GalleryUrl galleryUrl, String title, String updateTime})>? childrenGallerys;
  List<GalleryComment> comments;
  List<GalleryThumbnail> thumbnails;
  int thumbnailsPageCount;

  bool get isFavorite => favoriteTagIndex != null || favoriteTagName != null;

  GalleryUrl? get newVersionGalleryUrl {
    final List<({GalleryUrl galleryUrl, String title, String updateTime})>? children =
        childrenGallerys;
    if (children == null || children.isEmpty) {
      return null;
    }

    ({GalleryUrl galleryUrl, String title, String updateTime}) latest = children.first;
    for (final child in children.skip(1)) {
      if (_isChildNewer(child, latest)) {
        latest = child;
      }
    }

    return latest.galleryUrl;
  }

  bool _isChildNewer(
    ({GalleryUrl galleryUrl, String title, String updateTime}) candidate,
    ({GalleryUrl galleryUrl, String title, String updateTime}) current,
  ) {
    final DateTime? candidateTime = _parseChildUpdateTime(candidate.updateTime);
    final DateTime? currentTime = _parseChildUpdateTime(current.updateTime);

    if (candidateTime != null && currentTime != null) {
      final int timeResult = candidateTime.compareTo(currentTime);
      if (timeResult != 0) {
        return timeResult > 0;
      }
    } else if (candidateTime != null) {
      return true;
    } else if (currentTime != null) {
      return false;
    }

    return candidate.galleryUrl.gid > current.galleryUrl.gid;
  }

  DateTime? _parseChildUpdateTime(String updateTime) {
    if (updateTime.isEmpty) {
      return null;
    }

    return DateTime.tryParse(updateTime.replaceFirst(' ', 'T'));
  }

  GalleryDetail({
    required this.galleryUrl,
    required this.rawTitle,
    this.japaneseTitle,
    required this.category,
    required this.cover,
    required this.pageCount,
    required this.rating,
    required this.realRating,
    required this.hasRated,
    required this.ratingCount,
    this.favoriteTagIndex,
    this.favoriteTagName,
    required this.favoriteCount,
    required this.language,
    this.uploader,
    required this.publishTime,
    required this.isExpunged,
    required this.tags,
    required this.size,
    required this.torrentCount,
    required this.torrentPageUrl,
    required this.archivePageUrl,
    this.parentGalleryUrl,
    this.childrenGallerys,
    required this.comments,
    required this.thumbnails,
    required this.thumbnailsPageCount,
  });

  Gallery toGallery() {
    return Gallery(
      galleryUrl: galleryUrl,
      title: japaneseTitle ?? rawTitle,
      category: category,
      cover: cover,
      pageCount: pageCount,
      rating: rating,
      hasRated: hasRated,
      favoriteTagIndex: favoriteTagIndex,
      favoriteTagName: favoriteTagName,
      language: language,
      uploader: uploader,
      publishTime: publishTime,
      isExpunged: isExpunged,
      tags: tags,
    );
  }
}
