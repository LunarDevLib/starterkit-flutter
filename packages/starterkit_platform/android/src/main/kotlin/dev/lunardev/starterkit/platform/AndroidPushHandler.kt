package dev.lunardev.starterkit.platform

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Explicit-call-only Android notification permission adapter; registration is inert. */
internal class AndroidPushHandler(
    private val context: Context,
    private val main: Handler = Handler(Looper.getMainLooper()),
) : MethodChannel.MethodCallHandler {
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: PendingPermission? = null
    private var engineAttached = true
    private var engineGeneration = 0L

    private class PendingPermission(
        val state: PushOperationState,
        var binding: ActivityPluginBinding?,
        var result: MethodChannel.Result?,
        var listener: PluginRegistry.RequestPermissionsResultListener?,
    )

    fun onAttachedToActivity(binding: ActivityPluginBinding) { activityBinding = binding }

    fun onActivityDetached() {
        settle(pending, PushPolicy.response("failure", "push.activity_detached"))
        activityBinding = null
    }

    fun onEngineDetached() {
        engineAttached = false
        engineGeneration++
        settle(pending, PushPolicy.response("failure", "push.engine_detached"))
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "permissionStatus" && call.method != "requestPermission") {
            result.notImplemented()
            return
        }
        if (Looper.myLooper() == main.looper) {
            dispatch(call, result)
            return
        }
        val generation = engineGeneration
        try {
            if (!main.post {
                    if (!engineAttached || generation != engineGeneration) {
                        result.success(PushPolicy.response("failure", "push.engine_detached"))
                    } else {
                        dispatch(call, result)
                    }
                }
            ) result.success(PushPolicy.response("failure", "push.dispatch_failed"))
        } catch (_: Throwable) {
            result.success(PushPolicy.response("failure", "push.dispatch_failed"))
        }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        if (!PushPolicy.parseNoArguments(call.arguments)) {
            result.success(PushPolicy.response("invalid", "push.invalid_arguments"))
            return
        }
        when (call.method) {
            "permissionStatus" -> result.success(readStatus())
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (pending != null) {
            result.success(PushPolicy.response("conflict", "push.operation_in_progress"))
            return
        }
        val api33OrLater = Build.VERSION.SDK_INT >= 33
        val configured = !api33OrLater || hasPermissionDeclaration()
        if (!configured) {
            result.success(PushPolicy.response("unavailable", "push.permission_not_configured"))
            return
        }
        if (!api33OrLater) {
            result.success(readStatus())
            return
        }
        if (hasRuntimePermission()) {
            result.success(readStatus())
            return
        }
        val binding = activityBinding
        val activity = binding?.activity
        if (binding == null || activity == null || !isForegroundActivity(activity, binding)) {
            result.success(PushPolicy.response("unavailable", "push.activity_unavailable"))
            return
        }
        val requestCode = PushPolicy.requestCode()
        if (requestCode == null) {
            result.success(PushPolicy.response("failure", "push.permission_failed"))
            return
        }
        val operation = PendingPermission(PushOperationState(PushTicket(requestCode)), binding, result, null)
        val listener = PluginRegistry.RequestPermissionsResultListener { code, permissions, grants ->
            onPermissionResult(operation, code, permissions, grants)
        }
        operation.listener = listener
        pending = operation
        try {
            binding.addRequestPermissionsResultListener(listener)
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestCode)
        } catch (_: Throwable) {
            settle(operation, PushPolicy.response("failure", "push.permission_failed"))
        }
    }

    private fun onPermissionResult(
        operation: PendingPermission,
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (pending !== operation || requestCode != operation.state.ticket.requestCode) return false
        if (!PushPolicy.isExpectedPermissionCallback(requestCode, operation.state.ticket, permissions, grantResults)) {
            settle(operation, PushPolicy.response("failure", "push.permission_failed"))
            return true
        }
        val granted = grantResults[0] == PackageManager.PERMISSION_GRANTED
        val notificationsEnabled = runCatching { notificationManager().areNotificationsEnabled() }.getOrDefault(false)
        settle(operation, PushPolicy.permissionResult(granted, notificationsEnabled))
        return true
    }

    private fun readStatus(): Map<String, String> = try {
        val api33OrLater = Build.VERSION.SDK_INT >= 33
        val declared = !api33OrLater || hasPermissionDeclaration()
        if (api33OrLater && !declared) {
            PushPolicy.status(true, false, false, false)
        } else {
            PushPolicy.status(
                api33OrLater = api33OrLater,
                permissionDeclared = declared,
                permissionGranted = !api33OrLater || hasRuntimePermission(),
                notificationsEnabled = notificationManager().areNotificationsEnabled(),
            )
        }
    } catch (_: Throwable) {
        PushPolicy.response("unavailable", "push.platform_unavailable")
    }

    private fun hasPermissionDeclaration(): Boolean = try {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.contains(Manifest.permission.POST_NOTIFICATIONS) == true
    } catch (_: Throwable) {
        false
    }

    private fun hasRuntimePermission(): Boolean = try {
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) {
        false
    }

    private fun notificationManager(): NotificationManager =
        context.getSystemService(NotificationManager::class.java)
            ?: throw IllegalStateException("notification service unavailable")

    private fun isForegroundActivity(activity: Activity, binding: ActivityPluginBinding): Boolean {
        if (binding.activity !== activity || activity.isFinishing || activity.isDestroyed) return false
        return try {
            val decor = activity.window.decorView
            PushPolicy.foregroundActivity(
                attached = activityBinding === binding,
                finishing = activity.isFinishing,
                destroyed = activity.isDestroyed,
                focused = activity.hasWindowFocus(),
                visible = decor.visibility == View.VISIBLE && decor.isShown && decor.isAttachedToWindow,
            )
        } catch (_: Throwable) {
            false
        }
    }

    private fun settle(operation: PendingPermission?, outcome: Map<String, String>) {
        if (operation == null || pending !== operation || !operation.state.settle()) return
        pending = null
        val listener = operation.listener
        operation.listener = null
        val binding = operation.binding
        operation.binding = null
        if (listener != null) runCatching { binding?.removeRequestPermissionsResultListener(listener) }
        val callback = operation.result
        operation.result = null
        runCatching { callback?.success(outcome) }
    }
}
