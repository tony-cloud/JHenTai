import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/utils/domain_fronting_util.dart';
import 'package:jhentai/utils/rpc_media_proxy_util.dart';

typedef ResolvedImageWidgetBuilder = Widget Function(
  BuildContext context,
  DomainFrontingResult fronting,
  Map<String, String>? headers,
  VoidCallback retry,
);

/// Resolve an image request once, retaining it across ordinary widget rebuilds.
class EHImageRequestBuilder extends StatefulWidget {
  final String url;
  final ResolvedImageWidgetBuilder builder;
  final WidgetBuilder loadingBuilder;

  const EHImageRequestBuilder({
    super.key,
    required this.url,
    required this.builder,
    required this.loadingBuilder,
  });

  @override
  State<EHImageRequestBuilder> createState() => _EHImageRequestBuilderState();
}

class _EHImageRequestBuilderState extends State<EHImageRequestBuilder> {
  late RPCMediaProxyResult _proxy;
  late (bool, bool, String) _networkSettings;
  late Future<DomainFrontingResult> _request;

  (bool, bool, String) get _currentNetworkSettings => (
        networkSetting.enableDomainFronting.value,
        networkSetting.enableDnsOverHttps.value,
        networkSetting.dnsOverHttpsEndpoint.value,
      );

  @override
  void initState() {
    super.initState();
    _startResolution(RPCMediaProxyUtil.build(widget.url));
  }

  @override
  void didUpdateWidget(covariant EHImageRequestBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final RPCMediaProxyResult proxy = RPCMediaProxyUtil.build(widget.url);
    if (oldWidget.url != widget.url ||
        _proxy.url != proxy.url ||
        _proxy.proxied != proxy.proxied ||
        !mapEquals(_proxy.headers, proxy.headers) ||
        _networkSettings != _currentNetworkSettings) {
      _startResolution(proxy);
    }
  }

  void _startResolution(RPCMediaProxyResult proxy) {
    _proxy = proxy;
    _networkSettings = _currentNetworkSettings;
    _request = _resolve(proxy);
  }

  Future<DomainFrontingResult> _resolve(RPCMediaProxyResult proxy) {
    if (proxy.proxied) {
      return SynchronousFuture(DomainFrontingResult(url: proxy.url));
    }
    try {
      return DomainFrontingUtil.build(widget.url);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  void _retry() {
    setState(() => _startResolution(RPCMediaProxyUtil.build(widget.url)));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DomainFrontingResult>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingBuilder(context);
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: GestureDetector(
              onTap: _retry,
              child: const Icon(Icons.sentiment_very_dissatisfied),
            ),
          );
        }
        final DomainFrontingResult fronting = snapshot.data!;
        return KeyedSubtree(
          // A retry must recreate failed image state even when the IP is unchanged.
          key: ObjectKey(_request),
          child: widget.builder(context, fronting, _proxy.headers ?? fronting.headers, _retry),
        );
      },
    );
  }
}
