import 'package:jhentai/service/image_block_service.dart';

class QrBlockScanPlan {
  QrBlockScanPlan({
    required this.mode,
    required Iterable<int> indexes,
  }) : _indexes = _sortedUnique(indexes) {
    _positionByIndex = <int, int>{
      for (int i = 0; i < _indexes.length; i++) _indexes[i]: i,
    };
    _backwardPosition = _indexes.length - 1;
    _complete = _indexes.isEmpty;
  }

  final QrBlockMode mode;
  final List<int> _indexes;
  final Set<int> _qrIndexes = <int>{};
  late final Map<int, int> _positionByIndex;
  late int _backwardPosition;

  int _forwardPosition = 0;
  int? _firstQrPosition;
  int? _lastQrPosition;
  bool _complete = false;

  bool get isComplete => _complete;

  int? nextIndex() {
    if (_complete) {
      return null;
    }

    switch (mode) {
      case QrBlockMode.normal:
      case QrBlockMode.superRange:
        return _nextForwardIndex();
      case QrBlockMode.advanced:
        if (_firstQrPosition == null) {
          return _nextForwardIndex();
        }
        if (_backwardPosition <= _firstQrPosition!) {
          _complete = true;
          return null;
        }
        return _indexes[_backwardPosition];
    }
  }

  void recordResult(int index, {required bool hasQr}) {
    final int? position = _positionByIndex[index];
    if (position == null) {
      return;
    }

    switch (mode) {
      case QrBlockMode.normal:
        _recordNormalResult(index, position, hasQr: hasQr);
        return;
      case QrBlockMode.advanced:
        _recordAdvancedResult(position, hasQr: hasQr);
        return;
      case QrBlockMode.superRange:
        _recordSuperRangeResult(position, hasQr: hasQr);
        return;
    }
  }

  List<int> targetIndexes() {
    switch (mode) {
      case QrBlockMode.normal:
        return _sortedUnique(_qrIndexes);
      case QrBlockMode.advanced:
        final int? first = _firstQrPosition;
        if (first == null) {
          return const <int>[];
        }
        final int last = _lastQrPosition ?? first;
        return _indexes.sublist(first, last + 1);
      case QrBlockMode.superRange:
        final int? first = _firstQrPosition;
        if (first == null) {
          return const <int>[];
        }
        return _indexes.sublist(first);
    }
  }

  int? _nextForwardIndex() {
    if (_forwardPosition >= _indexes.length) {
      _complete = true;
      return null;
    }
    return _indexes[_forwardPosition];
  }

  void _recordNormalResult(int index, int position, {required bool hasQr}) {
    if (hasQr) {
      _qrIndexes.add(index);
    }
    _forwardPosition = position + 1;
    _complete = _forwardPosition >= _indexes.length;
  }

  void _recordAdvancedResult(int position, {required bool hasQr}) {
    if (_firstQrPosition == null) {
      if (hasQr) {
        _firstQrPosition = position;
        _lastQrPosition = position;
        _backwardPosition = _indexes.length - 1;
        _complete = _backwardPosition <= position;
        return;
      }

      _forwardPosition = position + 1;
      _complete = _forwardPosition >= _indexes.length;
      return;
    }

    if (hasQr) {
      _lastQrPosition = position;
      _complete = true;
      return;
    }

    _backwardPosition = position - 1;
    _complete = _backwardPosition <= _firstQrPosition!;
  }

  void _recordSuperRangeResult(int position, {required bool hasQr}) {
    if (hasQr) {
      _firstQrPosition = position;
      _complete = true;
      return;
    }

    _forwardPosition = position + 1;
    _complete = _forwardPosition >= _indexes.length;
  }

  static List<int> _sortedUnique(Iterable<int> indexes) {
    return indexes.toSet().toList()..sort();
  }
}
