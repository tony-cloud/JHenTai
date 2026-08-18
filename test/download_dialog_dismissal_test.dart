import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/utils/route_util.dart';

void main() {
  testWidgets(
      'confirmed dialog result is released after its dismissal transition',
      (WidgetTester tester) async {
    final Completer<String?> dialogResult = Completer<String?>();
    bool operationStarted = false;
    String? receivedResult;

    final Future<void> operation =
        waitForGetDialogDismissal(dialogResult.future).then((result) {
      receivedResult = result;
      operationStarted = true;
    });

    dialogResult.complete('group');
    await tester.pump();
    expect(operationStarted, isFalse);

    await tester.pump(
        Get.defaultDialogTransitionDuration - const Duration(milliseconds: 1));
    expect(operationStarted, isFalse);

    await tester.pump(const Duration(milliseconds: 1));
    await operation;
    expect(operationStarted, isTrue);
    expect(receivedResult, 'group');
  });

  testWidgets('cancelled dialog result returns without an animation delay',
      (WidgetTester tester) async {
    bool completed = false;
    String? receivedResult = 'not-null';
    final Future<void> operation =
        waitForGetDialogDismissal(Future<String?>.value()).then((result) {
      receivedResult = result;
      completed = true;
    });

    await tester.pump();
    await operation;
    expect(completed, isTrue);
    expect(receivedResult, isNull);
  });
}
