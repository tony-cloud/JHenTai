import 'package:flutter/material.dart';
import 'package:jhentai/config/ui_config.dart';

class BlankPage extends StatelessWidget {
  const BlankPage({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: UIConfig.backGroundColor(context),
      child: Center(
        child: isDarkMode
            ? const SizedBox.shrink()
            : Text(
                'J',
                style: TextStyle(
                    color: UIConfig.jHentaiIconColor(context),
                    fontSize: 120,
                    fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}
