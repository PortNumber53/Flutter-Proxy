package com.example.proxy

import android.content.Context
import android.util.Log
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Bridges HTTP requests that must go over Wi-Fi rather than the default network.
 *
 * The dongle sits on a Wi-Fi AP with no internet, so Android never promotes it to
 * the default network -- which is exactly why the proxy's upstream sockets reach
 * cellular without any help. The flip side is that an unbound socket aimed at
 * 10.0.0.1 also leaves via cellular and dies: `ip route get 10.0.0.1` resolves
 * via rmnet, and Android's routing rules key off the output interface
 * (`from all iif lo oif wlan0 lookup 1016`), so binding the source address is not
 * enough either.
 *
 * Network.openConnection() returns a connection bound to that specific network,
 * which is the only way to reach the dongle. dart:io exposes no equivalent.
 */
class MainActivity : FlutterActivity() {
    private val channel = "com.example.proxy/wifi_http"
    private val TAG = "DongleControl"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindCellular" -> {
                        val ok = CellularBinder.start(applicationContext)
                        result.success(ok)
                        return@setMethodCallHandler
                    }
                    "unbindCellular" -> {
                        CellularBinder.stop(applicationContext)
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    "isCellularBound" -> {
                        result.success(CellularBinder.isBound)
                        return@setMethodCallHandler
                    }
                }
                if (call.method != "request") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")
                val method = call.argument<String>("method") ?: "GET"
                val token = call.argument<String>("token") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
                if (url == null) {
                    result.error("bad_args", "url is required", null)
                    return@setMethodCallHandler
                }
                // Off the main thread: this does real network I/O.
                thread { requestOverWifi(url, method, token, timeoutMs, result) }
            }
    }

    /**
     * Acquire a Wi-Fi network we are actually allowed to bind to.
     *
     * Picking one out of `allNetworks` is not enough: binding then fails with
     * EPERM, because an app may only bind to a network it has requested. So ask
     * for one and wait for the callback. The request deliberately does not
     * demand a *validated* internet connection -- the dongle AP has none, which
     * is the whole reason this class exists.
     */
    private fun acquireWifiNetwork(timeoutMs: Int): Pair<Network?, ConnectivityManager.NetworkCallback?> {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        // The dongle AP advertises no NET_CAPABILITY_INTERNET on a phone that also
        // has cellular, and NetworkRequest.Builder requires INTERNET by default,
        // so a plain request is never satisfied. Drop it explicitly.
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val latch = CountDownLatch(1)
        val found = AtomicReference<Network?>(null)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                found.set(network)
                latch.countDown()
            }
            override fun onUnavailable() {
                latch.countDown()
            }
        }
        return try {
            cm.requestNetwork(req, cb, timeoutMs)
            val fired = latch.await(timeoutMs.toLong() + 500, TimeUnit.MILLISECONDS)
            val n = found.get()
            Log.i(TAG, "requestNetwork: fired=$fired network=$n")
            if (n == null) {
                // Fall back to scanning what is already up.
                val alt = cm.allNetworks.firstOrNull { c ->
                    cm.getNetworkCapabilities(c)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
                Log.i(TAG, "fallback allNetworks wifi=$alt of ${cm.allNetworks.size}")
                if (alt != null) return Pair(alt, cb)
            }
            Pair(n, cb)
        } catch (e: SecurityException) {
            Log.e(TAG, "requestNetwork SecurityException", e)
            try { cm.unregisterNetworkCallback(cb) } catch (_: Exception) {}
            Pair(null, null)
        } catch (e: Exception) {
            Log.e(TAG, "requestNetwork failed", e)
            try { cm.unregisterNetworkCallback(cb) } catch (_: Exception) {}
            Pair(null, null)
        }
    }

    private fun release(cb: ConnectivityManager.NetworkCallback?) {
        if (cb == null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        try { cm.unregisterNetworkCallback(cb) } catch (_: Exception) {}
    }

    private fun requestOverWifi(
        url: String, method: String, token: String, timeoutMs: Int, result: MethodChannel.Result
    ) {
        val (net, cb) = acquireWifiNetwork(timeoutMs)
        if (net == null) {
            release(cb)
            runOnUiThread {
                result.error("no_wifi", "Not connected to any Wi-Fi network.", null)
            }
            return
        }
        var conn: HttpURLConnection? = null
        try {
            conn = (net.openConnection(URL(url)) as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                useCaches = false
                setRequestProperty("Connection", "close")
                if (token.isNotEmpty()) setRequestProperty("X-Auth-Token", token)
                if (method == "POST") {
                    doOutput = true
                    setFixedLengthStreamingMode(0)
                }
            }
            conn.connect()
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.bufferedReader()?.use(BufferedReader::readText) ?: ""
            Log.i(TAG, "$method $url -> $status")
            runOnUiThread { result.success(mapOf("status" to status, "body" to body)) }
        } catch (e: Exception) {
            Log.e(TAG, "request failed", e)
            runOnUiThread {
                result.error("request_failed", e.message ?: e.toString(), null)
            }
        } finally {
            conn?.disconnect()
            release(cb)
        }
    }
}
