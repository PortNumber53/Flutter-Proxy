import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Controls the Android process binding used by the proxy's upstream sockets.
class CellularNetwork {
  static const MethodChannel _channel = MethodChannel(
    'com.example.proxy/cellular',
  );

  /// Pins sockets created after this call to Android's cellular network.
  ///
  /// The proxy listeners must be opened before calling this method so they
  /// remain reachable from clients on Wi-Fi.
  static Future<void> attach({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!Platform.isAndroid) return;

    final requested = await _channel.invokeMethod<bool>('attach') ?? false;
    if (!requested) {
      throw const CellularNetworkException(
        'Android did not allow access to the cellular network.',
      );
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final attached = await _channel.invokeMethod<bool>('isAttached') ?? false;
      if (attached) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await detach();
    throw const CellularNetworkException(
      'No cellular internet connection became available.',
    );
  }

  static Future<void> detach() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('detach');
  }
}

class CellularNetworkException implements Exception {
  const CellularNetworkException(this.message);

  final String message;

  @override
  String toString() => message;
}
