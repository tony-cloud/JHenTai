import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/setting/preference_setting.dart';

class NewSearchArgument {
  final String? keyword;
  final SearchBehaviour? keywordSearchBehaviour;

  final SearchConfig? rewriteSearchConfig;

  const NewSearchArgument({
    this.keyword,
    this.keywordSearchBehaviour,
    this.rewriteSearchConfig,
  }) : assert((keyword != null && keywordSearchBehaviour != null) || rewriteSearchConfig != null);
}
