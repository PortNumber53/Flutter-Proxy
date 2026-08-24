import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to `shutdownd` on the WirelessAndroidAutoDongle.
///
/// The dongle is normally killed by pulling car power, which cuts the SD card
/// mid-write. This asks it to power down cleanly instead.
///
/// On Android the request goes through a platform channel that binds it to the
/// Wi-Fi network. That is not optional: the dongle's AP has no internet, so
/// Android keeps cellular as the default network, and an unbound socket aimed at
/// 10.0.0.1 is routed out the cellular interface and lost. Android's routing
/// rules key off the output interface, so binding the source address does not
/// help either -- only `Network.openConnection()` reaches the dongle, and
/// `dart:io` has no equivalent.
class DongleControl {
  DongleControl({
    this.host = defaultHost,
    this.port = defaultPort,
    this.token = '',
  });

  /// The dongle's address on its own AP (`AAWirelessDongle`).
  static const String defaultHost = '10.0.0.1';
  static const int defaultPort = 8081;

  static const MethodChannel _channel =
      MethodChannel('com.example.proxy/wifi_http');

  final String host;
  final int port;

  /// Only needed if `AAWG_EXTRA_SHUTDOWN_TOKEN` is set in the dongle's
  /// `/boot/aawgd.conf`. Empty means the endpoint accepts any AP client.
  final String token;

  static const Duration _timeout = Duration(seconds: 6);

  /// ({status, body}) from whichever transport applies to this platform.
  Future<({int status, String body})> _send(String method, String path) async {
    final url = 'http://$host:$port$path';

    if (Platform.isAndroid) {
      final res = await _channel.invokeMapMethod<String, dynamic>('request', {
        'url': url,
        'method': method,
        'token': token,
        'timeoutMs': _timeout.inMilliseconds,
      });
      if (res == null) throw const SocketException('No response from platform channel');
      return (status: res['status'] as int, body: (res['body'] as String?) ?? '');
    }

    // Non-Android: plain dart:io, no network binding needed.
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.openUrl(method, Uri.parse(url)).timeout(_timeout);
      if (token.isNotEmpty) req.headers.set('X-Auth-Token', token);
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      final res = await req.close().timeout(_timeout);
      final body = await res.transform(utf8.decoder).join().timeout(_timeout);
      return (status: res.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  /// True if the dongle is reachable and running `shutdownd`.
  Future<bool> ping() async {
    try {
      return (await _send('GET', '/ping')).status == 200;
    } catch (_) {
      return false;
    }
  }

  /// Ask the dongle to power down. POST, not GET, so a stray prefetch or a
  /// mistyped URL can never take the car's head-unit link down.
  ///
  /// Returns null on success, or a human-readable reason on failure.
  Future<String?> shutdown() async {
    try {
      final res = await _send('POST', '/shutdown');
      if (res.status == 200) return null;
      if (res.status == 403) {
        return 'Dongle rejected the request: bad or missing token.';
      }
      return 'Dongle returned HTTP ${res.status}: ${res.body}';
    } on PlatformException catch (e) {
      if (e.code == 'no_wifi') {
        return 'Not connected to Wi-Fi. Join the dongle\'s network first.';
      }
      // Android refuses to let an app bind a socket to a network it was not
      // granted, and it will not grant the dongle's AP because that AP has no
      // internet. Every request to 10.0.0.1 is then routed out the cellular
      // interface and lost. There is no user-side workaround -- turning mobile
      // data off does not help, because Android still declines to make the
      // unvalidated Wi-Fi the default network.
      final msg = e.message ?? '';
      if (msg.contains('EPERM') || msg.contains('Binding socket')) {
        return 'This phone cannot reach the dongle: Android routes app traffic '
            'over mobile data and will not let the app use the dongle\'s Wi-Fi. '
            'Shut it down from a Wi-Fi-only device, or unplug it.';
      }
      return 'Could not reach the dongle at $host:$port. '
          'Are you on its Wi-Fi? ($msg)';
    } on SocketException catch (e) {
      return 'Could not reach the dongle at $host:$port. '
          '(${e.osError?.message ?? e.message})';
    } on TimeoutException {
      return 'Timed out talking to the dongle at $host:$port.';
    } catch (e) {
      return 'Shutdown failed: $e';
    }
  }
}
