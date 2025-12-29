import 'package:jhentai/pages/base/base_page_state.dart';

import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';

class DashboardPageState extends BasePageState {
  DashboardPageState() {
    searchConfig = SearchConfig.nonHOnly();
  }

  @override
  String get route => Routes.dashboard;

  LoadingState ranklistLoadingState = LoadingState.idle;
  LoadingState popularLoadingState = LoadingState.idle;

  List<Gallery> ranklistGallerys = List.empty(growable: true);
  List<Gallery> popularGallerys = List.empty(growable: true);
}
