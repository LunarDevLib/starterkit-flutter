package dev.lunardev.starterkit.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationPolicyTest {
    private val idA = "0123456789abcdef0123456789abcdef"
    private val idB = "fedcba9876543210fedcba9876543210"

    @Test
    fun permissionAndLocateParseDefaultsAndAllInclusiveBounds() {
        val permission = LocationPolicy.parsePermissionRequest(mapOf("requestId" to idA))
        assertEquals(
            LocationParseResult.Valid(
                LocationParameters(idA, LOCATION_DEFAULT_PERMISSION_TIMEOUT_MILLIS),
            ),
            permission,
        )
        val locate = LocationPolicy.parseLocate(mapOf("requestId" to idB))
        assertEquals(
            LocationParseResult.Valid(
                LocationParameters(idB, LOCATION_DEFAULT_TIMEOUT_MILLIS, LOCATION_DEFAULT_MAX_AGE_MILLIS),
            ),
            locate,
        )
        assertEquals(
            LocationParseResult.Valid(LocationParameters(idA, 1L)),
            LocationPolicy.parsePermissionRequest(mapOf("requestId" to idA, "timeoutMillis" to 1)),
        )
        assertEquals(
            LocationParseResult.Valid(LocationParameters(idA, 60_000L)),
            LocationPolicy.parsePermissionRequest(
                mapOf("requestId" to idA, "timeoutMillis" to LOCATION_MAX_TIMEOUT_MILLIS),
            ),
        )
        assertEquals(
            LocationParseResult.Valid(LocationParameters(idB, 60_000L, 60_000L)),
            LocationPolicy.parseLocate(
                mapOf("requestId" to idB, "timeoutMillis" to 60_000, "maxAgeMillis" to 60_000),
            ),
        )
    }

    @Test
    fun malformedIdsArgumentsAndUnknownFieldsAreRejected() {
        assertEquals(LocationParseResult.InvalidRequest(), LocationPolicy.parseLocate(null))
        assertEquals(LocationParseResult.InvalidRequest(), LocationPolicy.parseLocate(emptyMap<String, Any>()))
        assertEquals(
            LocationParseResult.InvalidRequest(),
            LocationPolicy.parseLocate(mapOf("requestId" to idA.uppercase())),
        )
        assertEquals(
            LocationParseResult.InvalidRequest(),
            LocationPolicy.parseLocate(mapOf("requestId" to "0123", "timeoutMillis" to 1)),
        )
        assertEquals(
            LocationParseResult.InvalidRequest(idA),
            LocationPolicy.parseLocate(mapOf("requestId" to idA, "futureField" to true)),
        )
        assertNull(LocationPolicy.parseCancelRequest(mapOf("requestId" to idA, "unused" to true)))
        assertEquals(idA, LocationPolicy.parseCancelRequest(mapOf("requestId" to idA)))
    }

    @Test
    fun timeoutAndAgeLimitsRejectNonfiniteFractionalAndOutOfRangeNumbers() {
        for (bad in listOf(0, -1, 60_001, Double.NaN, Double.POSITIVE_INFINITY, 1.0, 1.5, "10")) {
            assertEquals(
                LocationParseResult.InvalidLimits(idA),
                LocationPolicy.parsePermissionRequest(mapOf("requestId" to idA, "timeoutMillis" to bad)),
            )
        }
        for (bad in listOf(0, -1, 60_001, Double.NaN, Double.NEGATIVE_INFINITY, 1.0, 1.25, "5")) {
            assertEquals(
                LocationParseResult.InvalidLimits(idA),
                LocationPolicy.parseLocate(mapOf("requestId" to idA, "maxAgeMillis" to bad)),
            )
        }
        assertEquals(
            LocationParseResult.InvalidLimits(idA),
            LocationPolicy.parseLocate(mapOf("requestId" to idA, "timeoutMillis" to Double.MAX_VALUE)),
        )
    }

    @Test
    fun permissionStatusDoesNotInventNotDeterminedOrRestrictedOnAndroid() {
        assertEquals(
            LocationPermissionSnapshot("unavailable", null),
            LocationPolicy.permissionSnapshot(false, false, false),
        )
        assertEquals(
            LocationPermissionSnapshot("denied", null),
            LocationPolicy.permissionSnapshot(true, false, false),
        )
        assertEquals(
            LocationPermissionSnapshot("granted", true),
            LocationPolicy.permissionSnapshot(true, true, false),
        )
        assertEquals(
            LocationPermissionSnapshot("granted", false),
            LocationPolicy.permissionSnapshot(true, true, true),
        )
        assertEquals(
            LocationPermissionDecision.DENIED,
            LocationPolicy.locationPermissionDecision(LocationPermissionSnapshot("denied", null)),
        )
        assertEquals(
            LocationPermissionDecision.UNAVAILABLE,
            LocationPolicy.locationPermissionDecision(LocationPermissionSnapshot("unavailable", null)),
        )
        assertEquals(
            LocationPermissionDecision.GRANTED,
            LocationPolicy.locationPermissionDecision(LocationPermissionSnapshot("granted", true)),
        )
    }

    @Test
    fun foregroundRequiresLiveResumedFocusedVisibleActivity() {
        val foreground = ForegroundSnapshot(
            hasActivity = true,
            started = true,
            resumed = true,
            processForeground = true,
            processVisible = true,
            hasWindowFocus = true,
            windowShown = true,
            finishing = false,
            destroyed = false,
        )
        assertTrue(LocationPolicy.canUseForegroundActivity(foreground))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(hasActivity = false)))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(started = false)))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(resumed = false)))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(hasWindowFocus = false)))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(windowShown = false)))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(finishing = true)))
        assertFalse(LocationPolicy.canUseForegroundActivity(foreground.copy(destroyed = true)))
    }

    @Test
    fun permissionResultAllowsFocusedPauseButRejectsActualBackgroundOrDetachedActivity() {
        val foreground = ForegroundSnapshot(
            hasActivity = true,
            started = true,
            resumed = true,
            processForeground = true,
            processVisible = true,
            hasWindowFocus = true,
            windowShown = true,
            finishing = false,
            destroyed = false,
        )
        assertTrue(LocationPolicy.canReceivePermissionResult(foreground))
        assertTrue(
            LocationPolicy.canReceivePermissionResult(
                foreground.copy(resumed = false, hasWindowFocus = false, processForeground = false),
            ),
        )
        assertFalse(LocationPolicy.canReceivePermissionResult(foreground.copy(started = false)))
        assertFalse(LocationPolicy.canReceivePermissionResult(foreground.copy(hasActivity = false)))
        assertFalse(
            LocationPolicy.canReceivePermissionResult(
                foreground.copy(processForeground = false, processVisible = false),
            ),
        )
        assertFalse(LocationPolicy.canReceivePermissionResult(foreground.copy(destroyed = true)))
    }

    @Test
    fun permissionFocusLossIsNotBackgroundButSamplingPauseAndStopAreTerminal() {
        assertFalse(
            LocationPolicy.shouldCancelForLifecycle(
                LocationOperationMode.PERMISSION,
                LocationLifecycleEvent.PAUSED,
            ),
        )
        assertTrue(
            LocationPolicy.shouldCancelForLifecycle(
                LocationOperationMode.PERMISSION,
                LocationLifecycleEvent.STOPPED,
            ),
        )
        assertTrue(
            LocationPolicy.shouldCancelForLifecycle(
                LocationOperationMode.PERMISSION,
                LocationLifecycleEvent.DETACHED,
            ),
        )
        for (event in LocationLifecycleEvent.entries) {
            assertTrue(LocationPolicy.shouldCancelForLifecycle(LocationOperationMode.SAMPLE, event))
        }
    }

    @Test
    fun providerSelectionPrefersNetworkThenFallsBackToGpsAndFailsClosed() {
        assertEquals(LocationProviderChoice.NETWORK, LocationPolicy.preferredProvider(true, true))
        assertEquals(LocationProviderChoice.NETWORK, LocationPolicy.preferredProvider(true, false))
        assertEquals(LocationProviderChoice.GPS, LocationPolicy.preferredProvider(false, true))
        assertNull(LocationPolicy.preferredProvider(false, false))
    }

    @Test
    fun deadlineUsesMonotonicBoundaryAndRechecksExactDeadline() {
        assertFalse(LocationPolicy.deadlineReached(99, 100))
        assertTrue(LocationPolicy.deadlineReached(100, 100))
        assertTrue(LocationPolicy.deadlineReached(101, 100))
    }

    @Test
    fun sampleAcceptsOnlyFiniteCoordinatesAccuracyAndValidMonotonicAge() {
        val now = 9_000_000_000L
        val exactMaximumAge = LocationPolicy.validateSample(
            latitude = -90.0,
            longitude = 180.0,
            accuracyPresent = true,
            accuracyMeters = 0.0,
            approximate = true,
            sampleElapsedRealtimeNanos = now - 5_000L * LocationPolicy.NANOS_PER_MILLI,
            nowElapsedRealtimeNanos = now,
            maxAgeMillis = 5_000,
        )
        assertEquals(
            LocationSampleValidation.Valid(ForegroundLocation(-90.0, 180.0, 0.0, true, 5_000)),
            exactMaximumAge,
        )
        assertEquals(
            LocationSampleValidation.Valid(ForegroundLocation(90.0, -180.0, 17.5, false, 0)),
            LocationPolicy.validateSample(
                90.0, -180.0, true, 17.5, false, now, now, 5_000,
            ),
        )
        assertSampleError("location.invalid_coordinate", latitude = Double.NaN)
        assertSampleError("location.invalid_coordinate", latitude = Double.POSITIVE_INFINITY)
        assertSampleError("location.invalid_coordinate", latitude = 90.0001)
        assertSampleError("location.invalid_coordinate", longitude = Double.NEGATIVE_INFINITY)
        assertSampleError("location.invalid_coordinate", longitude = -180.0001)
        assertSampleError("location.invalid_accuracy", accuracy = Double.NaN)
        assertSampleError("location.invalid_accuracy", accuracy = Double.POSITIVE_INFINITY)
        assertSampleError("location.invalid_accuracy", accuracy = -0.01)
        assertSampleError("location.invalid_accuracy", accuracyPresent = false, accuracy = 0.0)
        assertSampleError("location.invalid_sample_time", sampleTime = 0L)
        assertSampleError("location.invalid_sample_time", sampleTime = now + 1)
        assertSampleError(
            "location.sample_stale",
            sampleTime = now - 5_000L * LocationPolicy.NANOS_PER_MILLI - 1,
        )
        assertEquals(
            LocationSampleValidation.Invalid("invalid", "location.sample_stale"),
            LocationPolicy.validateSample(0.0, 0.0, true, 0.0, true, now, now, 0),
        )
    }

    @Test
    fun oneLocationOperationConflictsAndOldIdentityCannotCancelOrSettleNewOne() {
        val fence = LocationOperationFence()
        val first = (fence.begin(
            LocationParameters(idA, 100, 5), LocationOperationMode.SAMPLE, 10,
        ) as LocationOperationStart.Started).ticket
        assertTrue(fence.isCurrent(first))
        assertEquals(110, first.deadlineElapsedRealtimeMillis)
        assertEquals(LocationOperationStart.Conflict, fence.begin(
            LocationParameters(idB, 100, 5), LocationOperationMode.SAMPLE, 10,
        ))
        assertNull(fence.matchingPending(idB))
        assertEquals(first, fence.matchingPending(idA))
        assertEquals(LocationSettlement.SETTLED, fence.settle(first, 109))
        assertEquals(LocationSettlement.STALE, fence.settle(first, 109))

        val second = (fence.begin(
            LocationParameters(idA, 100), LocationOperationMode.PERMISSION, 20,
        ) as LocationOperationStart.Started).ticket
        assertNotEquals(first.generation, second.generation)
        assertFalse(fence.isCurrent(first))
        assertNull(fence.matchingPending(idB))
        assertEquals(second, fence.matchingPending(idA))
        assertEquals(LocationSettlement.STALE, fence.settle(first, 21))
        assertTrue(fence.isCurrent(second))
    }

    @Test
    fun terminalSettlementAtomicallyResolvesBeforeAtAndAfterDeadline() {
        val beforeFence = LocationOperationFence()
        val before = (beforeFence.begin(
            LocationParameters(idA, 10), LocationOperationMode.SAMPLE, 100,
        ) as LocationOperationStart.Started).ticket
        assertEquals(LocationSettlement.SETTLED, beforeFence.settle(before, 109))

        val atFence = LocationOperationFence()
        val at = (atFence.begin(
            LocationParameters(idA, 10), LocationOperationMode.SAMPLE, 100,
        ) as LocationOperationStart.Started).ticket
        assertEquals(LocationSettlement.TIMED_OUT, atFence.settle(at, 110))
        assertEquals(LocationSettlement.STALE, atFence.settle(at, 111))

        val afterFence = LocationOperationFence()
        val after = (afterFence.begin(
            LocationParameters(idA, 10), LocationOperationMode.SAMPLE, 100,
        ) as LocationOperationStart.Started).ticket
        assertEquals(LocationSettlement.TIMED_OUT, afterFence.settle(after, 111))
    }

    @Test
    fun permissionEnvelopeNormalizesEveryNonsuccessExceptKnownDeniedOrRestricted() {
        val granted = LocationPermissionSnapshot("granted", false)
        for (kind in listOf("cancelled", "timeout", "conflict", "failure", "invalid", "unavailable")) {
            val envelope = LocationPolicy.permissionEnvelope(kind, "location.test", granted, idA)
            assertEquals("unavailable", envelope["status"])
            assertNull(envelope["approximate"])
            assertEquals(idA, envelope["requestId"])
        }
        val grantedSuccess = LocationPolicy.permissionEnvelope("success", "location.test", granted)
        assertEquals("granted", grantedSuccess["status"])
        assertEquals(false, grantedSuccess["approximate"])

        val informationalDenied = LocationPolicy.permissionEnvelope(
            "success", "location.permission_status", LocationPermissionSnapshot("denied", null),
        )
        assertEquals("denied", informationalDenied["status"])
        assertNull(informationalDenied["approximate"])
        assertEquals(
            "denied",
            LocationPolicy.permissionEnvelope("denied", "location.denied", LocationPermissionSnapshot("denied", null))["status"],
        )
        assertEquals(
            "restricted",
            LocationPolicy.permissionEnvelope("restricted", "location.restricted", LocationPermissionSnapshot("restricted", null))["status"],
        )
    }

    @Test
    fun permissionRequestCodeBudgetIsProcessRangeSizedAndNeverReuses() {
        val allocator = LocationPermissionRequestCodeAllocator()
        val codes = (0 until LOCATION_PERMISSION_REQUEST_RANGE_SIZE).map { allocator.allocate() }
        assertEquals((LOCATION_PERMISSION_REQUEST_FIRST..LOCATION_PERMISSION_REQUEST_LAST).toList(), codes)
        repeat(4) { assertNull(allocator.allocate()) }
    }

    @Test
    fun cleanupRunsEveryResourceOnceEvenWithDuplicateCloseAndLateRegistration() {
        val events = mutableListOf<String>()
        val cleanup = LocationOperationCleanup()
        cleanup.add { events.add("timer") }
        cleanup.add { events.add("location-listener") }
        cleanup.add { events.add("permission-listener") }
        cleanup.add { events.add("lifecycle-observer") }
        cleanup.add { error("one teardown must not prevent the rest") }
        cleanup.add { events.add("after-failure") }

        cleanup.close()
        cleanup.close()
        cleanup.add { events.add("registered-after-close") }

        assertEquals(
            listOf("timer", "location-listener", "permission-listener", "lifecycle-observer", "after-failure", "registered-after-close"),
            events,
        )
    }

    private fun assertSampleError(
        code: String,
        latitude: Double = 0.0,
        longitude: Double = 0.0,
        accuracyPresent: Boolean = true,
        accuracy: Double = 1.0,
        sampleTime: Long = 9_000_000_000L,
    ) {
        val result = LocationPolicy.validateSample(
            latitude = latitude,
            longitude = longitude,
            accuracyPresent = accuracyPresent,
            accuracyMeters = accuracy,
            approximate = true,
            sampleElapsedRealtimeNanos = sampleTime,
            nowElapsedRealtimeNanos = 9_000_000_000L,
            maxAgeMillis = 5_000,
        )
        assertEquals(LocationSampleValidation.Invalid("invalid", code), result)
    }
}
