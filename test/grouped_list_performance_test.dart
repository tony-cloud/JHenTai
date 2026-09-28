import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/widget/grouped_list.dart';

void main() {
  test('detached controllers do not block removal or group changes', () async {
    final controller = GroupedListController<String, int>();
    await controller.removeElement(1);
    controller.toggleGroup('group');
    expect(controller.isAttached, isFalse);
  });

  testWidgets('replacing a controller transfers the mounted list attachment', (tester) async {
    final oldController = GroupedListController<String, int>();
    final newController = GroupedListController<String, int>();
    Widget buildList(GroupedListController<String, int> controller) => MaterialApp(
          home: Scaffold(
            body: GroupedList<String, int>(
              groups: const {'group': false},
              elements: const [1],
              elementGroup: (_) => 'group',
              groupUniqueKey: (group) => group,
              elementUniqueKey: (element) => '$element',
              groupBuilder: (_, __, isOpen) => Text('open: $isOpen'),
              elementBuilder: (_, __, ___, ____) => const Text('row'),
              maxGalleryNum4Animation: 50,
              controller: controller,
            ),
          ),
        );

    await tester.pumpWidget(buildList(oldController));
    await tester.pumpWidget(buildList(newController));
    expect(oldController.isAttached, isFalse);
    expect(newController.isAttached, isTrue);
    newController.toggleGroup('group');
    await tester.pumpAndSettle();
    expect(find.text('open: true'), findsOneWidget);
    await oldController.removeElement(1);

    await tester.pumpWidget(const SizedBox());
    expect(newController.isAttached, isFalse);
    await newController.removeElement(1);
  });

  testWidgets('10K collapsed items build no rows; expanded items stay lazy',
      (tester) async {
    final controller = GroupedListController<String, int>();
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    int builtRows = 0;
    int groupLookups = 0;
    final elements = List.generate(10000, (index) => index);

    Widget buildList() => MaterialApp(
          home: Scaffold(
            body: GroupedList<String, int>(
              groups: const {'library': false},
              elements: elements,
              elementGroup: (_) {
                groupLookups++;
                return 'library';
              },
              groupUniqueKey: (group) => group,
              elementUniqueKey: (element) => '$element',
              groupBuilder: (_, group, isOpen) => SizedBox(
                height: 40,
                child: Text('$group $isOpen'),
              ),
              elementBuilder: (_, __, element, ___) {
                builtRows++;
                return SizedBox(height: 50, child: Text('row $element'));
              },
              maxGalleryNum4Animation: 50,
              openElementExtent: 50,
              controller: controller,
              scrollController: scrollController,
            ),
          ),
        );

    await tester.pumpWidget(buildList());
    expect(builtRows, 0);
    expect(groupLookups, elements.length);

    controller.toggleGroup('library');
    await tester.pumpAndSettle();
    expect(find.text('library true'), findsOneWidget);
    expect(builtRows, lessThan(30));
    expect(groupLookups, elements.length,
        reason: 'toggling reuses the group index');

    builtRows = 0;
    scrollController.jumpTo(400000);
    await tester.pumpAndSettle();
    expect(builtRows, lessThan(30),
        reason: 'jumping must not build intervening rows');

    // Removing an offscreen row must not wait for an animation on a row that
    // has no widget. The caller can then delete it from the download service.
    bool removed = false;
    controller.removeElement(1).then((_) => removed = true);
    await tester.pump();
    expect(removed, isTrue);

    builtRows = 0;
    elements.insert(0, -1);
    await tester.pumpWidget(buildList());
    expect(builtRows, 0);
    expect(
        groupLookups, 20002); // Two snapshots plus the removal's group lookup.
    expect(tester.takeException(), isNull);
  });

  testWidgets('small groups still finish animated removal', (tester) async {
    final controller = GroupedListController<String, int>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GroupedList<String, int>(
          groups: const {'group': true},
          elements: const [1, 2],
          elementGroup: (_) => 'group',
          groupUniqueKey: (group) => group,
          elementUniqueKey: (element) => '$element',
          groupBuilder: (_, __, ___) => const SizedBox(height: 40),
          elementBuilder: (_, __, element, ___) => SizedBox(
            height: 50,
            child: Text('row $element'),
          ),
          maxGalleryNum4Animation: 50,
          controller: controller,
        ),
      ),
    ));

    bool removed = false;
    controller.removeElement(1).then((_) => removed = true);
    await tester.pump();
    expect(removed, isFalse);
    await tester.pumpAndSettle();
    expect(removed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inserting a row preserves existing row state', (tester) async {
    final elements = List.generate(100, (index) => index);
    Widget buildList() => MaterialApp(
          home: Scaffold(
            body: GroupedList<String, int>(
              groups: const {'group': true},
              elements: elements,
              elementGroup: (_) => 'group',
              groupUniqueKey: (group) => group,
              elementUniqueKey: (element) => '$element',
              groupBuilder: (_, __, ___) => const SizedBox(height: 40),
              elementBuilder: (_, __, element, ___) =>
                  _StatefulRow(value: element),
              maxGalleryNum4Animation: 50,
              openElementExtent: 50,
            ),
          ),
        );

    await tester.pumpWidget(buildList());
    final state = tester.state(find.byType(_StatefulRow).first);
    elements.insert(0, -1);
    await tester.pumpWidget(buildList());
    expect(find.text('0 initially 0'), findsOneWidget);
    expect(tester.state(find.widgetWithText(_StatefulRow, '0 initially 0')),
        same(state));
    expect(find.text('-1 initially -1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _StatefulRow extends StatefulWidget {
  const _StatefulRow({required this.value});
  final int value;

  @override
  State<_StatefulRow> createState() => _StatefulRowState();
}

class _StatefulRowState extends State<_StatefulRow> {
  late final int initialValue = widget.value;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 50,
        child: Text('${widget.value} initially $initialValue'),
      );
}
