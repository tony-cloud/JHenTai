enum DownloadCompletionFilter { all, finished, unfinished }

class DownloadFilter {
  final String keyword;
  final List<String> includeTags;
  final Set<String> selectedGroups;
  final DownloadCompletionFilter completion;

  const DownloadFilter({
    this.keyword = '',
    this.includeTags = const [],
    this.selectedGroups = const {},
    this.completion = DownloadCompletionFilter.all,
  });

  bool get hasTextQuery => keyword.trim().isNotEmpty || includeTags.isNotEmpty;

  bool get hasGroupConstraint => selectedGroups.isNotEmpty;

  bool get hasCompletionConstraint => completion != DownloadCompletionFilter.all;

  bool get isDefault => !hasTextQuery && !hasGroupConstraint && !hasCompletionConstraint;

  DownloadFilter copyWith({
    String? keyword,
    List<String>? includeTags,
    Set<String>? selectedGroups,
    DownloadCompletionFilter? completion,
  }) {
    return DownloadFilter(
      keyword: keyword ?? this.keyword,
      includeTags: includeTags ?? this.includeTags,
      selectedGroups: selectedGroups ?? this.selectedGroups,
      completion: completion ?? this.completion,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DownloadFilter &&
        keyword == other.keyword &&
        _listEquals(includeTags, other.includeTags) &&
        _setEquals(selectedGroups, other.selectedGroups) &&
        completion == other.completion;
  }

  @override
  int get hashCode => Object.hash(
        keyword,
        Object.hashAll(includeTags),
        Object.hashAll(selectedGroups),
        completion,
      );

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _setEquals(Set<String> a, Set<String> b) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (String value in a) {
      if (!b.contains(value)) {
        return false;
      }
    }
    return true;
  }
}
