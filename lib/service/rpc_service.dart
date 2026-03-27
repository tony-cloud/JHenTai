import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:jhentai/network/rpc_request.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/rpc_setting.dart';

RPCService rpcService = RPCService();

class RPCService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  RxBool isBackendReachable = false.obs;
  RxList<String> capabilities = <String>[].obs;
  RxnString backendName = RxnString();
  RxnString backendVersion = RxnString();

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([rpcSetting, rpcRequest]);

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {
    if (rpcSetting.enableRpcMode.isFalse) {
      return;
    }

    await checkHealth();
  }

  Future<bool> checkHealth() async {
    try {
      final Map<String, dynamic> result = await rpcRequest.requestSystemHealth();
      _applyHealthResult(result);
      log.info('RPC health check success: $result');

      await _refreshCapabilities();
      return true;
    } catch (e) {
      isBackendReachable.value = false;
      capabilities.clear();
      log.warning('RPC health check failed', e, true);
      return false;
    }
  }

  bool supportsCapability(String capability) {
    return capabilities.contains(capability);
  }

  void _applyHealthResult(Map<String, dynamic> result) {
    isBackendReachable.value = _parseHealthState(result);
    backendName.value = result['name']?.toString();
    backendVersion.value = result['version']?.toString();

    final List<String> healthCapabilities = _parseCapabilities(result['capabilities']);
    if (healthCapabilities.isNotEmpty) {
      capabilities.assignAll(healthCapabilities);
    }
  }

  Future<void> _refreshCapabilities() async {
    try {
      final Map<String, dynamic> result = await rpcRequest.requestSystemCapabilities();
      final List<String> latestCapabilities = _parseCapabilities(result['capabilities']);
      if (latestCapabilities.isNotEmpty) {
        capabilities.assignAll(latestCapabilities);
      }

      backendName.value = result['name']?.toString() ?? backendName.value;
      backendVersion.value = result['version']?.toString() ?? backendVersion.value;
    } on RPCRequestException catch (e) {
      // Older backend may not implement capability discovery yet.
      log.trace('RPC capability discovery skipped: $e');
    } catch (e) {
      log.warning('RPC capability discovery failed', e, true);
    }
  }

  bool _parseHealthState(Map<String, dynamic> result) {
    final dynamic status = result['status'];
    if (status != null) {
      final String normalized = status.toString().toLowerCase();
      if (normalized == 'ok' || normalized == 'healthy') {
        return true;
      }
    }

    final dynamic healthy = result['healthy'];
    if (healthy is bool) {
      return healthy;
    }

    final dynamic ok = result['ok'];
    if (ok is bool) {
      return ok;
    }

    return true;
  }

  List<String> _parseCapabilities(dynamic rawCapabilities) {
    if (rawCapabilities is List) {
      return rawCapabilities
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
    }

    if (rawCapabilities is String) {
      return rawCapabilities
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
    }

    return <String>[];
  }
}
