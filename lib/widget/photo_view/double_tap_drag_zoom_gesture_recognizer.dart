// Copyright (c) 2018-present, fluttercandies & contributors.
// Modifications copyright (c) 2025, JHenTai contributors.
//
// This file derives from the open source project "photo_view"
// released under the MIT license. The original source can be
// obtained at https://github.com/BaseflowIT/flutter_photo_view.
// The implementation here adapts the double-tap plus drag gesture
// recognizer so it can be embedded directly in the application
// without requiring a custom fork of the package.

import 'dart:async';

import 'package:flutter/gestures.dart';

/// Details emitted when a double-tap-and-drag interaction starts.
class TapDragZoomStartDetails {
  TapDragZoomStartDetails({
    this.focalPoint = Offset.zero,
    Offset? localPoint,
  }) : localPoint = localPoint ?? focalPoint;

  final Offset focalPoint;
  final Offset localPoint;

  @override
  String toString() => 'TapDragZoomStartDetails(focalPoint: $focalPoint, localPoint: $localPoint)';
}

/// Details emitted while the pointer is dragging after the second tap.
class TapDragZoomUpdateDetails {
  TapDragZoomUpdateDetails({
    this.focalPoint = Offset.zero,
    Offset? localPoint,
    this.pointDelta = Offset.zero,
  }) : localPoint = localPoint ?? focalPoint;

  final Offset focalPoint;
  final Offset localPoint;
  final Offset pointDelta;

  @override
  String toString() =>
      'TapDragZoomUpdateDetails(focalPoint: $focalPoint, localPoint: $localPoint, pointDelta: $pointDelta)';
}

/// Callback invoked when the second tap is held and the finger moves.
typedef GestureTapDragZoomStartCallback = void Function(
  TapDragZoomStartDetails details,
);
typedef GestureTapDragZoomUpdateCallback = void Function(
  TapDragZoomUpdateDetails details,
);
typedef GestureTapDragZoomEndCallback = void Function();

/// Recognises a sequence that starts with a double tap. If the second tap is
/// held down, drag updates are emitted so the caller can map the vertical drag
/// distance to a zoom level. The recogniser preserves the original double tap
/// gesture behaviour so callers can still react to regular double taps.
class DoubleTapDragZoomGestureRecognizer extends GestureRecognizer {
  DoubleTapDragZoomGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  GestureTapDownCallback? onDoubleTapDown;
  GestureDoubleTapCallback? onDoubleTap;
  GestureTapCancelCallback? onDoubleTapCancel;
  GestureTapDragZoomStartCallback? onZoomStart;
  GestureTapDragZoomUpdateCallback? onZoomUpdate;
  GestureTapDragZoomEndCallback? onZoomEnd;

  Timer? _doubleTapTimer;
  _TapTracker? _firstTap;
  final Map<int, _TapTracker> _trackers = <int, _TapTracker>{};

  bool _zooming = false;
  PointerMoveEvent? _lastMoveEvent;

  bool get _canEmitDoubleTap =>
      onDoubleTapDown != null || onDoubleTap != null || onDoubleTapCancel != null;

  bool get _canEmitTapDragZoom => onZoomStart != null || onZoomUpdate != null || onZoomEnd != null;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (!_canEmitDoubleTap && !_canEmitTapDragZoom) {
      return false;
    }
    final bool allowed = super.isPointerAllowed(event);
    if (!allowed) {
      _reset();
    }
    return allowed;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_zooming) {
      return;
    }

    if (_firstTap != null) {
      if (!_firstTap!.isWithinGlobalTolerance(event, kDoubleTapSlop)) {
        return;
      }
      if (!_firstTap!.hasElapsedMinTime() || !_firstTap!.hasSameButton(event)) {
        _reset();
        _trackTap(event);
        return;
      }
      _resolveSecondPointer(event);
    }
    _trackTap(event);
  }

  void _trackTap(PointerDownEvent event) {
    _stopDoubleTapTimer();
    final _TapTracker tracker = _TapTracker(
      event: event,
      entry: GestureBinding.instance.gestureArena.add(event.pointer, this),
      doubleTapMinTime: kDoubleTapMinTime,
      deviceGestureSettings: gestureSettings,
    );
    _trackers[event.pointer] = tracker;
    tracker.startTrackingPointer(_handleEvent, event.transform);
  }

  void _resolveSecondPointer(PointerDownEvent event) {
    _firstTap!.entry.resolve(GestureDisposition.accepted);
  }

  void _handleEvent(PointerEvent event) {
    final _TapTracker tracker = _trackers[event.pointer]!;
    if (event is PointerUpEvent) {
      if (_firstTap == null) {
        _registerFirstTap(tracker);
      } else if (_zooming) {
        _finishZoom(tracker);
      } else if (_canEmitDoubleTap) {
        _registerSecondTap(tracker);
      } else if (_canEmitTapDragZoom) {
        _reset();
        _registerFirstTap(tracker);
      }
    } else if (event is PointerMoveEvent) {
      if (_firstTap == null) {
        if (!tracker.isWithinGlobalTolerance(event, kDoubleTapTouchSlop)) {
          _reject(tracker);
        }
      } else if (_zooming) {
        _updateZoom(event);
      } else if (_canEmitTapDragZoom) {
        _beginZoom(tracker, event);
      } else {
        _reject(tracker);
      }
    } else if (event is PointerCancelEvent) {
      _reject(tracker);
    }
  }

  void _registerFirstTap(_TapTracker tracker) {
    _startDoubleTapTimer();
    GestureBinding.instance.gestureArena.hold(tracker.pointer);
    _freezeTracker(tracker);
    _trackers.remove(tracker.pointer);
    _clearTrackers();
    _firstTap = tracker;
  }

  void _registerSecondTap(_TapTracker tracker) {
    _firstTap!.entry.resolve(GestureDisposition.accepted);
    tracker.entry.resolve(GestureDisposition.accepted);
    _freezeTracker(tracker);
    _trackers.remove(tracker.pointer);
    _notifyDoubleTap();
    _reset();
  }

  void _beginZoom(_TapTracker tracker, PointerMoveEvent moveEvent) {
    _firstTap!.entry.resolve(GestureDisposition.accepted);
    tracker.entry.resolve(GestureDisposition.accepted);
    for (final _TapTracker other in _trackers.values.toList()) {
      if (other != tracker) {
        _reject(other);
      }
    }
    _notifyDoubleTapCancel();
    _trackers.clear();
    _zooming = true;
    _notifyZoomStart();
    _updateZoom(moveEvent);
  }

  void _updateZoom(PointerMoveEvent moveEvent) {
    if (!_zooming) {
      return;
    }
    _lastMoveEvent = moveEvent;
    if (onZoomUpdate != null) {
      final TapDragZoomUpdateDetails details = TapDragZoomUpdateDetails(
        focalPoint: moveEvent.position,
        localPoint: moveEvent.localPosition,
        pointDelta: _lastMoveEvent == null
            ? Offset.zero
            : moveEvent.localPosition - _lastMoveEvent!.localPosition,
      );
      invokeCallback<void>('onZoomUpdate', () => onZoomUpdate!(details));
    }
  }

  void _finishZoom(_TapTracker tracker) {
    _freezeTracker(tracker);
    _trackers.remove(tracker.pointer);
    _notifyZoomEnd();
    _reset();
  }

  void _notifyDoubleTapDown(PointerDownEvent event) {
    if (onDoubleTapDown == null) {
      return;
    }
    final TapDownDetails details = TapDownDetails(
      globalPosition: event.position,
      localPosition: event.localPosition,
      kind: getKindForPointer(event.pointer),
    );
    invokeCallback<void>('onDoubleTapDown', () => onDoubleTapDown!(details));
  }

  void _notifyDoubleTap() {
    if (onDoubleTap != null) {
      invokeCallback<void>('onDoubleTap', onDoubleTap!);
    }
  }

  void _notifyDoubleTapCancel() {
    if (onDoubleTapCancel != null) {
      invokeCallback<void>('onDoubleTapCancel', onDoubleTapCancel!);
    }
  }

  void _notifyZoomStart() {
    if (onZoomStart != null && _firstTap != null) {
      final TapDragZoomStartDetails details = TapDragZoomStartDetails(
        focalPoint: _firstTap!._initialGlobalPosition,
        localPoint: _firstTap!._initialLocalPosition,
      );
      invokeCallback<void>('onZoomStart', () => onZoomStart!(details));
    }
  }

  void _notifyZoomEnd() {
    if (onZoomEnd != null) {
      invokeCallback<void>('onZoomEnd', onZoomEnd!);
    }
  }

  void _reject(_TapTracker tracker) {
    _trackers.remove(tracker.pointer);
    tracker.entry.resolve(GestureDisposition.rejected);
    _freezeTracker(tracker);
    if (_firstTap != null) {
      if (tracker == _firstTap) {
        _reset();
      } else {
        _notifyDoubleTapCancel();
        if (_trackers.isEmpty) {
          _reset();
        }
      }
    }
  }

  @override
  void acceptGesture(int pointer) {
    // The logic resolves gestures manually; nothing to do.
  }

  @override
  void rejectGesture(int pointer) {
    final _TapTracker? tracker =
        _trackers[pointer] ?? (_firstTap?.pointer == pointer ? _firstTap : null);
    if (tracker != null) {
      _reject(tracker);
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void handlePrimaryPointer(PointerEvent event) {
    if (event is PointerDownEvent && _firstTap == null && _trackers.isEmpty) {
      _notifyDoubleTapDown(event);
    }
  }

  void _startDoubleTapTimer() {
    _doubleTapTimer ??= Timer(kDoubleTapTimeout, _reset);
  }

  void _stopDoubleTapTimer() {
    _doubleTapTimer?.cancel();
    _doubleTapTimer = null;
  }

  void _freezeTracker(_TapTracker tracker) {
    tracker.stopTrackingPointer(_handleEvent);
  }

  void _clearTrackers() {
    for (final _TapTracker tracker in _trackers.values) {
      _reject(tracker);
    }
    _trackers.clear();
  }

  void _reset() {
    _stopDoubleTapTimer();
    if (_firstTap != null) {
      final _TapTracker tracker = _firstTap!;
      _firstTap = null;
      _reject(tracker);
      GestureBinding.instance.gestureArena.release(tracker.pointer);
    }
    _clearTrackers();
    _zooming = false;
    _lastMoveEvent = null;
  }

  @override
  String get debugDescription => 'double tap and drag zoom';
}

class _TapTracker {
  _TapTracker({
    required PointerDownEvent event,
    required this.entry,
    required Duration doubleTapMinTime,
    required this.deviceGestureSettings,
  })  : pointer = event.pointer,
        _initialGlobalPosition = event.position,
        _initialLocalPosition = event.localPosition,
        initialButtons = event.buttons,
        _countdown = _Countdown(doubleTapMinTime);

  final int pointer;
  final GestureArenaEntry entry;
  final Offset _initialGlobalPosition;
  final Offset _initialLocalPosition;
  final int initialButtons;
  final DeviceGestureSettings? deviceGestureSettings;
  final _Countdown _countdown;

  bool _tracking = false;

  void startTrackingPointer(PointerRoute route, Matrix4? transform) {
    if (_tracking) {
      return;
    }
    _tracking = true;
    GestureBinding.instance.pointerRouter.addRoute(pointer, route, transform);
  }

  void stopTrackingPointer(PointerRoute route) {
    if (!_tracking) {
      return;
    }
    _tracking = false;
    GestureBinding.instance.pointerRouter.removeRoute(pointer, route);
  }

  bool isWithinGlobalTolerance(PointerEvent event, double tolerance) {
    final Offset offset = event.position - _initialGlobalPosition;
    return offset.distance <= tolerance;
  }

  bool hasElapsedMinTime() => _countdown.finished;

  bool hasSameButton(PointerDownEvent event) => event.buttons == initialButtons;
}

class _Countdown {
  _Countdown(Duration duration) {
    Timer(duration, _onTimeout);
  }

  bool _finished = false;

  bool get finished => _finished;

  void _onTimeout() {
    _finished = true;
  }
}
