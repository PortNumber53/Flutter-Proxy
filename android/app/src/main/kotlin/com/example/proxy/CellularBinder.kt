package com.example.proxy

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

/**
 * Pins this process's outbound traffic to the mobile network.
 *
 * The proxy exists to relay clients on the dongle's Wi-Fi out over cellular, and
 * it used to get that for free: the dongle AP has no internet, so Android kept
 * cellular as the default network and unbound sockets went the right way.
 *
 * That is not dependable. Android decided the dongle AP was VALIDATED and made
 * it the default network; since the dongle advertises no gateway
 * (dhcp-option=3), every outbound socket then failed with "Network is
 * unreachable" and the phone itself lost internet. Binding explicitly removes
 * the dependency on which network Android happens to prefer.
 *
 * Process-wide rather than per-socket because dart:io exposes no way to bind an
 * individual socket. Binding is applied only after the proxy's listeners exist,
 * so the sockets accepting clients on Wi-Fi are unaffected.
 */
object CellularBinder {
    private const val TAG = "CellularBinder"
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var bound: Network? = null

    val isBound: Boolean get() = bound != null

    @Synchronized
    fun start(context: Context): Boolean {
        if (callback != null) return true
        val cm = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Requesting the network is what makes us allowed to bind to it.
                val ok = cm.bindProcessToNetwork(network)
                bound = if (ok) network else null
                Log.i(TAG, "cellular available, bindProcessToNetwork=$ok")
            }

            override fun onLost(network: Network) {
                if (bound == network) {
                    cm.bindProcessToNetwork(null)
                    bound = null
                    Log.i(TAG, "cellular lost, unbound")
                }
            }
        }

        return try {
            cm.requestNetwork(request, cb)
            callback = cb
            true
        } catch (e: SecurityException) {
            // Needs CHANGE_NETWORK_STATE; without it we simply stay unbound and
            // fall back to whatever Android picks.
            Log.e(TAG, "requestNetwork denied", e)
            false
        }
    }

    @Synchronized
    fun stop(context: Context) {
        val cm = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.bindProcessToNetwork(null)
        bound = null
        callback?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {}
        }
        callback = null
        Log.i(TAG, "unbound")
    }
}
