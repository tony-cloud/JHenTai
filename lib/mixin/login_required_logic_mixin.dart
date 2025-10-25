import 'package:get/get.dart';

import '../setting/user_setting.dart';
import '../utils/toast_util.dart';

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
