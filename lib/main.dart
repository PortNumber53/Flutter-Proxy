import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'proxy_server.dart';
import 'proxy_task_handler.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const ProxyApp());
}

class ProxyApp extends StatelessWidget {
  const ProxyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Proxy',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ProxyHomePage(),
    );
  }
}

class ProxyHomePage extends StatefulWidget {
  const ProxyHomePage({super.key});

  @override
  State<ProxyHomePage> createState() => _ProxyHomePageState();
}

class _ProxyHomePageState extends State<ProxyHomePage> {
  bool _running = false;
  bool _busy = false;
  String? _localIp;
  final List<ProxyLogEntry> _logs = [];
  final Map<String, int> _bandwidthByIp = {};
  final _portController = TextEditingController(text: '8080');
  final _socksPortController = TextEditingController(text: '1080');
  final _dnsPortController = TextEditingController(text: '5353');

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _loadIp();
    _loadServiceState();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'proxy_service',
        channelName: 'Proxy Service',
        channelDescription: 'Keeps the proxy server running in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(2000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _loadServiceState() async {
    try {
      final values = await Future.wait([
        FlutterForegroundTask.getData(key: proxyHttpPortKey),
        FlutterForegroundTask.getData(key: proxySocksPortKey),
        FlutterForegroundTask.getData(key: proxyDnsPortKey),
      ]);
      final running = await FlutterForegroundTask.isRunningService;
      if (!mounted) return;

      setState(() {
        if (values[0] is int) _portController.text = '${values[0]}';
        if (values[1] is int) _socksPortController.text = '${values[1]}';
        if (values[2] is int) _dnsPortController.text = '${values[2]}';
        _running = running;
      });
      if (running) {
        FlutterForegroundTask.sendDataToTask(proxyStatusRequest);
      }
    } on MissingPluginException {
      // Platform services are unavailable in widget tests and unsupported hosts.
    }
  }

  Future<void> _loadIp() async {
    final ip = await ProxyServer.getLocalIp();
    if (mounted) setState(() => _localIp = ip);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);

    if (_running) {
      final result = await FlutterForegroundTask.stopService();
      if (!mounted) return;
      if (result is ServiceRequestFailure) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop proxy: ${result.error}')),
        );
      } else {
        setState(() {
          _running = false;
          _busy = false;
        });
      }
    } else {
      final ports = _validatedPorts();
      if (ports == null) {
        setState(() => _busy = false);
        return;
      }

      try {
        if (Platform.isAndroid &&
            await FlutterForegroundTask.checkNotificationPermission() !=
                NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }

        final saved = await Future.wait([
          FlutterForegroundTask.saveData(
            key: proxyHttpPortKey,
            value: ports.$1,
          ),
          FlutterForegroundTask.saveData(
            key: proxySocksPortKey,
            value: ports.$2,
          ),
          FlutterForegroundTask.saveData(key: proxyDnsPortKey, value: ports.$3),
        ]);
        if (saved.any((success) => !success)) {
          throw StateError('Could not save the proxy port configuration.');
        }

        final result = await FlutterForegroundTask.startService(
          serviceId: 8080,
          notificationTitle: 'Proxy Running',
          notificationText:
              'HTTP :${ports.$1} | SOCKS :${ports.$2} | DNS :${ports.$3}',
          callback: startProxyServiceCallback,
        );
        if (result is ServiceRequestFailure) throw result.error;
        if (mounted) {
          setState(() {
            _running = true;
            _busy = false;
          });
        }
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _busy = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start proxy: $error')),
        );
      }
    }
  }

  (int, int, int)? _validatedPorts() {
    final httpPort = int.tryParse(_portController.text);
    final socksPort = int.tryParse(_socksPortController.text);
    final dnsPort = int.tryParse(_dnsPortController.text);
    final valid = [
      httpPort,
      socksPort,
      dnsPort,
    ].every((port) => port != null && port >= 1 && port <= 65535);
    if (!valid || httpPort == socksPort) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !valid
                ? 'Ports must be numbers from 1 to 65535.'
                : 'HTTP and SOCKS must use different TCP ports.',
          ),
        ),
      );
      return null;
    }
    return (httpPort!, socksPort!, dnsPort!);
  }

  void _onReceiveTaskData(Object data) {
    if (!mounted || data is! Map) return;
    final message = Map<String, dynamic>.from(data);

    switch (message['type']) {
      case 'log':
        setState(() {
          _logs.insert(
            0,
            ProxyLogEntry(
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                message['timestamp'] as int,
              ),
              method: message['method'] as String,
              url: message['url'] as String,
              statusCode: message['statusCode'] as int?,
              error: message['error'] as String?,
            ),
          );
        });
      case 'status':
        final bandwidth = message['bandwidth'];
        setState(() {
          _running = message['running'] == true;
          _busy = false;
          _bandwidthByIp
            ..clear()
            ..addAll(
              bandwidth is Map
                  ? bandwidth.map(
                      (key, value) => MapEntry('$key', value as int),
                    )
                  : const <String, int>{},
            );
        });
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    _portController.dispose();
    _socksPortController.dispose();
    _dnsPortController.dispose();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _showBandwidthStats() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final entries = _bandwidthByIp.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));
            final total = entries.fold<int>(0, (sum, e) => sum + e.value);

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Bandwidth by IP',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        'Total: ${_formatBytes(total)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.tealAccent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No traffic yet')),
                    )
                  else
                    ...entries
                        .take(20)
                        .map(
                          (e) => ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: const Icon(Icons.devices, size: 18),
                            title: Text(
                              e.key,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                            ),
                            trailing: Text(
                              _formatBytes(e.value),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                color: Colors.tealAccent,
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final port = _portController.text;

    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Proxy'),
          actions: [
            if (_running)
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: 'Bandwidth stats',
                onPressed: _showBandwidthStats,
              ),
            if (_logs.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: 'Clear logs',
                onPressed: () => setState(() => _logs.clear()),
              ),
          ],
        ),
        body: Column(
          children: [
            // Status card
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          _running
                              ? Icons.wifi_tethering
                              : Icons.wifi_tethering_off,
                          size: 40,
                          color: _running ? Colors.greenAccent : Colors.grey,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _running ? 'Proxy Running' : 'Proxy Stopped',
                                style: theme.textTheme.titleLarge,
                              ),
                              if (_localIp != null && _running)
                                GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(text: '$_localIp:$port'),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Copied to clipboard'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  },
                                  child: Text(
                                    '$_localIp:$port',
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                          color: Colors.tealAccent,
                                          fontFamily: 'monospace',
                                        ),
                                  ),
                                )
                              else if (_localIp == null)
                                Text(
                                  'Could not detect WiFi IP',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.orange,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _portController,
                            enabled: !_running,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'HTTP',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _socksPortController,
                            enabled: !_running,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'SOCKS',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _dnsPortController,
                            enabled: !_running,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'DNS',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _toggle,
                        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                        label: Text(_running ? 'Stop' : 'Start'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _running
                              ? Colors.red.shade700
                              : Colors.green.shade700,
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                    if (_running && _localIp != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'HTTP Proxy: $_localIp:$port\n'
                          'SOCKS5 (SSH): $_localIp:${_socksPortController.text}\n'
                          'DNS: $_localIp:${_dnsPortController.text}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Logs header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('Request Log', style: theme.textTheme.titleSmall),
                  const SizedBox(width: 8),
                  Text('(${_logs.length})', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Log list
            Expanded(
              child: _logs.isEmpty
                  ? Center(
                      child: Text(
                        _running
                            ? 'Waiting for requests...'
                            : 'Start the proxy to see requests',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        final time =
                            '${log.timestamp.hour.toString().padLeft(2, '0')}:'
                            '${log.timestamp.minute.toString().padLeft(2, '0')}:'
                            '${log.timestamp.second.toString().padLeft(2, '0')}';

                        Color methodColor;
                        switch (log.method) {
                          case 'GET':
                            methodColor = Colors.greenAccent;
                          case 'POST':
                            methodColor = Colors.blueAccent;
                          case 'CONNECT':
                            methodColor = Colors.purpleAccent;
                          case 'WS':
                            methodColor = Colors.cyanAccent;
                          case 'SOCKS':
                            methodColor = Colors.amberAccent;
                          case 'DNS':
                            methodColor = Colors.tealAccent;
                          case 'ERROR':
                            methodColor = Colors.redAccent;
                          default:
                            methodColor = Colors.orangeAccent;
                        }

                        return ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: Container(
                            width: 70,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: methodColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              log.method,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: methodColor,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          title: Text(
                            log.url,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: log.error != null
                              ? Text(
                                  log.error!,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 10,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                time,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              ),
                              if (log.statusCode != null)
                                Text(
                                  '${log.statusCode}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: log.statusCode! < 400
                                        ? Colors.greenAccent
                                        : Colors.redAccent,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
