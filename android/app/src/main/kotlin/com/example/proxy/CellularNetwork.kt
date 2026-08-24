package com.example.proxy

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

/** Pins this process's new outbound sockets to cellular until explicitly stopped. */
object CellularNetwork {
    private const val TAG = "CellularNetwork"

    private var callback: ConnectivityManager.NetworkCallback? = null

    @Volatile
    private var attachedNetwork: Network? = null

    val isAttached: Boolean
        get() = attachedNetwork != null

    @Synchronized
    fun attach(context: Context): Boolean {
        if (callback != null) return true

        val manager = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handleAvailable(this, manager, network)
            }

            override fun onLost(network: Network) {
                handleLost(this, network)
            }
        }

        callback = networkCallback
        return try {
            manager.requestNetwork(request, networkCallback)
            true
        } catch (error: SecurityException) {
            callback = null
            Log.e(TAG, "Cellular network request denied", error)
            false
        }
    }

    @Synchronized
    private fun handleAvailable(
        source: ConnectivityManager.NetworkCallback,
        manager: ConnectivityManager,
        network: Network,
    ) {
        if (callback !== source) return
        val attached = manager.bindProcessToNetwork(network)
        attachedNetwork = if (attached) network else null
        Log.i(TAG, "Cellular available; attached=$attached")
    }

    @Synchronized
    private fun handleLost(
        source: ConnectivityManager.NetworkCallback,
        network: Network,
    ) {
        if (callback !== source || attachedNetwork != network) return

        // Do not bind to the default network here. Remaining pinned to the
        // lost network makes new proxy connections fail closed until Android
        // supplies another cellular network.
        attachedNetwork = null
        Log.i(TAG, "Cellular lost; waiting for a replacement")
    }

    @Synchronized
    fun detach(context: Context) {
        val manager = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        callback?.let {
            try {
                manager.unregisterNetworkCallback(it)
            } catch (_: RuntimeException) {
                // It may already have been unregistered by Android.
            }
        }
        callback = null
        attachedNetwork = null
        manager.bindProcessToNetwork(null)
        Log.i(TAG, "Detached from cellular")
    }
}
