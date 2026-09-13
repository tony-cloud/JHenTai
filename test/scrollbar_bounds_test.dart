import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/config/ui_config.dart';

void main() {
  for (final explicitBehavior in [false, true]) {
    testWidgets(
        'scrollbar stays in bounds (explicit behavior: $explicitBehavior)',
        (tester) async {
      final controller = ScrollController(initialScrollOffset: 1500);
      addTearDown(controller.dispose);
      int refreshCount = 0;
      await _pumpScrollView(tester, controller, () async => refreshCount++,
          explicitBehavior: explicitBehavior);

      final offsets = <double>[];
      controller.addListener(() => offsets.add(controller.offset));
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        controller.jumpTo(1500);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final thumb = _thumbPosition(tester);
        final gesture = await tester.startGesture(thumb, kind: kind);
        await tester.pump(const Duration(milliseconds: 150));
        await gesture.moveTo(Offset(thumb.dx, -300));
        await tester.pump();
        expect(controller.offset, controller.position.minScrollExtent);
        expect(refreshCount, 0);

        await gesture.moveTo(Offset(thumb.dx, 900));
        await tester.pump();
        expect(controller.offset, controller.position.maxScrollExtent);
        await gesture.up();
        await tester.pumpAndSettle();
      }

      expect(
          offsets,
          everyElement(inInclusiveRange(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          )));
      expect(refreshCount, 0);
    }, variant: TargetPlatformVariant.all());
  }

  testWidgets('releasing a moving scrollbar does not fling the content',
      (tester) async {
    final controller = ScrollController(initialScrollOffset: 1500);
    addTearDown(controller.dispose);
    int refreshCount = 0;
    await _pumpScrollView(tester, controller, () async => refreshCount++);

    for (final distance in [-60.0, 60.0]) {
      controller.jumpTo(1500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.flingFrom(_thumbPosition(tester), Offset(0, distance), 2000);
      final releaseOffset = controller.offset;
      expect(releaseOffset, distance < 0 ? lessThan(1500) : greaterThan(1500));
      await tester.pumpAndSettle();
      expect(controller.offset, releaseOffset);
    }
    expect(refreshCount, 0);
  }, variant: TargetPlatformVariant.all());

  testWidgets(
      'content keeps its platform behavior and can still pull to refresh',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    int refreshCount = 0;
    await _pumpScrollView(tester, controller, () async => refreshCount++);

    final contentContext = tester.element(find.text('Row 0'));
    expect(ScrollConfiguration.of(contentContext).getPlatform(contentContext),
        Theme.of(contentContext).platform);

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
  }, variant: TargetPlatformVariant.all());
}

Future<void> _pumpScrollView(
  WidgetTester tester,
  ScrollController controller,
  RefreshCallback onRefresh, {
  bool explicitBehavior = true,
}) async {
  await tester.pumpWidget(MaterialApp(
    scrollBehavior: UIConfig.scrollBehaviourWithScrollBar,
    home: Scaffold(
      body: CustomScrollView(
        controller: controller,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        scrollBehavior: explicitBehavior
            ? UIConfig.scrollBehaviourWithScrollBarWithMouse
            : null,
        slivers: [
          CupertinoSliverRefreshControl(onRefresh: onRefresh),
          SliverFixedExtentList(
            itemExtent: 50,
            delegate: SliverChildBuilderDelegate(
              (_, index) => Text('Row $index'),
              childCount: 100,
            ),
          ),
        ],
      ),
    ),
  ));
  // A scroll notification makes the adaptive scrollbar visible and draggable.
  controller.jumpTo(controller.offset + 1);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Offset _thumbPosition(WidgetTester tester) {
  final finder = find.byWidgetPredicate((widget) =>
      widget is CustomPaint && widget.foregroundPainter is ScrollbarPainter);
  final painter =
      tester.widget<CustomPaint>(finder).foregroundPainter! as ScrollbarPainter;
  final rect = tester.getRect(finder);
  for (double y = 0; y < rect.height; y++) {
    final local = Offset(rect.width - 5, y);
    if (painter.hitTestOnlyThumbInteractive(local, PointerDeviceKind.mouse)) {
      return rect.topLeft + local + const Offset(0, 5);
    }
  }
  throw StateError('No visible scrollbar thumb');
}
