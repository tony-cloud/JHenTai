import '../../model/search_config.dart';
import '../../routes/routes.dart';
import '../base/base_page_state.dart';

class WatchedPageState extends BasePageState {
  WatchedPageState() {
    searchConfig = SearchConfig(searchType: SearchType.watched);
  }

  @override
  String get route => Routes.watched;
}
