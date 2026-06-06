import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/service/image_block_service.dart';
import 'package:jhentai/service/qr_block_scan_plan.dart';

void main() {
  test('normal mode scans every index and targets only qr hits', () {
    final _PlanRun run = _runPlan(
      mode: QrBlockMode.normal,
      indexes: <int>[0, 1, 2, 3],
      qrIndexes: <int>{1, 3},
    );

    expect(run.scannedIndexes, <int>[0, 1, 2, 3]);
    expect(run.targetIndexes, <int>[1, 3]);
  });

  test('super range mode stops at first qr and targets through the end', () {
    final _PlanRun run = _runPlan(
      mode: QrBlockMode.superRange,
      indexes: <int>[0, 1, 2, 3, 4],
      qrIndexes: <int>{1, 4},
    );

    expect(run.scannedIndexes, <int>[0, 1]);
    expect(run.targetIndexes, <int>[1, 2, 3, 4]);
  });

  test('advanced mode scans forward to first qr then backward to last qr', () {
    final _PlanRun run = _runPlan(
      mode: QrBlockMode.advanced,
      indexes: <int>[0, 1, 2, 3, 4, 5],
      qrIndexes: <int>{1, 4},
    );

    expect(run.scannedIndexes, <int>[0, 1, 5, 4]);
    expect(run.targetIndexes, <int>[1, 2, 3, 4]);
  });

  test('advanced mode targets first qr only when no later qr exists', () {
    final _PlanRun run = _runPlan(
      mode: QrBlockMode.advanced,
      indexes: <int>[0, 1, 2, 3, 4, 5],
      qrIndexes: <int>{1},
    );

    expect(run.scannedIndexes, <int>[0, 1, 5, 4, 3, 2]);
    expect(run.targetIndexes, <int>[1]);
  });
}

_PlanRun _runPlan({
  required QrBlockMode mode,
  required List<int> indexes,
  required Set<int> qrIndexes,
}) {
  final QrBlockScanPlan plan = QrBlockScanPlan(mode: mode, indexes: indexes);
  final List<int> scannedIndexes = <int>[];

  while (!plan.isComplete) {
    final int? index = plan.nextIndex();
    if (index == null) {
      break;
    }

    scannedIndexes.add(index);
    plan.recordResult(index, hasQr: qrIndexes.contains(index));
  }

  return _PlanRun(
    scannedIndexes: scannedIndexes,
    targetIndexes: plan.targetIndexes(),
  );
}

class _PlanRun {
  const _PlanRun({required this.scannedIndexes, required this.targetIndexes});

  final List<int> scannedIndexes;
  final List<int> targetIndexes;
}
