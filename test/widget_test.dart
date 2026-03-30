import 'package:flutter_test/flutter_test.dart';

import 'package:jhentai/main.dart';
import 'package:jhentai/service/jh_service.dart';

class _FakeLifeCycleBean implements JHLifeCircleBean {
  final List<JHLifeCircleBean> _initDependencies;

  @override
  List<JHLifeCircleBean> get initDependencies => _initDependencies;

  _FakeLifeCycleBean({
    List<JHLifeCircleBean> initDependencies = const <JHLifeCircleBean>[],
  }) : _initDependencies = List<JHLifeCircleBean>.from(initDependencies);

  void setDependencies(List<JHLifeCircleBean> dependencies) {
    _initDependencies
      ..clear()
      ..addAll(dependencies);
  }

  @override
  Future<void> initBean() async {}

  @override
  void afterBeanReady() {}
}

void main() {
  test('topologicalSort keeps dependency order', () {
    final _FakeLifeCycleBean dependency = _FakeLifeCycleBean();
    final _FakeLifeCycleBean target =
        _FakeLifeCycleBean(initDependencies: <JHLifeCircleBean>[dependency]);

    final List<JHLifeCircleBean> sorted = topologicalSort(<JHLifeCircleBean>[target, dependency]);

    expect(sorted.indexOf(dependency), lessThan(sorted.indexOf(target)));
  });

  test('topologicalSort throws on circular dependency', () {
    final _FakeLifeCycleBean beanA = _FakeLifeCycleBean();
    final _FakeLifeCycleBean beanB = _FakeLifeCycleBean();

    beanA.setDependencies(<JHLifeCircleBean>[beanB]);
    beanB.setDependencies(<JHLifeCircleBean>[beanA]);

    expect(
      () => topologicalSort(<JHLifeCircleBean>[beanA, beanB]),
      throwsException,
    );
  });
}
