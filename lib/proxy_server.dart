import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class ProxyLogEntry {
  final DateTime timestamp;
  final String method;
  final String url;
  final int? statusCode;
  final String? error;

  ProxyLogEntry({
    required this.timestamp,
    required this.method,
    required this.url,
    this.statusCode,
    this.error,
  });
}


/// Per-client usage: how much data, and how long it was actually active.
class DeviceStats {
  DeviceStats(this.ip);

  final String ip;
  int bytes = 0;
  int requests = 0;
  DateTime? firstSeen;
  DateTime? lastSeen;

  /// Accumulated *active* time, not wall-clock since firstSeen. Gaps longer
  /// than [idleGap] are treated as the device being idle rather than in use,
  /// so a phone left connected overnight does not report 8 hours of usage.
  Duration active = Duration.zero;

  static const Duration idleGap = Duration(seconds: 60);

  void touch(DateTime now, int addedBytes) {
    bytes += addedBytes;
    firstSeen ??= now;
    final prev = lastSeen;
    if (prev != null) {
      final gap = now.difference(prev);
      if (gap <= idleGap) active += gap;
    }
    lastSeen = now;
  }
}

class ProxyServer {
  HttpServer? _server;
  ServerSocket? _socksServer;
  RawDatagramSocket? _dnsServer;
  final int port;
  final int socksPort;
  final int dnsPort;
  final String upstreamDns;

  /// The dongle's address on its own AP; only this peer consumes a pending
  /// shutdown request.
  final String dongleIp;
  final void Function(ProxyLogEntry entry) onLog;
  final void Function(bool running) onStatusChanged;

  /// Usage per client IP address.
  final Map<String, DeviceStats> statsByIp = {};

  /// Bandwidth consumed per client IP address (bytes).
  Map<String, int> get bandwidthByIp =>
      {for (final e in statsByIp.entries) e.key: e.value.bytes};

  /// The busiest clients, most data first.
  List<DeviceStats> topDevices([int limit = 3]) {
    final all = statsByIp.values.toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    return all.take(limit).toList();
  }

  void _trackBandwidth(String ip, int bytes) {
    (statsByIp[ip] ??= DeviceStats(ip)).touch(DateTime.now(), bytes);
  }

  void _trackRequest(String ip) {
    final st = statsByIp[ip] ??= DeviceStats(ip);
    st.requests++;
    st.touch(DateTime.now(), 0);
  }

  bool get isRunning => _server != null;

  ProxyServer({
    this.port = 8080,
    this.socksPort = 1080,
    this.dnsPort = 5353,
    this.upstreamDns = '8.8.8.8',
    this.dongleIp = '10.0.0.1',
    required this.onLog,
    required this.onStatusChanged,
  });

  Future<void> start() async {
    if (_server != null) return;

    // Start HTTP proxy
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest, onError: (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'ERROR',
        url: e.toString(),
      ));
    });

    // Start SOCKS5 proxy
    _socksServer = await ServerSocket.bind(InternetAddress.anyIPv4, socksPort);
    _socksServer!.listen(_handleSocksClient, onError: (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'ERROR',
        url: 'SOCKS: $e',
      ));
    });

    // Start DNS proxy
    _dnsServer = await RawDatagramSocket.bind(InternetAddress.anyIPv4, dnsPort);
    _dnsServer!.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _dnsServer!.receive();
        if (datagram != null) {
          _handleDnsQuery(datagram);
        }
      }
    });

    onStatusChanged(true);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _socksServer?.close();
    _socksServer = null;
    _dnsServer?.close();
    _dnsServer = null;
    onStatusChanged(false);
  }

  // ─── SOCKS5 Proxy ───

  Future<void> _handleSocksClient(Socket client) async {
    final reader = _SocketReader(client);
    try {
      // Read greeting
      final greeting = await reader.read(2);
      if (greeting[0] != 0x05) {
        client.close();
        return;
      }
      final nMethods = greeting[1];
      await reader.read(nMethods); // consume methods

      // Reply: no authentication required
      client.add([0x05, 0x00]);

      // Read connect request
      final header = await reader.read(4);
      if (header[0] != 0x05 || header[1] != 0x01) {
        // Only support CONNECT command
        client.add([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        client.close();
        return;
      }

      String host;
      final addrType = header[3];
      if (addrType == 0x01) {
        // IPv4
        final addr = await reader.read(4);
        host = addr.join('.');
      } else if (addrType == 0x03) {
        // Domain name
        final lenByte = await reader.read(1);
        final domainBytes = await reader.read(lenByte[0]);
        host = String.fromCharCodes(domainBytes);
      } else if (addrType == 0x04) {
        // IPv6
        final addr = await reader.read(16);
        host = InternetAddress.fromRawAddress(Uint8List.fromList(addr)).address;
      } else {
        client.add([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        client.close();
        return;
      }

      final portBytes = await reader.read(2);
      final targetPort = (portBytes[0] << 8) | portBytes[1];

      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'SOCKS',
        url: '$host:$targetPort',
      ));

      // Connect to target
      final target = await Socket.connect(host, targetPort);

      // Send success reply
      final boundAddr = target.address.rawAddress;
      final boundPort = target.port;
      client.add([
        0x05, 0x00, 0x00, 0x01,
        ...boundAddr,
        (boundPort >> 8) & 0xFF, boundPort & 0xFF,
      ]);

      // Switch to bidirectional tunnel — hand remaining buffered data
      // and future data to target
      final socksClientIp = client.remoteAddress.address;
    _trackRequest(socksClientIp);
      reader.forwardTo(target,
        onDone: client.close,
        onData: (bytes) => _trackBandwidth(socksClientIp, bytes),
      );
      target.listen((data) { _trackBandwidth(socksClientIp, data.length); client.add(data); },
        onDone: client.close, onError: (_) => client.close());
    } catch (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'SOCKS',
        url: 'connection',
        error: e.toString(),
      ));
      try {
        client.close();
      } catch (_) {}
    }
  }

  // ─── DNS Proxy ───

  Future<void> _handleDnsQuery(Datagram datagram) async {
    final clientIp = datagram.address.address;
    _trackBandwidth(clientIp, datagram.data.length);

    onLog(ProxyLogEntry(
      timestamp: DateTime.now(),
      method: 'DNS',
      url: '$clientIp:${datagram.port}',
    ));

    try {
      final upstream = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      upstream.send(datagram.data, InternetAddress(upstreamDns), 53);

      // Wait for response with timeout
      await for (final event in upstream.timeout(const Duration(seconds: 5))) {
        if (event == RawSocketEvent.read) {
          final response = upstream.receive();
          if (response != null) {
            _trackBandwidth(clientIp, response.data.length);
            _dnsServer?.send(response.data, datagram.address, datagram.port);
          }
          break;
        }
      }
      upstream.close();
    } catch (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'DNS',
        url: '${datagram.address.address}:${datagram.port}',
        error: e.toString(),
      ));
    }
  }

  /// Roughly how long a queued shutdown takes to be picked up, for UI copy.
  /// Matches AAWG_EXTRA_SHUTDOWN_POLL in the dongle's /boot/aawgd.conf.
  static const int pollHintSeconds = 15;

  /// Path the dongle polls to ask whether it should power itself off.
  static const String pollPath = '/__aawg/poll';

  /// Set when the user asks for a shutdown; consumed by the dongle's next poll.
  DateTime? _shutdownRequestedAt;

  /// A pending request goes stale after this. Without an expiry, a request made
  /// while the dongle was already off would be waiting for it at the next boot
  /// and power it straight back down.
  static const Duration shutdownRequestTtl = Duration(seconds: 90);

  bool get shutdownPending {
    final at = _shutdownRequestedAt;
    return at != null && DateTime.now().difference(at) < shutdownRequestTtl;
  }

  /// Ask the dongle to power off at its next poll.
  void requestDongleShutdown() => _shutdownRequestedAt = DateTime.now();

  void cancelDongleShutdown() => _shutdownRequestedAt = null;

  /// The dongle polls this instead of the app calling the dongle: Android will
  /// not let an app bind a socket to the dongle's Wi-Fi, so phone -> dongle is
  /// impossible, while dongle -> phone is the path the proxy already uses.
  Future<void> _handlePoll(HttpRequest request) async {
    final peer = request.connectionInfo?.remoteAddress.address ?? '';
    final pending = shutdownPending;

    // Only the dongle consumes the flag. Any other client on the AP can read
    // it, but must not clear it out from under the dongle.
    if (pending && peer == dongleIp) {
      _shutdownRequestedAt = null;
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'POLL',
        url: 'shutdown -> $peer',
      ));
    }

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write('{"shutdown":$pending}');
    await request.response.close();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Origin-form request aimed at us rather than at a proxy target.
    if (request.method == 'GET' &&
        request.uri.host.isEmpty &&
        request.uri.path == pollPath) {
      await _handlePoll(request);
      return;
    }
    if (request.method == 'CONNECT') {
      await _handleConnect(request);
    } else {
      await _handleHttp(request);
    }
  }

  /// Handle HTTPS CONNECT tunneling
  Future<void> _handleConnect(HttpRequest request) async {
    final target = request.uri.host.isNotEmpty
        ? request.uri
        : Uri.parse('https://${request.requestedUri.host}:${request.requestedUri.port}');

    final host = target.host.isNotEmpty ? target.host : request.headers.value('host')?.split(':').first ?? '';
    final port = target.port != 0 ? target.port : 443;

    onLog(ProxyLogEntry(
      timestamp: DateTime.now(),
      method: 'CONNECT',
      url: '$host:$port',
    ));

    final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    _trackRequest(clientIp);
    try {
      final socket = await Socket.connect(host, port);
      request.response.statusCode = HttpStatus.ok;
      request.response.reasonPhrase = 'Connection Established';
      request.response.headers.contentLength = -1;
      final clientSocket = await request.response.detachSocket();
      socket.listen((data) { _trackBandwidth(clientIp, data.length); clientSocket.add(data); },
        onDone: clientSocket.close, onError: (_) => clientSocket.close());
      clientSocket.listen((data) { _trackBandwidth(clientIp, data.length); socket.add(data); },
        onDone: socket.close, onError: (_) => socket.close());
    } catch (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'CONNECT',
        url: '$host:$port',
        error: e.toString(),
      ));
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    }
  }

  /// Handle WebSocket upgrade by tunneling raw sockets
  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    final uri = request.requestedUri;
    final host = uri.host;
    final port = uri.port != 0 ? uri.port : 80;
    final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    _trackRequest(clientIp);

    onLog(ProxyLogEntry(
      timestamp: DateTime.now(),
      method: 'WS',
      url: uri.toString(),
    ));

    try {
      final socket = await Socket.connect(host, port);

      // Reconstruct the original HTTP upgrade request to send to the target
      final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
      final buffer = StringBuffer();
      buffer.write('${request.method} $path HTTP/1.1\r\n');
      request.headers.forEach((name, values) {
        for (final v in values) {
          buffer.write('$name: $v\r\n');
        }
      });
      buffer.write('\r\n');
      socket.add(buffer.toString().codeUnits);

      // Detach the client socket and tunnel bidirectionally
      final clientSocket = await request.response.detachSocket(writeHeaders: false);
      socket.listen((data) { _trackBandwidth(clientIp, data.length); clientSocket.add(data); },
        onDone: clientSocket.close, onError: (_) => clientSocket.close());
      clientSocket.listen((data) { _trackBandwidth(clientIp, data.length); socket.add(data); },
        onDone: socket.close, onError: (_) => socket.close());
    } catch (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: 'WS',
        url: uri.toString(),
        error: e.toString(),
      ));
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Handle plain HTTP proxy requests
  Future<void> _handleHttp(HttpRequest request) async {
    // Detect WebSocket upgrade requests
    final upgradeHeader = request.headers.value('upgrade');
    if (upgradeHeader != null && upgradeHeader.toLowerCase() == 'websocket') {
      return _handleWebSocketUpgrade(request);
    }

    final uri = request.requestedUri;
    final method = request.method;
    final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    _trackRequest(clientIp);

    onLog(ProxyLogEntry(
      timestamp: DateTime.now(),
      method: method,
      url: uri.toString(),
    ));

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);

      final proxyRequest = await client.openUrl(method, uri);

      // Forward headers (skip hop-by-hop headers)
      const hopByHop = {
        'proxy-connection',
        'proxy-authorization',
        'te',
        'trailers',
        'transfer-encoding',
      };
      request.headers.forEach((name, values) {
        if (!hopByHop.contains(name.toLowerCase())) {
          for (final v in values) {
            proxyRequest.headers.add(name, v);
          }
        }
      });

      // Forward request body
      await for (final chunk in request) {
        _trackBandwidth(clientIp, chunk.length);
        proxyRequest.add(chunk);
      }
      final proxyResponse = await proxyRequest.close();

      // Forward response status and headers
      request.response.statusCode = proxyResponse.statusCode;
      proxyResponse.headers.forEach((name, values) {
        if (!hopByHop.contains(name.toLowerCase())) {
          for (final v in values) {
            request.response.headers.add(name, v);
          }
        }
      });

      // Forward response body
      await for (final chunk in proxyResponse) {
        _trackBandwidth(clientIp, chunk.length);
        request.response.add(chunk);
      }
      await request.response.close();

      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: method,
        url: uri.toString(),
        statusCode: proxyResponse.statusCode,
      ));

      client.close();
    } catch (e) {
      onLog(ProxyLogEntry(
        timestamp: DateTime.now(),
        method: method,
        url: uri.toString(),
        error: e.toString(),
      ));
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Get the device's local WiFi IP address
  /// This device's address, preferring one on [preferPrefix] when present.
  ///
  /// The proxy listens on anyIPv4, so several addresses are valid; the one worth
  /// showing is the one clients can actually reach it on. On the dongle's AP
  /// that is the 10.0.0.x address, so ask for it explicitly rather than taking
  /// whatever wlan0 happens to hold.
  static Future<String?> getLocalIp({String? preferPrefix}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      if (preferPrefix != null) {
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback && addr.address.startsWith(preferPrefix)) {
              return addr.address;
            }
          }
        }
      }
      for (final iface in interfaces) {
        // Prefer WiFi/WLAN interfaces
        if (iface.name.startsWith('en') ||
            iface.name.startsWith('wlan') ||
            iface.name.startsWith('Wi-Fi')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) return addr.address;
          }
        }
      }
      // Fallback: first non-loopback address
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}

/// Buffered reader for a socket stream that maintains a single subscription.
/// After handshake is done, can forward remaining data to a target socket.
class _SocketReader {
  final Socket _socket;
  final _buffer = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _dataNeeded;
  bool _done = false;

  _SocketReader(this._socket) {
    _subscription = _socket.listen(
      (data) {
        _buffer.addAll(data);
        _dataNeeded?.complete();
        _dataNeeded = null;
      },
      onDone: () {
        _done = true;
        _dataNeeded?.complete();
        _dataNeeded = null;
      },
      onError: (e) {
        _done = true;
        _dataNeeded?.completeError(e);
        _dataNeeded = null;
      },
    );
  }

  /// Read exactly [count] bytes.
  Future<List<int>> read(int count) async {
    while (_buffer.length < count && !_done) {
      _dataNeeded = Completer<void>();
      await _dataNeeded!.future;
    }
    if (_buffer.length < count) {
      throw SocketException('Connection closed during SOCKS handshake');
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  /// Stop reading for handshake and forward all future data (plus any
  /// buffered remainder) to [target]. Calls [onDone] when client disconnects.
  /// Optional [onData] callback receives byte count for each chunk forwarded.
  void forwardTo(Socket target, {required void Function() onDone, void Function(int bytes)? onData}) {
    // Send any buffered data that arrived after the last handshake read
    if (_buffer.isNotEmpty) {
      onData?.call(_buffer.length);
      target.add(_buffer);
      _buffer.clear();
    }

    // Replace listener to forward directly
    _subscription.onData((data) {
      onData?.call(data.length);
      target.add(data);
    });
    _subscription.onDone(() {
      target.close();
      onDone();
    });
    _subscription.onError((_) {
      target.close();
      onDone();
    });
  }
}
