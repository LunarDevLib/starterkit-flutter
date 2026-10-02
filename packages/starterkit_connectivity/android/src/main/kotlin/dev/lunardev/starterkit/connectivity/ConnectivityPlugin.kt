package dev.lunardev.starterkit.connectivity

import android.Manifest
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/** Installs only the channel during engine attachment; observation is subscription-driven. */
class ConnectivityPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventChannel: EventChannel? = null
    private var connectivityManager: ConnectivityManager? = null
    private var eventSink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var generation = 0L
    private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = true
        appContext = binding.applicationContext
        connectivityManager = binding.applicationContext
            .getSystemService(ConnectivityManager::class.java)
        eventChannel = EventChannel(
            binding.binaryMessenger,
            "starterkit/connectivity/events",
        ).also { it.setStreamHandler(this) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stopObservation()
        val currentGeneration = generation
        eventSink = events
        val context = connectivityManager ?: run {
            postStatus(currentGeneration, "unknown")
            return
        }
        // Apps must explicitly declare this permission. Never request it here.
        val appContext = appContext ?: run {
            postStatus(currentGeneration, "unknown")
            return
        }
        val permissionGranted = try {
            appContext.checkSelfPermission(Manifest.permission.ACCESS_NETWORK_STATE) ==
                PackageManager.PERMISSION_GRANTED
        } catch (_: RuntimeException) {
            postStatus(currentGeneration, "unknown")
            return
        }
        if (!permissionGranted) {
            postStatus(currentGeneration, "unknown")
            return
        }

        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = publishCurrent(context, currentGeneration)
            override fun onLost(network: Network) = publishCurrent(context, currentGeneration)
            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = publishCurrent(context, currentGeneration)
        }
        callback = networkCallback
        try {
            context.registerDefaultNetworkCallback(networkCallback)
            publishCurrent(context, currentGeneration)
        } catch (_: SecurityException) {
            reportFailure(currentGeneration)
        } catch (_: RuntimeException) {
            reportFailure(currentGeneration)
        }
    }

    override fun onCancel(arguments: Any?) = stopObservation()

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        stopObservation()
        connectivityManager = null
        appContext = null
    }

    private var appContext: android.content.Context? = null

    private fun publishCurrent(manager: ConnectivityManager, token: Long) {
        val status = try {
            val network = manager.activeNetwork
            if (network == null) {
                "offline"
            } else {
                val capabilities = manager.getNetworkCapabilities(network)
                    ?: return reportFailure(token)
                if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                    "onlineLike"
                } else {
                    "offline"
                }
            }
        } catch (_: SecurityException) {
            return reportFailure(token)
        } catch (_: RuntimeException) {
            return reportFailure(token)
        }
        postStatus(token, status)
    }

    private fun reportFailure(token: Long) {
        mainHandler.post {
            if (!attached || token != generation) return@post
            val sink = eventSink
            unregisterCallback()
            generation += 1
            eventSink = sink
            eventSink?.success("unknown")
        }
    }

    private fun postStatus(token: Long, status: String) {
        mainHandler.post {
            if (attached && token == generation) eventSink?.success(status)
        }
    }

    private fun stopObservation() {
        generation += 1
        unregisterCallback()
        eventSink = null
    }

    private fun unregisterCallback() {
        val oldCallback = callback
        callback = null
        if (oldCallback != null) {
            try {
                connectivityManager?.unregisterNetworkCallback(oldCallback)
            } catch (_: IllegalArgumentException) {
                // It may not have been registered (or may already be unregistered).
            } catch (_: RuntimeException) {
                // Teardown is best-effort and must remain idempotent.
            }
        }
    }
}
