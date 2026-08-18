import 'dart:async';

typedef CoalescingAsyncTask = Future<void> Function(
    bool Function() isSuperseded);

/// Runs at most one task for each key and coalesces bursts into the latest task.
///
/// A task can avoid committing stale work by checking [isSuperseded] after an
/// expensive asynchronous preparation step. The runner always yields once
/// before starting a new drain so callers can finish their current UI event.
class CoalescingAsyncTaskRunner<K> {
  final Map<K, _CoalescingAsyncTaskState> _states =
      <K, _CoalescingAsyncTaskState>{};

  Future<void> schedule(K key, CoalescingAsyncTask task) {
    final _CoalescingAsyncTaskState state =
        _states.putIfAbsent(key, _CoalescingAsyncTaskState.new);
    state.generation++;
    state
      ..latestTask = task
      ..dirty = true;

    final Future<void>? active = state.active;
    if (active != null) {
      return active;
    }

    final Future<void> drain = _drain(key, state);
    state.active = drain;
    return drain;
  }

  void cancel(K key) {
    final _CoalescingAsyncTaskState? state = _states.remove(key);
    if (state != null) {
      state.cancelled = true;
    }
  }

  Future<void> _drain(K key, _CoalescingAsyncTaskState state) async {
    await Future<void>.delayed(Duration.zero);

    try {
      while (state.dirty && !state.cancelled) {
        state.dirty = false;
        final int generation = state.generation;
        final CoalescingAsyncTask task = state.latestTask!;
        await task(() => state.cancelled || state.generation != generation);
      }
    } finally {
      if (identical(_states[key], state)) {
        _states.remove(key);
      }
    }
  }
}

class _CoalescingAsyncTaskState {
  int generation = 0;
  bool dirty = false;
  bool cancelled = false;
  CoalescingAsyncTask? latestTask;
  Future<void>? active;
}
