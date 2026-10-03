package dev.lunardev.starterkit.platform

internal const val LOCATION_PERMISSION_REQUEST_FIRST = 0x5400
internal const val LOCATION_PERMISSION_REQUEST_LAST = 0x54ff
internal const val LOCATION_PERMISSION_REQUEST_RANGE_SIZE = 256
internal const val LOCATION_DEFAULT_PERMISSION_TIMEOUT_MILLIS = 60_000L
internal const val LOCATION_DEFAULT_TIMEOUT_MILLIS = 15_000L
internal const val LOCATION_DEFAULT_MAX_AGE_MILLIS = 5_000L
internal const val LOCATION_MAX_TIMEOUT_MILLIS = 60_000L
internal const val LOCATION_MAX_AGE_MILLIS = 60_000L

internal enum class LocationOperationMode { PERMISSION, SAMPLE }

internal data class LocationParameters(
    val requestId: String,
    val timeoutMillis: Long,
    val maxAgeMillis: Long? = null,
)

internal sealed class LocationParseResult {
    data class Valid(val parameters: LocationParameters) : LocationParseResult()
    data class InvalidRequest(val requestId: String? = null) : LocationParseResult()
    data class InvalidLimits(val requestId: String) : LocationParseResult()
}

internal data class LocationPermissionSnapshot(val status: String, val approximate: Boolean?)
internal enum class LocationPermissionDecision { GRANTED, DENIED, UNAVAILABLE }

internal data class ForegroundSnapshot(
    val hasActivity: Boolean,
    val started: Boolean,
    val resumed: Boolean,
    val processForeground: Boolean,
    val processVisible: Boolean,
    val hasWindowFocus: Boolean,
    val windowShown: Boolean,
    val finishing: Boolean,
    val destroyed: Boolean,
)

internal enum class LocationLifecycleEvent { PAUSED, STOPPED, DETACHED }
internal enum class LocationProviderChoice { NETWORK, GPS }

internal data class ForegroundLocation(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double,
    val approximate: Boolean,
    val ageMillis: Long,
)

internal sealed class LocationSampleValidation {
    data class Valid(val location: ForegroundLocation) : LocationSampleValidation()
    data class Invalid(val kind: String, val code: String) : LocationSampleValidation()
}

/** Pure request parsing, result policy, deadlines, and callback identity fencing. */
internal object LocationPolicy {
    private val requestIdPattern = Regex("^[0-9a-f]{32}$")

    fun validRequestId(value: Any?): String? =
        (value as? String)?.takeIf(requestIdPattern::matches)

    fun parsePermissionRequest(arguments: Any?): LocationParseResult =
        parseOperation(
            arguments = arguments,
            expectedKeys = setOf("requestId", "timeoutMillis"),
            defaultTimeoutMillis = LOCATION_DEFAULT_PERMISSION_TIMEOUT_MILLIS,
            includeMaxAge = false,
        )

    fun parseLocate(arguments: Any?): LocationParseResult =
        parseOperation(
            arguments = arguments,
            expectedKeys = setOf("requestId", "timeoutMillis", "maxAgeMillis"),
            defaultTimeoutMillis = LOCATION_DEFAULT_TIMEOUT_MILLIS,
            includeMaxAge = true,
        )

    fun parseCancelRequest(arguments: Any?): String? {
        val values = arguments as? Map<*, *> ?: return null
        if (values.keys != setOf("requestId")) return null
        return validRequestId(values["requestId"])
    }

    private fun parseOperation(
        arguments: Any?,
        expectedKeys: Set<String>,
        defaultTimeoutMillis: Long,
        includeMaxAge: Boolean,
    ): LocationParseResult {
        val values = arguments as? Map<*, *> ?: return LocationParseResult.InvalidRequest()
        val requestId = validRequestId(values["requestId"])
            ?: return LocationParseResult.InvalidRequest()
        if (
            "requestId" !in values.keys ||
                values.keys.any { it !in expectedKeys }
        ) {
            return LocationParseResult.InvalidRequest(requestId)
        }

        val timeout = if (values.containsKey("timeoutMillis")) {
            boundedInteger(values["timeoutMillis"], 1L, LOCATION_MAX_TIMEOUT_MILLIS)
        } else {
            defaultTimeoutMillis
        } ?: return LocationParseResult.InvalidLimits(requestId)

        val maxAge = if (includeMaxAge) {
            if (values.containsKey("maxAgeMillis")) {
                boundedInteger(values["maxAgeMillis"], 1L, LOCATION_MAX_AGE_MILLIS)
            } else {
                LOCATION_DEFAULT_MAX_AGE_MILLIS
            } ?: return LocationParseResult.InvalidLimits(requestId)
        } else {
            null
        }

        return LocationParseResult.Valid(LocationParameters(requestId, timeout, maxAge))
    }

    private fun boundedInteger(value: Any?, minimum: Long, maximum: Long): Long? {
        val integer = when (value) {
            is Byte -> value.toLong()
            is Short -> value.toLong()
            is Int -> value.toLong()
            is Long -> value
            else -> return null
        }
        return integer.takeIf { it in minimum..maximum }
    }

    fun permissionSnapshot(
        coarsePermissionConfigured: Boolean,
        coarseGranted: Boolean,
        fineGranted: Boolean,
    ): LocationPermissionSnapshot = when {
        !coarsePermissionConfigured -> LocationPermissionSnapshot("unavailable", null)
        coarseGranted -> LocationPermissionSnapshot("granted", approximate = !fineGranted)
        else -> LocationPermissionSnapshot("denied", null)
    }

    fun locationPermissionDecision(snapshot: LocationPermissionSnapshot): LocationPermissionDecision =
        when (snapshot.status) {
            "granted" -> LocationPermissionDecision.GRANTED
            "denied" -> LocationPermissionDecision.DENIED
            else -> LocationPermissionDecision.UNAVAILABLE
        }

    fun permissionEnvelope(
        kind: String,
        code: String,
        snapshot: LocationPermissionSnapshot,
        requestId: String? = null,
    ): Map<String, Any?> {
        val normalizedKind = when {
            kind == "denied" && snapshot.status != "denied" -> "unavailable"
            kind == "restricted" && snapshot.status != "restricted" -> "unavailable"
            kind == "success" && snapshot.status !in setOf("granted", "notDetermined", "denied", "restricted") ->
                "unavailable"
            kind == "success" && snapshot.status == "granted" && snapshot.approximate == null ->
                "unavailable"
            else -> kind
        }
        val normalizedCode = if (normalizedKind == kind) code else "location.platform_unavailable"
        val normalizedSnapshot = when (normalizedKind) {
            "success" -> if (snapshot.status == "granted") {
                snapshot
            } else {
                LocationPermissionSnapshot(snapshot.status, null)
            }
            "denied" -> LocationPermissionSnapshot("denied", null)
            "restricted" -> LocationPermissionSnapshot("restricted", null)
            else -> LocationPermissionSnapshot("unavailable", null)
        }
        return buildMap {
            put("kind", normalizedKind)
            put("code", normalizedCode)
            put("status", normalizedSnapshot.status)
            put("approximate", normalizedSnapshot.approximate)
            if (requestId != null) put("requestId", requestId)
        }
    }

    fun canUseForegroundActivity(snapshot: ForegroundSnapshot): Boolean =
        snapshot.hasActivity && snapshot.started && snapshot.resumed && snapshot.processForeground &&
            snapshot.hasWindowFocus && snapshot.windowShown &&
            !snapshot.finishing && !snapshot.destroyed

    fun canReceivePermissionResult(snapshot: ForegroundSnapshot): Boolean =
        snapshot.hasActivity && snapshot.started &&
            (snapshot.processForeground || snapshot.processVisible) &&
            snapshot.windowShown && !snapshot.finishing && !snapshot.destroyed

    fun shouldCancelForLifecycle(
        mode: LocationOperationMode,
        event: LocationLifecycleEvent,
    ): Boolean = when (mode) {
        LocationOperationMode.SAMPLE -> true
        // Runtime permission UI can take focus (and briefly pause interaction) while still
        // belonging to the foreground Activity. A real stop or detach is terminal.
        LocationOperationMode.PERMISSION ->
            event == LocationLifecycleEvent.STOPPED ||
                event == LocationLifecycleEvent.DETACHED
    }

    fun preferredProvider(networkEnabled: Boolean, gpsEnabled: Boolean): LocationProviderChoice? =
        when {
            networkEnabled -> LocationProviderChoice.NETWORK
            gpsEnabled -> LocationProviderChoice.GPS
            else -> null
        }

    fun deadlineReached(nowElapsedRealtimeMillis: Long, deadlineElapsedRealtimeMillis: Long): Boolean =
        nowElapsedRealtimeMillis >= deadlineElapsedRealtimeMillis

    fun validateSample(
        latitude: Double,
        longitude: Double,
        accuracyPresent: Boolean,
        accuracyMeters: Double,
        approximate: Boolean,
        sampleElapsedRealtimeNanos: Long,
        nowElapsedRealtimeNanos: Long,
        maxAgeMillis: Long,
    ): LocationSampleValidation {
        if (!latitude.isFinite() || latitude !in -90.0..90.0 ||
            !longitude.isFinite() || longitude !in -180.0..180.0
        ) {
            return LocationSampleValidation.Invalid("invalid", "location.invalid_coordinate")
        }
        if (!accuracyPresent || !accuracyMeters.isFinite() || accuracyMeters < 0.0) {
            return LocationSampleValidation.Invalid("invalid", "location.invalid_accuracy")
        }
        if (sampleElapsedRealtimeNanos <= 0L || nowElapsedRealtimeNanos < 0L ||
            sampleElapsedRealtimeNanos > nowElapsedRealtimeNanos
        ) {
            return LocationSampleValidation.Invalid("invalid", "location.invalid_sample_time")
        }
        val ageNanos = nowElapsedRealtimeNanos - sampleElapsedRealtimeNanos
        if (maxAgeMillis !in 1L..LOCATION_MAX_AGE_MILLIS ||
            ageNanos > maxAgeMillis * NANOS_PER_MILLI
        ) {
            return LocationSampleValidation.Invalid("invalid", "location.sample_stale")
        }
        return LocationSampleValidation.Valid(
            ForegroundLocation(
                latitude = latitude,
                longitude = longitude,
                accuracyMeters = accuracyMeters,
                approximate = approximate,
                ageMillis = ageNanos / NANOS_PER_MILLI,
            ),
        )
    }

    const val NANOS_PER_MILLI = 1_000_000L
}

internal class LocationPermissionRequestCodeAllocator(
    private val firstCode: Int = LOCATION_PERMISSION_REQUEST_FIRST,
    private val lastCode: Int = LOCATION_PERMISSION_REQUEST_LAST,
) {
    private var nextCode = firstCode

    init {
        require(firstCode in 0..0xffff && lastCode in firstCode..0xffff)
    }

    @Synchronized
    fun allocate(): Int? = if (nextCode <= lastCode) nextCode++ else null
}

/** Process-lifetime allocator; prompted request codes are never returned or reused. */
internal object LocationPermissionRequestCodes {
    private val allocator = LocationPermissionRequestCodeAllocator()

    fun allocate(): Int? = allocator.allocate()
}

internal class LocationOperationTicket internal constructor(
    val requestId: String,
    val mode: LocationOperationMode,
    val deadlineElapsedRealtimeMillis: Long,
    val maxAgeMillis: Long?,
    /** A fresh token fences callbacks even if a client later reuses its request ID. */
    internal val generation: Any,
)

internal sealed class LocationOperationStart {
    data class Started(val ticket: LocationOperationTicket) : LocationOperationStart()
    data object Conflict : LocationOperationStart()
}

internal enum class LocationSettlement { STALE, SETTLED, TIMED_OUT }

/** One pending Location request (permission or sample); Media operations are independent. */
internal class LocationOperationFence {
    private var current: LocationOperationTicket? = null

    @Synchronized
    fun begin(
        parameters: LocationParameters,
        mode: LocationOperationMode,
        nowElapsedRealtimeMillis: Long,
    ): LocationOperationStart {
        if (current != null) return LocationOperationStart.Conflict
        val deadline = if (Long.MAX_VALUE - nowElapsedRealtimeMillis < parameters.timeoutMillis) {
            Long.MAX_VALUE
        } else {
            nowElapsedRealtimeMillis + parameters.timeoutMillis
        }
        val ticket = LocationOperationTicket(
            requestId = parameters.requestId,
            mode = mode,
            deadlineElapsedRealtimeMillis = deadline,
            maxAgeMillis = parameters.maxAgeMillis,
            generation = Any(),
        )
        current = ticket
        return LocationOperationStart.Started(ticket)
    }

    @Synchronized
    fun isCurrent(ticket: LocationOperationTicket): Boolean {
        val active = current
        return active === ticket && active.generation === ticket.generation
    }

    @Synchronized
    fun matchingPending(requestId: String): LocationOperationTicket? =
        current?.takeIf { it.requestId == requestId }

    @Synchronized
    fun settle(ticket: LocationOperationTicket, nowElapsedRealtimeMillis: Long): LocationSettlement {
        if (!isCurrent(ticket)) return LocationSettlement.STALE
        val timedOut = LocationPolicy.deadlineReached(
            nowElapsedRealtimeMillis,
            ticket.deadlineElapsedRealtimeMillis,
        )
        current = null
        return if (timedOut) LocationSettlement.TIMED_OUT else LocationSettlement.SETTLED
    }
}

/** Idempotent cleanup stack for per-operation listeners, timers, and lifecycle callbacks. */
internal class LocationOperationCleanup {
    private val actions = mutableListOf<() -> Unit>()
    private var closed = false

    @Synchronized
    fun add(action: () -> Unit) {
        if (closed) {
            runCatching(action)
        } else {
            actions.add(action)
        }
    }

    fun close() {
        val pendingActions = synchronized(this) {
            if (closed) return
            closed = true
            actions.toList().also { actions.clear() }
        }
        pendingActions.forEach { runCatching(it) }
    }
}
