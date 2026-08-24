package com.example.proxy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val cellularChannel = "com.example.proxy/cellular"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cellularChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "attach" -> result.success(
                        CellularNetwork.attach(applicationContext)
                    )
                    "detach" -> {
                        CellularNetwork.detach(applicationContext)
                        result.success(null)
                    }
                    "isAttached" -> result.success(CellularNetwork.isAttached)
                    else -> result.notImplemented()
                }
            }
    }
}
