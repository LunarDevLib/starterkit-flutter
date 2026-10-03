package dev.lunardev.starterkit.platform

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.DialogInterface
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/** Explicit-call-only Android framework adapter for the independent Biometric channel. */
internal class AndroidBiometricHandler(
    private val context: Context,
    private val main: Handler = Handler(Looper.getMainLooper()),
) : MethodChannel.MethodCallHandler {
    private val fence = BiometricOperationFence()
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: PendingBiometricOperation? = null

    fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    fun onActivityDetached() {
        pending?.let { finish(it, "cancelled", "biometric.activity_detached") }
        activityBinding = null
    }

    fun onEngineDetached() {
        pending?.let { finish(it, "cancelled", "biometric.engine_detached") }
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "biometricAvailability" -> availability(call.arguments, result)
            "authenticateBiometric" -> authenticate(call.arguments, result)
            "cancelBiometric" -> result.success(cancel(call.arguments))
            else -> result.notImplemented()
        }
    }

    private fun availability(arguments: Any?, result: MethodChannel.Result) {
        if (!BiometricPolicy.parseAvailabilityRequest(arguments)) {
            result.success(
                BiometricPolicy.availabilityEnvelope(
                    BiometricAvailability(
                        BiometricAvailabilityState.UNAVAILABLE,
                        "biometric.invalid_request",
                    ),
                ),
            )
            return
        }
        result.success(BiometricPolicy.availabilityEnvelope(readAvailability()))
    }

    private fun authenticate(arguments: Any?, result: MethodChannel.Result) {
        when (val parsed = BiometricPolicy.parseAuthenticateRequest(arguments)) {
            is BiometricParseResult.InvalidRequest -> {
                result.success(
                    BiometricPolicy.authenticationEnvelope(
                        "invalid",
                        "biometric.invalid_request",
                        parsed.requestId.orEmpty(),
                    ),
                )
                return
            }
            is BiometricParseResult.InvalidReason -> {
                result.success(
                    BiometricPolicy.authenticationEnvelope(
                        "denied",
                        "biometric.invalid_reason",
                        parsed.requestId,
                    ),
                )
                return
            }
            is BiometricParseResult.Valid -> startAuthentication(parsed.request, result)
        }
    }

    private fun startAuthentication(request: BiometricRequest, result: MethodChannel.Result) {
        val ticket = when (val started = fence.begin(request.requestId)) {
            is BiometricOperationStart.Conflict -> {
                result.success(
                    BiometricPolicy.authenticationEnvelope(
                        "conflict",
                        "biometric.operation_in_progress",
                        request.requestId,
                    ),
                )
                return
            }
            is BiometricOperationStart.Started -> started.ticket
        }
        val operation = PendingBiometricOperation(ticket, this, result, request.reason)
        pending = operation

        val available = readAvailability()
        if (available.state != BiometricAvailabilityState.READY) {
            val refusal = BiometricPolicy.authenticationPreflight(available, request.requestId)
            finish(
                operation,
                refusal["kind"] as String,
                refusal["code"] as String,
            )
            return
        }

        val activity = activityBinding?.activity
        if (activity == null || !BiometricPolicy.shouldOpenPrompt(available, hostSnapshot(activity))) {
            finish(operation, "unavailable", "biometric.foreground_required")
            return
        }
        operation.activity = activity
        if (!installLifecycleObserver(operation, activity)) {
            finish(operation, "failure", "biometric.platform_failure")
            return
        }

        val cancellationSignal = CancellationSignal()
        val startOutcome = BiometricDriverStart.start(
            fence = fence,
            ticket = ticket,
            cancelNative = { cancellationSignal.cancel() },
            startNative = {
                // The same signal is installed in the fence before authenticate can start.
                if (fence.isCurrent(ticket)) {
                    AndroidBiometricApi29.startPrompt(
                        activity = activity,
                        reason = request.reason,
                        executor = Executor { callback -> main.post(callback) },
                        events = operation,
                        cancellationSignal = cancellationSignal,
                    )
                }
            },
        )
        when (startOutcome) {
            BiometricDriverStartOutcome.STARTED,
            BiometricDriverStartOutcome.NOT_STARTED -> Unit
            BiometricDriverStartOutcome.PERMISSION_REJECTED,
            BiometricDriverStartOutcome.FAILURE -> {
                val (kind, code) = requireNotNull(BiometricPolicy.promptStartFailure(startOutcome))
                finish(operation, kind, code)
            }
        }
    }

    private fun readAvailability(): BiometricAvailability {
        val sdkInt = Build.VERSION.SDK_INT
        val declaredAndGranted = hasBiometricPermission()
        val platform = if (declaredAndGranted.first && declaredAndGranted.second &&
            BiometricPolicy.frameworkPolicy(sdkInt) != BiometricFrameworkPolicy.UNSUPPORTED
        ) {
            try {
                AndroidBiometricApi29.canAuthenticate(context, sdkInt)
            } catch (_: SecurityException) {
                return BiometricPolicy.availabilityFailure(BiometricAvailabilityFailure.PERMISSION)
            } catch (_: Throwable) {
                return BiometricPolicy.availabilityFailure(BiometricAvailabilityFailure.PLATFORM)
            }
        } else {
            BiometricPlatformAvailability.UNKNOWN
        }
        return BiometricPolicy.availability(
            sdkInt,
            permissionDeclared = declaredAndGranted.first,
            permissionGranted = declaredAndGranted.second,
            platform = platform,
        )
    }

    private fun hasBiometricPermission(): Pair<Boolean, Boolean> {
        val declared = runCatching {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_PERMISSIONS,
            ).requestedPermissions?.contains(USE_BIOMETRIC_PERMISSION) == true
        }.getOrDefault(false)
        if (!declared) return false to false
        val granted = runCatching {
            context.checkSelfPermission(USE_BIOMETRIC_PERMISSION) ==
                PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
        return declared to granted
    }

    private fun installLifecycleObserver(
        operation: PendingBiometricOperation,
        activity: Activity,
    ): Boolean {
        val application = context.applicationContext as? Application ?: return false
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

            override fun onActivityStopped(activity: Activity) {
                if (activity === operation.activity && fence.isCurrent(operation.ticket) &&
                    BiometricPolicy.shouldCancelForLifecycle(BiometricLifecycleEvent.STOPPED)
                ) {
                    finish(operation, "cancelled", "biometric.backgrounded")
                }
            }

            override fun onActivityDestroyed(activity: Activity) {
                if (activity === operation.activity && fence.isCurrent(operation.ticket) &&
                    BiometricPolicy.shouldCancelForLifecycle(BiometricLifecycleEvent.DESTROYED)
                ) {
                    finish(operation, "cancelled", "biometric.activity_detached")
                }
            }
        }
        operation.lifecycleCallbacks = callbacks
        return try {
            application.registerActivityLifecycleCallbacks(callbacks)
            operation.cleanup.add { application.unregisterActivityLifecycleCallbacks(callbacks) }
            true
        } catch (_: Throwable) {
            operation.lifecycleCallbacks = null
            false
        }
    }

    private fun hostSnapshot(activity: Activity): BiometricHostSnapshot? =
        runCatching {
            val owner = activity as? LifecycleOwner ?: return null
            val process = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(process)
            val decor = activity.window.decorView
            BiometricHostSnapshot(
                currentActivity = activityBinding?.activity === activity,
                started = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED),
                resumed = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED),
                processForeground = process.importance ==
                    ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND,
                windowFocused = activity.hasWindowFocus(),
                windowVisible = decor.visibility == View.VISIBLE && decor.isShown && decor.isAttachedToWindow,
                finishing = activity.isFinishing,
                destroyed = activity.isDestroyed,
            )
        }.getOrNull()

    private fun isCurrentForegroundCallback(operation: PendingBiometricOperation): Boolean {
        val activity = operation.activity ?: return false
        return hostSnapshot(activity)?.let(BiometricPolicy::canDeliverSuccess) == true
    }

    private fun cancel(arguments: Any?): Boolean {
        val requestId = BiometricPolicy.parseCancelRequest(arguments) ?: return false
        val ticket = fence.matchingPending(requestId) ?: return false
        val operation = pending?.takeIf { it.ticket === ticket } ?: return false
        return finish(operation, "cancelled", "biometric.cancelled")
    }

    private fun finish(
        operation: PendingBiometricOperation,
        kind: String,
        code: String,
    ): Boolean {
        if (!fence.settle(operation.ticket)) return false
        if (pending === operation) pending = null
        operation.lifecycleCallbacks = null
        operation.cleanup.close()
        // Settle() cancels the platform signal exactly once, including successful authentication.
        val response = BiometricPolicy.authenticationEnvelope(kind, code, operation.ticket.requestId)
        val result = operation.result
        operation.release()
        runCatching { result?.success(response) }
        return true
    }

    private fun onPromptFailed(operation: PendingBiometricOperation) {
        // AuthenticationFailed is a retry notification, not a terminal denial or success.
        fence.noteAuthenticationFailed(operation.ticket)
    }

    private fun onPromptSuccess(
        operation: PendingBiometricOperation,
        authenticationType: BiometricAuthenticationType?,
    ) {
        if (!fence.isCurrent(operation.ticket)) return
        if (!isCurrentForegroundCallback(operation)) {
            finish(operation, "cancelled", "biometric.backgrounded")
            return
        }
        val successCode = BiometricPolicy.successCode(Build.VERSION.SDK_INT, authenticationType)
        if (successCode == null) {
            finish(operation, "failure", "biometric.platform_failure")
        } else {
            finish(operation, "authenticated", successCode)
        }
    }

    private fun onPromptError(operation: PendingBiometricOperation, error: BiometricPromptError) {
        if (!fence.isCurrent(operation.ticket)) return
        val (kind, code) = BiometricPolicy.promptError(error)
        finish(operation, kind, code)
    }

    private class PendingBiometricOperation(
        val ticket: BiometricOperationTicket,
        owner: AndroidBiometricHandler,
        result: MethodChannel.Result,
        val reason: String,
    ) : BiometricPromptEvents {
        var owner: AndroidBiometricHandler? = owner
        var result: MethodChannel.Result? = result
        var activity: Activity? = null
        var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null
        val cleanup = BiometricOperationCleanup()

        override fun onAuthenticationFailed() {
            owner?.onPromptFailed(this)
        }

        override fun onAuthenticationSucceeded(type: BiometricAuthenticationType?) {
            owner?.onPromptSuccess(this, type)
        }

        override fun onAuthenticationError(error: BiometricPromptError) {
            owner?.onPromptError(this, error)
        }

        fun release() {
            owner = null
            result = null
            activity = null
            lifecycleCallbacks = null
            cleanup.close()
        }
    }

    private companion object {
        const val USE_BIOMETRIC_PERMISSION = "android.permission.USE_BIOMETRIC"
    }
}

/** API-29+ references are isolated in this lazily loaded class; API 24..28 never resolve it. */
private object AndroidBiometricApi29 {
    fun canAuthenticate(context: Context, sdkInt: Int): BiometricPlatformAvailability {
        val manager = context.getSystemService(android.hardware.biometrics.BiometricManager::class.java)
            ?: return BiometricPlatformAvailability.UNKNOWN
        val result = when (BiometricPolicy.frameworkPolicy(sdkInt)) {
            BiometricFrameworkPolicy.API29_DEFAULT -> manager.canAuthenticate()
            BiometricFrameworkPolicy.API30_STRONG -> AndroidBiometricApi30.canAuthenticate(manager)
            BiometricFrameworkPolicy.UNSUPPORTED -> return BiometricPlatformAvailability.UNKNOWN
        }
        return when (result) {
            android.hardware.biometrics.BiometricManager.BIOMETRIC_SUCCESS ->
                BiometricPlatformAvailability.SUCCESS
            android.hardware.biometrics.BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE ->
                BiometricPlatformAvailability.NO_HARDWARE
            android.hardware.biometrics.BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED ->
                BiometricPlatformAvailability.NOT_ENROLLED
            android.hardware.biometrics.BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE ->
                BiometricPlatformAvailability.HARDWARE_UNAVAILABLE
            else -> BiometricPlatformAvailability.UNKNOWN
        }
    }

    fun startPrompt(
        activity: Activity,
        reason: String,
        executor: Executor,
        events: BiometricPromptEvents,
        cancellationSignal: CancellationSignal,
    ) {
        val builder = android.hardware.biometrics.BiometricPrompt.Builder(activity)
            .setTitle(reason)
            .setNegativeButton("Cancel", executor, DialogInterface.OnClickListener { _, _ ->
                events.onAuthenticationError(BiometricPromptError.USER_CANCELLED)
            })
        if (BiometricPolicy.frameworkPolicy(Build.VERSION.SDK_INT) == BiometricFrameworkPolicy.API30_STRONG) {
            AndroidBiometricApi30.allowStrongBiometrics(builder)
        }
        val prompt = builder.build()
        prompt.authenticate(cancellationSignal, executor,
            object : android.hardware.biometrics.BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationFailed() {
                    events.onAuthenticationFailed()
                }

                override fun onAuthenticationSucceeded(
                    result: android.hardware.biometrics.BiometricPrompt.AuthenticationResult,
                ) {
                    val type = if (BiometricPolicy.frameworkPolicy(Build.VERSION.SDK_INT) ==
                        BiometricFrameworkPolicy.API30_STRONG
                    ) {
                        AndroidBiometricApi30.authenticationType(result)
                    } else {
                        null
                    }
                    events.onAuthenticationSucceeded(type)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    events.onAuthenticationError(mapError(errorCode))
                }
            })
    }

    private fun mapError(errorCode: Int): BiometricPromptError = when (errorCode) {
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ->
            BiometricPromptError.USER_CANCELLED
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT ->
            BiometricPromptError.LOCKED_OUT
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT ->
            BiometricPromptError.NO_HARDWARE
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS ->
            BiometricPromptError.NOT_ENROLLED
        android.hardware.biometrics.BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE ->
            BiometricPromptError.HARDWARE_UNAVAILABLE
        else -> BiometricPromptError.OTHER
    }
}

/** API-30 members are isolated so API 29 verifies only its platform-default prompt path. */
private object AndroidBiometricApi30 {
    fun canAuthenticate(manager: android.hardware.biometrics.BiometricManager): Int =
        manager.canAuthenticate(
            android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG,
        )

    fun allowStrongBiometrics(builder: android.hardware.biometrics.BiometricPrompt.Builder) {
        builder.setAllowedAuthenticators(
            android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG,
        )
    }

    fun authenticationType(
        result: android.hardware.biometrics.BiometricPrompt.AuthenticationResult,
    ): BiometricAuthenticationType = when (result.authenticationType) {
        android.hardware.biometrics.BiometricPrompt.AUTHENTICATION_RESULT_TYPE_BIOMETRIC ->
            BiometricAuthenticationType.BIOMETRIC
        android.hardware.biometrics.BiometricPrompt.AUTHENTICATION_RESULT_TYPE_DEVICE_CREDENTIAL ->
            BiometricAuthenticationType.OTHER
        else -> BiometricAuthenticationType.UNKNOWN
    }
}

private interface BiometricPromptEvents {
    fun onAuthenticationFailed()
    fun onAuthenticationSucceeded(type: BiometricAuthenticationType?)
    fun onAuthenticationError(error: BiometricPromptError)
}
