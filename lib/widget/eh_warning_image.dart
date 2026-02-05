import 'package:flutter/material.dart';

import 'package:blur/blur.dart';
import 'package:extended_image/extended_image.dart';
import 'package:get/get.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/utils/domain_fronting_util.dart';

class EHWarningImage extends StatefulWidget {
  final bool warning;
  final String src;

  const EHWarningImage({super.key, required this.warning, required this.src});

  @override
  State<EHWarningImage> createState() => _EHWarningImageState();
}

class _EHWarningImageState extends State<EHWarningImage> {
  bool warning = false;

  @override
  void initState() {
    warning = widget.warning;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final DomainFrontingResult fronting = DomainFrontingUtil.build(widget.src);

    return GestureDetector(
      onTap: () {
        if (warning) {
          setState(() => warning = false);
        }
      },
      child: warning
          ? Blur(
              blur: 15,
              blurColor: UIConfig.warningImageBlurColor,
              colorOpacity: 0.75,
              overlay: Center(
                child: Text(
                  'warningImageHint'.tr,
                  style: const TextStyle(
                      fontSize: 12, height: 2, color: UIConfig.warningImageTextColor),
                  textAlign: TextAlign.center,
                ),
              ),
              child: ExtendedImage.network(
                fronting.url,
                headers: fronting.headers,
              ),
            )
          : ExtendedImage.network(
              fronting.url,
              headers: fronting.headers,
            ),
    );
  }
}
