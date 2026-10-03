package dev.lunardev.starterkit.platform

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Android framework adapter for the separately registered foreground Location channel. */
internal class AndroidLocationHandler(
    private val context: Context,
    private val main: Handler = Handler(Looper.getMainLooper()),
) : MethodChannel.MethodCallHandler {
    private val fence = LocationOperationFence()
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: PendingLocationOperation? = null

    fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    fun onActivityDetached() {
        pending?.let { finish(it, cancellationEnvelope(it, "location.activity_detached")) }
        activityBinding = null
    }

    fun onEngineDetached() {
        pending?.let { finish(it, cancellationEnvelope(it, "location.engine_detached")) }
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "locationPermissionStatus" -> permissionStatus(call, result)
            "requestLocationPermission" -> requestPermission(call.arguments, result)
            "locate" -> locate(call.arguments, result)
            "cancelLocation" -> result.success(cancel(call.arguments))
            else -> result.notImplemented()
        }
    }

    private fun permissionStatus(call: MethodCall, result: MethodChannel.Result) {
        if (call.arguments != null) {
            result.success(
                permissionEnvelope(
                    "invalid",
                    "location.invalid_request",
                    unavailableSnapshot(),
                ),
            )
            return
        }
        val snapshot = permissionSnapshot()
        val unavailable = snapshot.status == "unavailable"
        val code = if (unavailable) "location.permission_not_configured" else "location.permission_status"
        result.success(permissionEnvelope(if (unavailable) "unavailable" else "success", code, snapshot))
    }

    private fun requestPermission(arguments: Any?, result: MethodChannel.Result) {
        val parameters = when (val parsed = LocationPolicy.parsePermissionRequest(arguments)) {
            is LocationParseResult.Valid -> parsed.parameters
            is LocationParseResult.InvalidLimits -> {
                result.success(permissionEnvelope("invalid", "location.invalid_limits", unavailableSnapshot(), parsed.requestId))
                return
            }
            is LocationParseResult.InvalidRequest -> {
                result.success(permissionEnvelope("invalid", "location.invalid_request", unavailableSnapshot(), parsed.requestId))
                return
            }
        }
        val operation = begin(parameters, LocationOperationMode.PERMISSION, result) ?: return
        val snapshot = permissionSnapshot()
        if (snapshot.status == "unavailable") {
            finish(operation, permissionEnvelope("unavailable", "location.permission_not_configured", snapshot, parameters.requestId))
            return
        }
        if (snapshot.status == "granted") {
            finish(operation, permissionEnvelope("success", "location.permission_granted", snapshot, parameters.requestId))
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            finish(operation, permissionEnvelope("unavailable", "location.activity_unavailable", snapshot, parameters.requestId))
            return
        }
        if (!isForeground(activity)) {
            finish(operation, permissionEnvelope("unavailable", "location.foreground_required", snapshot, parameters.requestId))
            return
        }
        val requestCode = LocationPermissionRequestCodes.allocate()
        if (requestCode == null) {
            finish(operation, permissionEnvelope("failure", "location.request_codes_exhausted", snapshot, parameters.requestId))
            return
        }

        operation.activity = activity
        if (!installLifecycleObserver(operation, activity)) {
            finish(operation, permissionEnvelope("failure", "location.platform_failure", snapshot, parameters.requestId))
            return
        }
        startDeadline(operation)

        val binding = activityBinding
        if (binding == null || binding.activity !== activity) {
            finish(operation, permissionEnvelope("unavailable", "location.activity_unavailable", snapshot, parameters.requestId))
            return
        }
        val listener = object : PluginRegistry.RequestPermissionsResultListener {
            override fun onRequestPermissionsResult(
                callbackRequestCode: Int,
                permissions: Array<out String>,
                grantResults: IntArray,
            ): Boolean {
                if (callbackRequestCode != requestCode) return false
                if (!isCurrent(operation)) return true
                if (finishIfDeadlineReached(operation)) return true
                if (!canReceivePermissionResult(activity)) {
                    finish(operation, cancellationEnvelope(operation, "location.backgrounded"))
                    return true
                }
                val actual = permissionSnapshot()
                if (actual.status == "granted") {
                    finish(operation, permissionEnvelope("success", "location.permission_granted", actual, parameters.requestId))
                } else if (actual.status == "denied") {
                    finish(operation, permissionEnvelope("denied", "location.denied", actual, parameters.requestId))
                } else {
                    finish(operation, permissionEnvelope("unavailable", "location.permission_not_configured", actual, parameters.requestId))
                }
                return true
            }
        }
        try {
            operation.cleanup.add { binding.removeRequestPermissionsResultListener(listener) }
            binding.addRequestPermissionsResultListener(listener)
        } catch (_: Throwable) {
            finish(operation, permissionEnvelope("failure", "location.platform_failure", permissionSnapshot(), parameters.requestId))
            return
        }
        if (finishIfDeadlineReached(operation)) return
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION), requestCode)
        } catch (_: SecurityException) {
            finish(operation, permissionPlatformFailure(permissionSnapshot(), parameters.requestId))
        } catch (_: Throwable) {
            finish(operation, permissionEnvelope("failure", "location.platform_failure", permissionSnapshot(), parameters.requestId))
        }
    }

    private fun locate(arguments: Any?, result: MethodChannel.Result) {
        val parameters = when (val parsed = LocationPolicy.parseLocate(arguments)) {
            is LocationParseResult.Valid -> parsed.parameters
            is LocationParseResult.InvalidLimits -> {
                result.success(locationEnvelope("invalid", "location.invalid_limits", parsed.requestId))
                return
            }
            is LocationParseResult.InvalidRequest -> {
                result.success(locationEnvelope("invalid", "location.invalid_request", parsed.requestId))
                return
            }
        }
        val operation = begin(parameters, LocationOperationMode.SAMPLE, result) ?: return
        val snapshot = permissionSnapshot()
        when (LocationPolicy.locationPermissionDecision(snapshot)) {
            LocationPermissionDecision.GRANTED -> Unit
            LocationPermissionDecision.DENIED -> {
                finish(operation, locationEnvelope("denied", "location.denied", parameters.requestId))
                return
            }
            LocationPermissionDecision.UNAVAILABLE -> {
                finish(operation, locationEnvelope("unavailable", "location.permission_not_configured", parameters.requestId))
                return
            }
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            finish(operation, locationEnvelope("unavailable", "location.activity_unavailable", parameters.requestId))
            return
        }
        if (!isForeground(activity)) {
            finish(operation, locationEnvelope("unavailable", "location.foreground_required", parameters.requestId))
            return
        }
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (manager == null) {
            finish(operation, locationEnvelope("unavailable", "location.platform_unavailable", parameters.requestId))
            return
        }
        val provider = try {
            when (
                LocationPolicy.preferredProvider(
                    networkEnabled = manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER),
                    gpsEnabled = manager.isProviderEnabled(LocationManager.GPS_PROVIDER),
                )
            ) {
                LocationProviderChoice.NETWORK -> LocationManager.NETWORK_PROVIDER
                LocationProviderChoice.GPS -> LocationManager.GPS_PROVIDER
                null -> null
            }
        } catch (_: SecurityException) {
            finish(operation, locationPermissionFailure(permissionSnapshot(), parameters.requestId))
            return
        } catch (_: Throwable) {
            finish(operation, locationEnvelope("failure", "location.platform_failure", parameters.requestId))
            return
        }
        if (provider == null) {
            finish(operation, locationEnvelope("unavailable", "location.provider_disabled", parameters.requestId))
            return
        }

        operation.activity = activity
        if (!installLifecycleObserver(operation, activity)) {
            finish(operation, locationEnvelope("failure", "location.platform_failure", parameters.requestId))
            return
        }
        startDeadline(operation)
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (!isCurrent(operation)) return
                if (finishIfDeadlineReached(operation)) return
                if (activityBinding?.activity !== activity || !isForeground(activity)) {
                    finish(operation, locationEnvelope("cancelled", "location.backgrounded", parameters.requestId))
                    return
                }
                val providerEnabled = try {
                    manager.isProviderEnabled(provider)
                } catch (_: SecurityException) {
                    finish(operation, locationPermissionFailure(permissionSnapshot(), parameters.requestId))
                    return
                } catch (_: Throwable) {
                    finish(operation, locationEnvelope("failure", "location.platform_failure", parameters.requestId))
                    return
                }
                if (!providerEnabled) {
                    finish(operation, locationEnvelope("unavailable", "location.provider_disabled", parameters.requestId))
                    return
                }
                val currentPermission = permissionSnapshot()
                if (currentPermission.status == "denied") {
                    finish(operation, locationEnvelope("denied", "location.denied", parameters.requestId))
                    return
                }
                if (currentPermission.status != "granted") {
                    finish(operation, locationEnvelope("unavailable", "location.permission_not_configured", parameters.requestId))
                    return
                }
                val checked = LocationPolicy.validateSample(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    accuracyPresent = location.hasAccuracy(),
                    accuracyMeters = location.accuracy.toDouble(),
                    approximate = currentPermission.approximate == true,
                    sampleElapsedRealtimeNanos = location.elapsedRealtimeNanos,
                    nowElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos(),
                    maxAgeMillis = parameters.maxAgeMillis ?: LOCATION_DEFAULT_MAX_AGE_MILLIS,
                )
                when (checked) {
                    is LocationSampleValidation.Invalid ->
                        finish(operation, locationEnvelope(checked.kind, checked.code, parameters.requestId))
                    is LocationSampleValidation.Valid -> {
                        val sample = checked.location
                        finish(
                            operation,
                            locationEnvelope(
                                "success",
                                "location.success",
                                parameters.requestId,
                                location = mapOf(
                                    "latitude" to sample.latitude,
                                    "longitude" to sample.longitude,
                                    "accuracyMeters" to sample.accuracyMeters,
                                    "approximate" to sample.approximate,
                                    "ageMillis" to sample.ageMillis,
                                ),
                            ),
                        )
                    }
                }
            }

            override fun onProviderEnabled(provider: String) {
                if (isCurrent(operation)) finishIfDeadlineReached(operation)
            }

            override fun onProviderDisabled(provider: String) {
                if (isCurrent(operation) && !finishIfDeadlineReached(operation)) {
                    finish(operation, locationEnvelope("unavailable", "location.provider_disabled", parameters.requestId))
                }
            }

            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {
                if (isCurrent(operation)) finishIfDeadlineReached(operation)
            }
        }
        operation.cleanup.add { manager.removeUpdates(listener) }
        if (finishIfDeadlineReached(operation)) return
        try {
            manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
        } catch (_: SecurityException) {
            finish(operation, locationPermissionFailure(permissionSnapshot(), parameters.requestId))
        } catch (_: Throwable) {
            finish(operation, locationEnvelope("failure", "location.platform_failure", parameters.requestId))
        }
    }

    private fun begin(
        parameters: LocationParameters,
        mode: LocationOperationMode,
        result: MethodChannel.Result,
    ): PendingLocationOperation? {
        return when (
            val started = fence.begin(parameters, mode, SystemClock.elapsedRealtime())
        ) {
            is LocationOperationStart.Conflict -> {
                val response = if (mode == LocationOperationMode.PERMISSION) {
                    permissionEnvelope("conflict", "location.operation_in_progress", permissionSnapshot(), parameters.requestId)
                } else {
                    locationEnvelope("conflict", "location.operation_in_progress", parameters.requestId)
                }
                result.success(response)
                null
            }
            is LocationOperationStart.Started -> {
                PendingLocationOperation(started.ticket, result).also { pending = it }
            }
        }
    }

    private fun startDeadline(operation: PendingLocationOperation) {
        val timer = object : Runnable {
            override fun run() {
                if (!isCurrent(operation)) return
                if (finishIfDeadlineReached(operation)) return
                val remaining = operation.ticket.deadlineElapsedRealtimeMillis - SystemClock.elapsedRealtime()
                main.postDelayed(this, remaining.coerceAtLeast(1L))
            }
        }
        operation.cleanup.add { main.removeCallbacks(timer) }
        val delay = operation.ticket.deadlineElapsedRealtimeMillis - SystemClock.elapsedRealtime()
        main.postDelayed(timer, delay.coerceAtLeast(0L))
    }

    private fun finishIfDeadlineReached(operation: PendingLocationOperation): Boolean {
        if (!isCurrent(operation)) return true
        if (!LocationPolicy.deadlineReached(SystemClock.elapsedRealtime(), operation.ticket.deadlineElapsedRealtimeMillis)) {
            return false
        }
        finish(operation, timeoutEnvelope(operation))
        return true
    }

    private fun installLifecycleObserver(
        operation: PendingLocationOperation,
        activity: Activity,
    ): Boolean {
        val application = context.applicationContext as? Application ?: return false
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = recheckDeadline(operation, activity)
            override fun onActivityResumed(activity: Activity) = recheckDeadline(operation, activity)

            override fun onActivityPaused(activity: Activity) {
                lifecycleEvent(operation, activity, LocationLifecycleEvent.PAUSED)
            }

            override fun onActivityStopped(activity: Activity) {
                lifecycleEvent(operation, activity, LocationLifecycleEvent.STOPPED)
            }

            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) =
                recheckDeadline(operation, activity)

            override fun onActivityDestroyed(activity: Activity) {
                lifecycleEvent(operation, activity, LocationLifecycleEvent.DETACHED)
            }
        }
        operation.cleanup.add { application.unregisterActivityLifecycleCallbacks(callbacks) }
        try {
            application.registerActivityLifecycleCallbacks(callbacks)
        } catch (_: Throwable) {
            return false
        }
        return true
    }

    private fun lifecycleEvent(
        operation: PendingLocationOperation,
        activity: Activity,
        event: LocationLifecycleEvent,
    ) {
        if (activity !== operation.activity || !isCurrent(operation)) return
        if (finishIfDeadlineReached(operation)) return
        if (!LocationPolicy.shouldCancelForLifecycle(operation.ticket.mode, event)) return
        val code = if (event == LocationLifecycleEvent.DETACHED) {
            "location.activity_detached"
        } else {
            "location.backgrounded"
        }
        finish(operation, cancellationEnvelope(operation, code))
    }

    private fun recheckDeadline(operation: PendingLocationOperation, activity: Activity) {
        if (activity === operation.activity && isCurrent(operation)) {
            finishIfDeadlineReached(operation)
        }
    }

    private fun isForeground(activity: Activity): Boolean =
        foregroundSnapshot(activity)?.let(LocationPolicy::canUseForegroundActivity) == true

    private fun canReceivePermissionResult(activity: Activity): Boolean =
        foregroundSnapshot(activity)?.let(LocationPolicy::canReceivePermissionResult) == true

    private fun foregroundSnapshot(activity: Activity): ForegroundSnapshot? {
        return runCatching {
            val owner = activity as? LifecycleOwner ?: return null
            val state = owner.lifecycle.currentState
            val processInfo = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(processInfo)
            val foregroundProcess = processInfo.importance ==
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            val visibleProcess = processInfo.importance ==
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
            val decor = activity.window.decorView
            ForegroundSnapshot(
                hasActivity = activityBinding?.activity === activity,
                started = state.isAtLeast(Lifecycle.State.STARTED),
                resumed = state.isAtLeast(Lifecycle.State.RESUMED),
                processForeground = foregroundProcess,
                processVisible = visibleProcess,
                hasWindowFocus = activity.hasWindowFocus(),
                windowShown = decor.visibility == View.VISIBLE && decor.isShown && decor.isAttachedToWindow,
                finishing = activity.isFinishing,
                destroyed = activity.isDestroyed,
            )
        }.getOrNull()
    }

    private fun permissionSnapshot(): LocationPermissionSnapshot {
        val configured = runCatching {
            @Suppress("DEPRECATION")
            val packageInfo = context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_PERMISSIONS,
            )
            packageInfo.requestedPermissions?.contains(Manifest.permission.ACCESS_COARSE_LOCATION) == true
        }.getOrDefault(false)
        val coarseGranted = configured && context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val fineGranted = coarseGranted && context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        return LocationPolicy.permissionSnapshot(configured, coarseGranted, fineGranted)
    }

    private fun unavailableSnapshot() = LocationPermissionSnapshot("unavailable", null)

    private fun cancellationEnvelope(
        operation: PendingLocationOperation,
        code: String,
    ): Map<String, Any?> = if (operation.ticket.mode == LocationOperationMode.PERMISSION) {
        permissionEnvelope(
            "cancelled",
            code,
            permissionSnapshot(),
            operation.ticket.requestId,
        )
    } else {
        locationEnvelope("cancelled", code, operation.ticket.requestId)
    }

    private fun permissionPlatformFailure(
        snapshot: LocationPermissionSnapshot,
        requestId: String,
    ): Map<String, Any?> = when (snapshot.status) {
        "denied" -> permissionEnvelope("denied", "location.denied", snapshot, requestId)
        "unavailable" -> permissionEnvelope(
            "unavailable",
            "location.permission_not_configured",
            snapshot,
            requestId,
        )
        else -> permissionEnvelope("failure", "location.platform_failure", snapshot, requestId)
    }

    private fun locationPermissionFailure(
        snapshot: LocationPermissionSnapshot,
        requestId: String,
    ): Map<String, Any?> = when (snapshot.status) {
        "denied" -> locationEnvelope("denied", "location.denied", requestId)
        "unavailable" -> locationEnvelope("unavailable", "location.permission_not_configured", requestId)
        else -> locationEnvelope("failure", "location.platform_failure", requestId)
    }

    private fun cancel(arguments: Any?): Boolean {
        val requestId = LocationPolicy.parseCancelRequest(arguments) ?: return false
        val ticket = fence.matchingPending(requestId) ?: return false
        val operation = pending?.takeIf { it.ticket === ticket } ?: return false
        val response = if (ticket.mode == LocationOperationMode.PERMISSION) {
            permissionEnvelope("cancelled", "location.cancelled", permissionSnapshot(), requestId)
        } else {
            locationEnvelope("cancelled", "location.cancelled", requestId)
        }
        return finish(operation, response) == LocationSettlement.SETTLED
    }

    private fun isCurrent(operation: PendingLocationOperation): Boolean =
        pending === operation && fence.isCurrent(operation.ticket)

    private fun finish(
        operation: PendingLocationOperation,
        response: Map<String, Any?>,
    ): LocationSettlement {
        val settlement = fence.settle(operation.ticket, SystemClock.elapsedRealtime())
        if (settlement == LocationSettlement.STALE) return settlement
        if (pending === operation) pending = null
        operation.cleanup.close()
        val terminalResponse = when {
            settlement == LocationSettlement.TIMED_OUT -> timeoutEnvelope(operation)
            operation.ticket.mode == LocationOperationMode.PERMISSION ->
                normalizePermissionResponse(response)
            else -> response
        }
        operation.result.success(terminalResponse)
        return settlement
    }

    private fun timeoutEnvelope(operation: PendingLocationOperation): Map<String, Any?> =
        if (operation.ticket.mode == LocationOperationMode.PERMISSION) {
            permissionEnvelope(
                "timeout",
                "location.timeout",
                unavailableSnapshot(),
                operation.ticket.requestId,
            )
        } else {
            locationEnvelope("timeout", "location.timeout", operation.ticket.requestId)
        }

    private fun normalizePermissionResponse(response: Map<String, Any?>): Map<String, Any?> =
        LocationPolicy.permissionEnvelope(
            kind = response["kind"] as? String ?: "failure",
            code = response["code"] as? String ?: "location.platform_failure",
            snapshot = LocationPermissionSnapshot(
                status = response["status"] as? String ?: "unavailable",
                approximate = response["approximate"] as? Boolean,
            ),
            requestId = response["requestId"] as? String,
        )

    private fun permissionEnvelope(
        kind: String,
        code: String,
        snapshot: LocationPermissionSnapshot,
        requestId: String? = null,
    ): Map<String, Any?> = LocationPolicy.permissionEnvelope(kind, code, snapshot, requestId)

    private fun locationEnvelope(
        kind: String,
        code: String,
        requestId: String? = null,
        location: Map<String, Any>? = null,
    ): Map<String, Any?> = buildMap {
        put("kind", kind)
        put("code", code)
        if (requestId != null) put("requestId", requestId)
        if (location != null) put("location", location)
    }

    private class PendingLocationOperation(
        val ticket: LocationOperationTicket,
        val result: MethodChannel.Result,
    ) {
        val cleanup = LocationOperationCleanup()
        var activity: Activity? = null
    }
}
