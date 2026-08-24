import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dongle_control.dart';
import 'proxy_server.dart';

void main() {
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
  late ProxyServer _proxy;
  final DongleControl _dongle = DongleControl();
  bool _running = false;
  bool _shuttingDownDongle = false;
  String? _localIp;
  final List<ProxyLogEntry> _logs = [];
  final _portController = TextEditingController(text: '8080');
  final _socksPortController = TextEditingController(text: '1080');
  final _dnsPortController = TextEditingController(text: '5353');
  Timer? _bandwidthRefreshTimer;

  @override
  void initState() {
    super.initState();
    _initProxy();
    _loadIp();
    _initForegroundTask();
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
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  void _initProxy() {
    _proxy = ProxyServer(
      port: int.tryParse(_portController.text) ?? 8080,
      socksPort: int.tryParse(_socksPortController.text) ?? 1080,
      dnsPort: int.tryParse(_dnsPortController.text) ?? 5353,
      onLog: (entry) {
        if (mounted) {
          setState(() => _logs.insert(0, entry));
        }
      },
      onStatusChanged: (running) {
        if (mounted) {
          setState(() => _running = running);
        }
      },
    );
  }

  Future<void> _loadIp() async {
    final ip = await ProxyServer.getLocalIp();
    if (mounted) setState(() => _localIp = ip);
  }

  Future<void> _toggle() async {
    if (_running) {
      await _proxy.stop();
      WakelockPlus.disable();
      FlutterForegroundTask.stopService();
      _bandwidthRefreshTimer?.cancel();
      _bandwidthRefreshTimer = null;
    } else {
      await _proxy.stop();
      _initProxy();
      await _proxy.start();
      WakelockPlus.enable();
      FlutterForegroundTask.startService(
        notificationTitle: 'Proxy Running',
        notificationText: 'HTTP :${_portController.text} | SOCKS :${_socksPortController.text} | DNS :${_dnsPortController.text}',
      );
      // Periodically refresh UI to update bandwidth display
      _bandwidthRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _proxy.stop();
    WakelockPlus.disable();
    _bandwidthRefreshTimer?.cancel();
    _portController.dispose();
    _socksPortController.dispose();
    _dnsPortController.dispose();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _shutdownDongle() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.power_settings_new, color: Colors.orange),
        title: const Text('Shut down dongle?'),
        content: const Text(
          'The Android Auto dongle will power off. Android Auto will disconnect '
          'and its Wi-Fi network will disappear.\n\n'
          'You will need to unplug and replug it to turn it back on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Shut down'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _shuttingDownDongle = true);
    final error = await _dongle.shutdown();
    if (!mounted) return;
    setState(() => _shuttingDownDongle = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ??
            'Dongle is shutting down. Wait for its LED to stop before '
            'cutting power.'),
        backgroundColor: error == null ? null : Colors.red.shade900,
        duration: Duration(seconds: error == null ? 5 : 8),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  /// Top 3 clients by data, with how long each was actually active.
  Widget _topDevicesCard(ThemeData theme) {
    final top = _proxy.topDevices(3);
    if (top.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Top devices', style: theme.textTheme.titleSmall),
                if (_proxy.statsByIp.length > 3)
                  Text('of ${_proxy.statsByIp.length}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor)),
              ],
            ),
            const SizedBox(height: 8),
            ...top.map((d) {
              final maxBytes = top.first.bytes == 0 ? 1 : top.first.bytes;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(d.ip,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 13)),
                        ),
                        Text(_formatBytes(d.bytes),
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                color: Colors.tealAccent)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.schedule, size: 12, color: theme.hintColor),
                        const SizedBox(width: 4),
                        Text(_formatDuration(d.active),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.hintColor)),
                        const SizedBox(width: 12),
                        Icon(Icons.swap_vert, size: 12, color: theme.hintColor),
                        const SizedBox(width: 4),
                        Text('${d.requests} req',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.hintColor)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: d.bytes / maxBytes,
                        minHeight: 3,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  void _showBandwidthStats() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final entries = _proxy.bandwidthByIp.entries.toList()
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
                      Text('Bandwidth by IP', style: Theme.of(context).textTheme.titleMedium),
                      Text('Total: ${_formatBytes(total)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.tealAccent,
                        )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No traffic yet')),
                    )
                  else
                    ...entries.take(20).map((e) {
                      final st = _proxy.statsByIp[e.key];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.devices, size: 18),
                        title: Text(e.key, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                        subtitle: st == null
                            ? null
                            : Text('${_formatDuration(st.active)} active  \u00b7  ${st.requests} req',
                                style: const TextStyle(fontSize: 11)),
                        trailing: Text(_formatBytes(e.value),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.tealAccent)),
                      );
                    }),
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

    return Scaffold(
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
                        _running ? Icons.wifi_tethering : Icons.wifi_tethering_off,
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
                                  style: theme.textTheme.headlineMedium?.copyWith(
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
                      onPressed: _toggle,
                      icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                      label: Text(_running ? 'Stop' : 'Start'),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            _running ? Colors.red.shade700 : Colors.green.shade700,
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _shuttingDownDongle ? null : _shutdownDongle,
                      icon: _shuttingDownDongle
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.power_settings_new),
                      label: Text(_shuttingDownDongle
                          ? 'Shutting down\u2026'
                          : 'Shut down dongle'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange.shade300,
                        side: BorderSide(color: Colors.orange.shade900),
                        minimumSize: const Size(0, 44),
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
          if (_running) _topDevicesCard(theme),
          // Logs header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'Request Log',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(width: 8),
                Text(
                  '(${_logs.length})',
                  style: theme.textTheme.bodySmall,
                ),
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
                          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
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
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
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
    );
  }
}
