import 'package:flutter/material.dart';

class EHCommentScoreDetailsDialog extends StatelessWidget {
  final List<String> scoreDetails;

  const EHCommentScoreDetailsDialog({super.key, required this.scoreDetails});

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      children: scoreDetails
          .map(
            (detail) => Center(
              child: Text(detail),
            ),
          )
          .toList(),
    );
  }
}
