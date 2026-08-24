import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dongle_control.dart';
import 'proxy_server.dart';
import 'proxy_task_handler.dart';

void main() {
  // Required before the UI and the service isolate can exchange anything.
  // Without it sendDataToMain/sendDataToTask silently go nowhere: the proxy runs
  // but the UI never learns it, so the button stays on "Start" and tapping it
  // appears to do nothing.
  WidgetsFlutterBinding.ensureInitialized();
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

class _ProxyHomePageState extends State<ProxyHomePage>
    with WidgetsBindingObserver {
  final DongleControl _dongle = DongleControl();

  /// Mirror of the service isolate's state. The sockets live over there so they
  /// outlive this activity; the UI only renders what the service reports.
  bool _running = false;
  bool _shutdownPending = false;
  bool _autoStart = true;
  bool _cellularBound = false;
  Timer? _autoStartTimer;
  List<DeviceSnapshot> _devices = const [];
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
    _loadIp();
    _initForegroundTask();
    _ensureBackgroundPermissions();
    _restoreAutoStart();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    // The service may already be running from a previous session.
    _syncWithService();
  }

  /// Samsung's Freecess froze this process mid-session and the proxy stopped
  /// answering while the app still looked "running". A foreground service alone
  /// does not prevent that; the app also has to be off the battery optimiser.
  Future<void> _ensureBackgroundPermissions() async {
    if (!Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    final notif = await FlutterForegroundTask.checkNotificationPermission();
    if (notif != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
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
        // Periodic tick so the service pushes a fresh snapshot even when the
        // UI is not driving it.
        eventAction: ForegroundTaskEventAction.repeat(2000),
        // Survive a reboot and an app update: in the car the phone may restart
        // before the app is ever opened.
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static const String _autoStartKey = 'proxy_auto_start';

  Future<void> _restoreAutoStart() async {
    final saved = await FlutterForegroundTask.getData(key: _autoStartKey);
    if (mounted) setState(() => _autoStart = saved is bool ? saved : true);
    _autoStartTimer?.cancel();
    _autoStartTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadIp();
      _maybeAutoStart();
    });
    _maybeAutoStart();
  }

  /// Start the proxy on its own once we are on the dongle's network.
  ///
  /// Detected by subnet rather than SSID on purpose: reading the SSID needs
  /// location permission on modern Android, while our own address on the AP is
  /// free to look up and just as decisive.
  Future<void> _maybeAutoStart() async {
    if (!_autoStart || _running) return;
    final ip = await ProxyServer.getLocalIp();
    if (ip == null || !ip.startsWith(_dongleSubnetPrefix)) return;
    if (await FlutterForegroundTask.isRunningService) return;
    await _toggle();
  }

  /// The dongle hands out 10.0.0.0/24 on its own AP.
  static String get _dongleSubnetPrefix {
    final parts = DongleControl.defaultHost.split('.');
    return '${parts[0]}.${parts[1]}.${parts[2]}.';
  }

  Future<void> _syncWithService() async {
    // Ask the OS directly rather than trusting a message round-trip: the
    // service may already be running from autoRunOnBoot before this activity
    // ever existed.
    final live = await FlutterForegroundTask.isRunningService;
    if (mounted && live != _running) setState(() => _running = live);
    if (live) {
      if (!await DongleControl.isCellularBound()) {
        final b = await DongleControl.bindCellular();
        if (mounted) setState(() => _cellularBound = b);
      } else if (mounted) {
        setState(() => _cellularBound = true);
      }
      FlutterForegroundTask.sendDataToTask(proxyStatusRequest);
      _bandwidthRefreshTimer?.cancel();
      _bandwidthRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        FlutterForegroundTask.sendDataToTask(proxyStatusRequest);
      });
    }
  }

  /// Everything the UI knows about the proxy arrives through here.
  void _onTaskData(Object data) {
    if (data is! Map) return;
    if (!mounted) return;
    switch (data['type']) {
      case 'status':
        setState(() {
          _running = data['running'] == true;
          _shutdownPending = data['shutdownPending'] == true;
          _devices = [
            for (final d in (data['devices'] as List? ?? const []))
              DeviceSnapshot(
                ip: d['ip'] as String? ?? '?',
                bytes: (d['bytes'] as num?)?.toInt() ?? 0,
                requests: (d['requests'] as num?)?.toInt() ?? 0,
                active: Duration(milliseconds: (d['activeMs'] as num?)?.toInt() ?? 0),
              ),
          ]..sort((a, b) => b.bytes.compareTo(a.bytes));
        });
      case 'log':
        setState(() {
          _logs.insert(
            0,
            ProxyLogEntry(
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                  (data['timestamp'] as num?)?.toInt() ?? 0),
              method: data['method'] as String? ?? '',
              url: data['url'] as String? ?? '',
              statusCode: (data['statusCode'] as num?)?.toInt(),
              error: data['error'] as String?,
            ),
          );
          if (_logs.length > 500) _logs.removeLast();
        });
    }
  }

  Future<void> _loadIp() async {
    final ip = await ProxyServer.getLocalIp(preferPrefix: _dongleSubnetPrefix);
    if (mounted) setState(() => _localIp = ip);
  }

  /// True when this phone is actually on the dongle's AP. When it is not, the
  /// proxy still runs but nothing on the dongle can reach it, which is worth
  /// saying out loud rather than just showing an unfamiliar address.
  bool get _onDongleNetwork =>
      _localIp != null && _localIp!.startsWith(_dongleSubnetPrefix);

  Future<void> _toggle() async {
    if (_running) {
      await FlutterForegroundTask.stopService();
      await DongleControl.unbindCellular();
      WakelockPlus.disable();
      _bandwidthRefreshTimer?.cancel();
      _bandwidthRefreshTimer = null;
      if (mounted) setState(() => _running = false);
    } else {
      // Ports travel through shared prefs; the service isolate reads them on
      // start, since it cannot see this isolate's memory.
      await FlutterForegroundTask.saveData(
          key: proxyHttpPortKey, value: int.tryParse(_portController.text) ?? 8080);
      await FlutterForegroundTask.saveData(
          key: proxySocksPortKey, value: int.tryParse(_socksPortController.text) ?? 1080);
      await FlutterForegroundTask.saveData(
          key: proxyDnsPortKey, value: int.tryParse(_dnsPortController.text) ?? 5353);

      await FlutterForegroundTask.startService(
        notificationTitle: 'Proxy Running',
        notificationText:
            'HTTP :${_portController.text} | SOCKS :${_socksPortController.text} | DNS :${_dnsPortController.text}',
        callback: startProxyServiceCallback,
      );
      // Only after the service is up, so the listening sockets already exist.
      // Binding pins outbound traffic to mobile data, which is the whole point
      // of the relay and no longer something Android's default-network choice
      // can be trusted to provide.
      final boundNow = await DongleControl.bindCellular();
      if (mounted) setState(() => _cellularBound = boundNow);

      WakelockPlus.enable();
      _bandwidthRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        FlutterForegroundTask.sendDataToTask(proxyStatusRequest);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the background: the service may have started, stopped or
    // been restarted while this activity was gone.
    if (state == AppLifecycleState.resumed) {
      _syncWithService();
      _loadIp();
    }
  }

  @override
  void dispose() {
    // Deliberately does not stop the proxy: the sockets belong to the service
    // isolate and are meant to survive this activity being destroyed.
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    _bandwidthRefreshTimer?.cancel();
    _autoStartTimer?.cancel();
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

    // Two routes, because neither works everywhere:
    //  - direct POST: instant, but only from a device whose default network is
    //    this Wi-Fi. A phone with cellular cannot reach the dongle at all.
    //  - queued: the dongle polls us every ~15s and powers off when it sees the
    //    flag. Needs the proxy running, since the poll endpoint lives on it.
    final directError = await _dongle.shutdown();
    if (!mounted) return;

    String? error;
    String message;
    if (directError == null) {
      // It is going down now; make sure a reboot inside the TTL does not see a
      // stale request and power straight back off.
      FlutterForegroundTask.sendDataToTask(proxyShutdownCancel);
      message = 'Dongle is shutting down. Wait for its LED to stop before '
          'cutting power.';
    } else if (_running) {
      FlutterForegroundTask.sendDataToTask(proxyShutdownRequest);
      message = 'Shutdown queued \u2014 the dongle will power off within about '
          '${ProxyServer.pollHintSeconds}s, at its next check-in.';
    } else {
      error = 'Cannot reach the dongle directly from this phone, and the proxy '
          'is stopped so it cannot check in either. Start the proxy and try '
          'again, or unplug the dongle.';
      message = error;
    }

    setState(() => _shuttingDownDongle = false);

    // Explicit light-on-dark: the default SnackBar content colour is derived
    // from the theme, which renders near-black text on the red error surface
    // and is essentially unreadable.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(error == null ? Icons.power_settings_new : Icons.error_outline,
                color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        ),
        backgroundColor:
            error == null ? Colors.green.shade800 : Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error == null ? 5 : 10),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () =>
              ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
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
    final top = _devices.take(3).toList();
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
                if (_devices.length > 3)
                  Text('of ${_devices.length}',
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
            final entries = [for (final d in _devices) MapEntry(d.ip, d.bytes)];
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
                      final st = _devices.firstWhere((d) => d.ip == e.key,
                          orElse: () => DeviceSnapshot.empty);
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.devices, size: 18),
                        title: Text(e.key, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                        subtitle: Text('${_formatDuration(st.active)} active  \u00b7  ${st.requests} req',
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

  /// The controls card. Identical in both orientations.
  Widget _statusCard(ThemeData theme, String port) {
    return Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
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
                  onPressed: (_shuttingDownDongle || _shutdownPending)
                      ? null
                      : _shutdownDongle,
                  icon: (_shuttingDownDongle || _shutdownPending)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.power_settings_new),
                  label: Text(_shutdownPending
                      ? 'Waiting for dongle to check in\u2026'
                      : _shuttingDownDongle
                          ? 'Shutting down\u2026'
                          : 'Shut down dongle'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange.shade300,
                    side: BorderSide(color: Colors.orange.shade900),
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
              if (_running && !_cellularBound) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade900),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.signal_cellular_off,
                          size: 18, color: Colors.orange.shade300),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Not pinned to mobile data. Upstream will follow '
                          'whichever network Android prefers, which may have no '
                          'route out.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade200),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (!_onDongleNetwork) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade900),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.wifi_find,
                          size: 18, color: Colors.orange.shade300),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _localIp == null
                              ? 'No Wi-Fi address. Join the dongle\'s network '
                                  '(${DongleControl.defaultHost.substring(0, DongleControl.defaultHost.lastIndexOf('.'))}.x).'
                              : 'Not on the dongle\'s Wi-Fi \u2014 this phone is '
                                  'at $_localIp. The dongle cannot reach the '
                                  'proxy here.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade200),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _autoStart,
                title: const Text('Auto-start on dongle Wi-Fi',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text('Starts by itself once this phone joins '
                    '10.0.0.x', style: TextStyle(fontSize: 11)),
                onChanged: (v) async {
                  setState(() => _autoStart = v);
                  await FlutterForegroundTask.saveData(
                      key: _autoStartKey, value: v);
                  if (v) _maybeAutoStart();
                },
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
      );
  }

  /// Request log: header plus the scrolling list. The parent always gives this
  /// a bounded height so the list keeps its own scroll area instead of pushing
  /// the controls off screen.
  Widget _logsPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final port = _portController.text;

    return Scaffold(
      appBar: AppBar(
        // Status lives here now: the old 40px icon + headline + IP row cost
        // ~100dp of height, which in landscape forced the left panel to scroll.
        // The IP is still shown in full by the endpoints box below.
        title: Row(
          children: [
            const Text('Proxy'),
            const SizedBox(width: 12),
            Icon(
              _running ? Icons.wifi_tethering : Icons.wifi_tethering_off,
              size: 18,
              color: _running ? Colors.greenAccent : Colors.grey,
            ),
            const SizedBox(width: 6),
            Text(
              _running ? (_localIp == null ? 'Running' : '$_localIp:$port') : 'Stopped',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: !_running
                    ? Colors.grey
                    : (_onDongleNetwork ? Colors.tealAccent : Colors.orangeAccent),
                fontFamily: _running && _localIp != null ? 'monospace' : null,
              ),
            ),
          ],
        ),
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          // In landscape a phone leaves roughly 350dp of height: stacked
          // vertically the controls card alone fills it and the log is pushed
          // off screen. Side by side instead, each panel scrolling on its own.
          final wide = constraints.maxWidth > constraints.maxHeight &&
              constraints.maxWidth >= 600;

          if (!wide) {
            return Column(
              children: [
                _statusCard(theme, port),
                if (_running) _topDevicesCard(theme),
                Expanded(child: _logsPanel(theme)),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth * 0.42,
                // Scrollable so a short landscape viewport never clips the
                // Start / Shut down buttons.
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _statusCard(theme, port),
                      if (_running) _topDevicesCard(theme),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _logsPanel(theme)),
            ],
          );
        },
      ),
    );
  }
}
