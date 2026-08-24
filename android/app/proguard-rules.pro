# flutter_foreground_task registers its Service and Receiver by class name from
# the plugin, and the manifest entries are written by the plugin's own manifest.
# R8 was renaming those classes, so startService() failed at runtime with
#   "Unable to start service Intent { cmp=com.example.proxy/h0.a }: not found"
# and the proxy silently ran with no foreground service at all -- which let
# Samsung's Freecess freeze the process mid-session.
-keep class com.pravera.flutter_foreground_task.** { *; }
-keep class * extends android.app.Service { *; }
-keep class * extends android.content.BroadcastReceiver { *; }

# Flutter embedding entry points.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }

# Flutter references Play Core's deferred-component APIs, which this app does
# not ship. Nothing calls them at runtime; R8 only needs to stop warning.
-dontwarn com.google.android.play.core.**
