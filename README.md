# Flutter-Proxy

A flutter app to make your Android phone work as a proxy server for other devices

On Android, starting the proxy launches a visible foreground service. The proxy
sockets live in that service's Dart isolate, so traffic continues when the app
is minimized, removed from Recents, restarted after an unexpected process stop,
or rebooted while the proxy was active. Tap **Stop** before closing the app when
you do not want the proxy to restart.

Android 13 and later may ask for notification permission when the proxy starts.
Some manufacturers also require disabling battery optimization for reliable
long-running services.

## iOS limitation

iOS does not permit an ordinary app to host an always-on proxy in the
background. The configured background task can run only periodically; a true
continuous iOS proxy requires an Apple Network Extension entitlement and a
native Network Extension target.
