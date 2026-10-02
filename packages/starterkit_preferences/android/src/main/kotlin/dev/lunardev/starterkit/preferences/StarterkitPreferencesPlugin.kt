package dev.lunardev.starterkit.preferences

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Installs a handler only; preference storage and its worker are operation-lazy. */
class StarterkitPreferencesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val policy = PreferencesHandlerPolicy { completion ->
        mainHandler.post { completion() }
    }
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        policy.attach(
            storageFactory = {
                SharedPreferencesStorage(
                    binding.applicationContext.getSharedPreferences(
                        "starterkit_preferences_v1",
                        Context.MODE_PRIVATE,
                    ),
                )
            },
            workerFactory = {
                val thread = HandlerThread("starterkit-preferences")
                thread.start()
                try {
                    HandlerWorker(Handler(thread.looper), thread)
                } catch (failure: RuntimeException) {
                    thread.quitSafely()
                    throw failure
                }
            },
        )
        channel = MethodChannel(binding.binaryMessenger, "starterkit/preferences").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        policy.onMethodCall(call.method, call.arguments) { value, error ->
            if (error != null) result.error(error, null, null) else result.success(value)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        policy.detach()
    }

    private class SharedPreferencesStorage(
        private val preferences: android.content.SharedPreferences,
    ) : PreferencesStorage {
        override fun read(key: String): Any? = preferences.all[key]

        override fun write(key: String, value: String): Boolean =
            preferences.edit().putString(key, value).commit()

        override fun remove(key: String): Boolean = preferences.edit().remove(key).commit()
    }

    private class HandlerWorker(
        private val handler: Handler,
        private val thread: HandlerThread,
    ) : PreferencesWorker {
        override fun post(task: () -> Unit): Boolean = handler.post { task() }
        override fun clear() = handler.removeCallbacksAndMessages(null)
        override fun quit() {
            thread.quitSafely()
        }
    }
}
