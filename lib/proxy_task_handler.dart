import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'proxy_server.dart';

const proxyHttpPortKey = 'proxy_http_port';
const proxySocksPortKey = 'proxy_socks_port';
const proxyDnsPortKey = 'proxy_dns_port';
const proxyStatusRequest = 'proxy_status_request';
const proxyShutdownRequest = 'proxy_shutdown_request';
const proxyShutdownCancel = 'proxy_shutdown_cancel';

/// Entry point used by the foreground-service isolate.
@pragma('vm:entry-point')
void startProxyServiceCallback() {
  FlutterForegroundTask.setTaskHandler(ProxyTaskHandler());
}

/// Owns all listening sockets so they outlive the Flutter activity.
class ProxyTaskHandler extends TaskHandler {
  ProxyServer? _proxy;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final httpPort = await _savedPort(proxyHttpPortKey, 8080);
    final socksPort = await _savedPort(proxySocksPortKey, 1080);
    final dnsPort = await _savedPort(proxyDnsPortKey, 5353);

    _proxy = ProxyServer(
      port: httpPort,
      socksPort: socksPort,
      dnsPort: dnsPort,
      onLog: _sendLog,
      onStatusChanged: (_) {},
    );

    try {
      await _proxy!.start();
      _sendSnapshot(running: true);
    } catch (error) {
      _sendLog(
        ProxyLogEntry(
          timestamp: DateTime.now(),
          method: 'ERROR',
          url: 'Could not start proxy',
          error: error.toString(),
        ),
      );
      _sendSnapshot(running: false);
      await _proxy?.stop();
      _proxy = null;
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _sendSnapshot(running: _proxy?.isRunning ?? false);
  }

  @override
  void onReceiveData(Object data) {
    switch (data) {
      case proxyStatusRequest:
        _sendSnapshot(running: _proxy?.isRunning ?? false);
      case proxyShutdownRequest:
        // The dongle polls this isolate, not the UI one, so the pending flag
        // has to be set here.
        _proxy?.requestDongleShutdown();
        _sendSnapshot(running: _proxy?.isRunning ?? false);
      case proxyShutdownCancel:
        _proxy?.cancelDongleShutdown();
        _sendSnapshot(running: _proxy?.isRunning ?? false);
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _proxy?.stop();
    _proxy = null;
    _sendSnapshot(running: false);
  }

  Future<int> _savedPort(String key, int fallback) async {
    final value = await FlutterForegroundTask.getData(key: key);
    return value is int ? value : fallback;
  }

  void _sendLog(ProxyLogEntry entry) {
    FlutterForegroundTask.sendDataToMain({
      'type': 'log',
      'timestamp': entry.timestamp.millisecondsSinceEpoch,
      'method': entry.method,
      'url': entry.url,
      'statusCode': entry.statusCode,
      'error': entry.error,
    });
  }

  void _sendSnapshot({required bool running}) {
    final stats = _proxy?.statsByIp.values.toList() ?? const <DeviceStats>[];
    FlutterForegroundTask.sendDataToMain({
      'type': 'status',
      'running': running,
      'shutdownPending': _proxy?.shutdownPending ?? false,
      // Flattened for the isolate boundary: only primitives survive it.
      'devices': [
        for (final d in stats)
          {
            'ip': d.ip,
            'bytes': d.bytes,
            'requests': d.requests,
            'activeMs': d.active.inMilliseconds,
          }
      ],
    });
  }
}

/// Per-device usage as it crosses the isolate boundary into the UI.
class DeviceSnapshot {
  const DeviceSnapshot({
    required this.ip,
    required this.bytes,
    required this.requests,
    required this.active,
  });

  static const DeviceSnapshot empty =
      DeviceSnapshot(ip: '?', bytes: 0, requests: 0, active: Duration.zero);

  final String ip;
  final int bytes;
  final int requests;
  final Duration active;
}
