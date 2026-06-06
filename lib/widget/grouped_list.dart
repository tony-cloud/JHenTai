import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/widget/fade_slide_widget.dart';

import 'package:jhentai/widget/eh_wheel_speed_controller.dart';

class GroupedListLogic extends GetxController {}

class GroupedList<G, E> extends StatefulWidget {
  final Map<G, bool> groups;
  final List<E> elements;

  final G Function(E element) elementGroup;
  final String Function(G group) groupUniqueKey;
  final String Function(E element) elementUniqueKey;
  final Widget Function(BuildContext context, G group, bool isOpen) groupBuilder;
  final Widget Function(BuildContext context, G group, E element, bool isOpen) elementBuilder;

  final int maxGalleryNum4Animation;

  /// If provided, open groups use a fixed-extent sliver for better jump performance.
  final double? openElementExtent;

  final ScrollController? scrollController;

  final GroupedListController? controller;

  const GroupedList({
    super.key,
    required this.groups,
    required this.elements,
    required this.elementGroup,
    required this.elementUniqueKey,
    required this.groupUniqueKey,
    required this.groupBuilder,
    required this.elementBuilder,
    required this.maxGalleryNum4Animation,
    this.openElementExtent,
    this.scrollController,
    this.controller,
  });

  @override
  State<GroupedList<G, E>> createState() => _GroupedListState<G, E>();
}

abstract class GroupedListDelegate<G, E> {
  Future<void> removeElement(E element);

  void toggleGroup(G group);
}

class _GroupedListState<G, E> extends State<GroupedList<G, E>>
    implements GroupedListDelegate<G, E> {
  late GroupedListLogic logic;

  late int maxGalleryNum4Animation;

  late ScrollController scrollController;

  late GroupedListController controller;

  final Map<G, bool> _groups = {};
  Map<G, List<E>> _group2Elements = {};

  final Map<Object, Completer<void>> _deletingElements = {};

  @override
  void initState() {
    super.initState();

    logic = GroupedListLogic();

    maxGalleryNum4Animation = widget.maxGalleryNum4Animation;

    _initGroupsAndElements(widget);

    if (widget.scrollController == null) {
      scrollController = ScrollController();
    } else {
      scrollController = widget.scrollController!;
    }

    if (widget.controller == null) {
      controller = GroupedListController();
    } else {
      controller = widget.controller!;
    }
    controller.attach(this);
  }

  @override
  void dispose() {
    logic.dispose();
    controller.detach(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GroupedList<G, E> oldWidget) {
    super.didUpdateWidget(oldWidget);

    maxGalleryNum4Animation = widget.maxGalleryNum4Animation;

    _initGroupsAndElements(widget);
  }

  @override
  Widget build(BuildContext context) {
    // return _buildInListView();

    return _buildInCustomScrollView(context);
  }

  EHWheelSpeedController _buildInCustomScrollView(BuildContext context) {
    return EHWheelSpeedController(
      controller: scrollController,
      child: CustomScrollView(
        scrollCacheExtent: ScrollCacheExtent.pixels(200),
        controller: scrollController,
        slivers: _buildSlivers(context),
      ),
    );
  }

  List<Widget> _buildSlivers(BuildContext context) {
    List<Widget> slivers = [];

    Map<G, List<E>> group2Elements = widget.elements.groupListsBy<G>((e) => widget.elementGroup(e));

    for (G group in _groups.keys) {
      slivers.add(_buildGroupSliver(context, group));

      if (group2Elements.containsKey(group)) {
        final bool isOpen = _groups[group] ?? false;
        slivers.add(_buildElementsSliver(context, group2Elements[group]!, group, isOpen));
      }
    }

    return slivers;
  }

  Widget _buildGroupSliver(BuildContext context, G group) {
    return SliverToBoxAdapter(
      child: _buildGroup(group, context),
    );
  }

  Widget _buildElementsSliver(BuildContext context, List<E> elements, G group, bool isOpen) {
    final SliverChildBuilderDelegate delegate = SliverChildBuilderDelegate(
      (context, index) {
        return _buildElement(
            context, elements[index], group, elements.length <= maxGalleryNum4Animation);
      },
      childCount: elements.length,
    );

    if (isOpen && widget.openElementExtent != null) {
      return SliverFixedExtentList(
        itemExtent: widget.openElementExtent!,
        delegate: delegate,
      );
    }

    return SliverList(delegate: delegate);
  }

  GetBuilder<GroupedListLogic> _buildGroup(G group, BuildContext context) {
    return GetBuilder<GroupedListLogic>(
      id: 'group::${widget.groupUniqueKey(group)}',
      global: false,
      init: logic,
      builder: (_) {
        bool isOpen = _groups[group] ?? false;
        return widget.groupBuilder(context, group, isOpen);
      },
    );
  }

  Widget _buildElement(BuildContext context, E element, G group, bool enableAnimation) {
    return GetBuilder<GroupedListLogic>(
      id: 'group::${widget.groupUniqueKey(group)}',
      global: false,
      init: logic,
      builder: (_) {
        return GetBuilder<GroupedListLogic>(
          id: 'element::${widget.elementUniqueKey(element)}',
          global: false,
          init: logic,
          builder: (_) {
            bool isOpen = _groups[group] ?? false;
            return FadeSlideWidget(
              key: ValueKey(widget.elementUniqueKey(element)),
              show: isOpen && !_deletingElements.containsKey(widget.elementUniqueKey(element)),
              enableOpacityTransition: enableAnimation,
              enableSlideTransition: enableAnimation,
              child: widget.elementBuilder(context, group, element, isOpen),
              afterAnimation: (bool show, bool isInit) {
                if (!show && !isInit) {
                  _deletingElements.remove(widget.elementUniqueKey(element))?.complete();
                }
              },
            );
          },
        );
      },
    );
  }

  @override
  Future<void> removeElement(E element) {
    Completer<void> completer = Completer();
    String elementKey = widget.elementUniqueKey(element);
    _deletingElements[elementKey] = completer;

    G group = widget.elementGroup(element);
    _group2Elements[group]!.remove(element);

    logic.update(['element::$elementKey']);
    return completer.future;
  }

  @override
  void toggleGroup(G group) {
    if (!_groups.containsKey(group)) {
      return;
    }
    setState(() {
      _groups[group] = !_groups[group]!;
    });
    logic.updateSafely(['group::${widget.groupUniqueKey(group)}']);
  }

  void _initGroupsAndElements(GroupedList<G, E> widget) {
    _groups.clear();
    _group2Elements.clear();

    _groups.addAll(widget.groups);
    _group2Elements = widget.elements.groupListsBy<G>((e) => widget.elementGroup(e));
  }
}

class GroupedListController<G, E> {
  bool get isAttached => _delegate != null;

  GroupedListDelegate<G, E>? _delegate;

  void attach(GroupedListDelegate<G, E> delegate) {
    _delegate = delegate;
  }

  void detach(GroupedListDelegate<G, E> delegate) {
    if (identical(_delegate, delegate)) {
      _delegate = null;
    }
  }

  Future<void> removeElement(E element) {
    assert(isAttached);

    return _delegate!.removeElement(element);
  }

  void toggleGroup(G group) {
    assert(isAttached);

    _delegate!.toggleGroup(group);
  }
}
