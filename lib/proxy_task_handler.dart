import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'proxy_server.dart';

const proxyHttpPortKey = 'proxy_http_port';
const proxySocksPortKey = 'proxy_socks_port';
const proxyDnsPortKey = 'proxy_dns_port';
const proxyStatusRequest = 'proxy_status_request';

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
    if (data == proxyStatusRequest) {
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
    FlutterForegroundTask.sendDataToMain({
      'type': 'status',
      'running': running,
      'bandwidth': Map<String, int>.from(
        _proxy?.bandwidthByIp ?? const <String, int>{},
      ),
    });
  }
}
