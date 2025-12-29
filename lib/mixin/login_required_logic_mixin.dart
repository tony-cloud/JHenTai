import 'package:get/get.dart';

import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/toast_util.dart';

mixin LoginRequiredMixin {
  bool checkLogin() {
    if (!userSetting.hasLoggedIn()) {
      showLoginToast();
      return false;
    }

    return true;
  }

  void showLoginToast() {
    toast('needLoginToOperate'.tr);
  }
}
