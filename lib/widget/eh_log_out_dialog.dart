import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';

import '../network/eh_request.dart';
import '../utils/route_util.dart';

class LogoutDialog extends StatelessWidget {
  const LogoutDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text('${'logout'.tr} ?'),
      actions: [
        CupertinoDialogAction(onPressed: backRoute, child: Text('cancel'.tr)),
        CupertinoDialogAction(
          child: Text('OK'.tr, style: TextStyle(color: UIConfig.alertColor(context))),
          onPressed: () async {
            await ehRequest.requestLogout();
            backRoute();
          },
        ),
      ],
    );
  }
}
