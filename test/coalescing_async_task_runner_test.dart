import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/utils/coalescing_async_task_runner.dart';

void main() {
  group('CoalescingAsyncTaskRunner', () {
    test('yields before starting work', () async {
      final CoalescingAsyncTaskRunner<int> runner =
          CoalescingAsyncTaskRunner<int>();
      bool started = false;

      final Future<void> completed = runner.schedule(1, (_) async {
        started = true;
      });

      expect(started, isFalse);
      await completed;
      expect(started, isTrue);
    });

    test('skips a superseded commit and runs only the latest pending task',
        () async {
      final CoalescingAsyncTaskRunner<int> runner =
          CoalescingAsyncTaskRunner<int>();
      final Completer<void> firstStarted = Completer<void>();
      final Completer<void> releaseFirst = Completer<void>();
      final List<String> commits = <String>[];

      final Future<void> first = runner.schedule(1, (isSuperseded) async {
        firstStarted.complete();
        await releaseFirst.future;
        if (!isSuperseded()) {
          commits.add('stale');
        }
      });

      await firstStarted.future;
      final Future<void> latest = runner.schedule(1, (isSuperseded) async {
        if (!isSuperseded()) {
          commits.add('latest');
        }
      });
      releaseFirst.complete();

      await Future.wait(<Future<void>>[first, latest]);
      expect(commits, <String>['latest']);
    });

    test('cancel prevents pending work from committing', () async {
      final CoalescingAsyncTaskRunner<int> runner =
          CoalescingAsyncTaskRunner<int>();
      bool committed = false;

      final Future<void> completed = runner.schedule(1, (isSuperseded) async {
        if (!isSuperseded()) {
          committed = true;
        }
      });
      runner.cancel(1);

      await completed;
      expect(committed, isFalse);
    });
  });
}
