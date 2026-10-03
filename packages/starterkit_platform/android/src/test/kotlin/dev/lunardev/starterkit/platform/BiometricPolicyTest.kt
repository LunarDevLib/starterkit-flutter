package dev.lunardev.starterkit.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BiometricPolicyTest {
    private val idA = "0123456789abcdef0123456789abcdef"
    private val idB = "fedcba9876543210fedcba9876543210"

    @Test
    fun availabilityOnlyAcceptsNoArguments() {
        assertTrue(BiometricPolicy.parseAvailabilityRequest(null))
        assertFalse(BiometricPolicy.parseAvailabilityRequest(emptyMap<String, Any>()))
        assertFalse(BiometricPolicy.parseAvailabilityRequest(false))
    }

    @Test
    fun authenticateRequiresExactKeysAndValidRequestId() {
        assertEquals(BiometricParseResult.InvalidRequest(), BiometricPolicy.parseAuthenticateRequest(null))
        assertEquals(
            BiometricParseResult.InvalidRequest(),
            BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to "bad", "reason" to "Unlock")),
        )
        assertEquals(
            BiometricParseResult.InvalidRequest(idA),
            BiometricPolicy.parseAuthenticateRequest(
                mapOf("requestId" to idA, "reason" to "Unlock", "extra" to true),
            ),
        )
        assertEquals(
            BiometricParseResult.Valid(BiometricRequest(idA, "Unlock")),
            BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to idA, "reason" to "Unlock")),
        )
    }

    @Test
    fun reasonRequiresNonWhitespaceNoNulAndAtMost256Utf8Bytes() {
        for (reason in listOf("", "  \n\t", "a\u0000b")) {
            assertEquals(
                BiometricParseResult.InvalidReason(idA),
                BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to idA, "reason" to reason)),
            )
        }
        assertEquals(
            BiometricParseResult.Valid(BiometricRequest(idA, "é".repeat(128))),
            BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to idA, "reason" to "é".repeat(128))),
        )
        assertEquals(
            BiometricParseResult.InvalidReason(idA),
            BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to idA, "reason" to "é".repeat(129))),
        )
        assertEquals(
            BiometricParseResult.Valid(BiometricRequest(idA, "x".repeat(256))),
            BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to idA, "reason" to "x".repeat(256))),
        )
        assertEquals(
            BiometricParseResult.InvalidReason(idA),
            BiometricPolicy.parseAuthenticateRequest(mapOf("requestId" to idA, "reason" to "x".repeat(257))),
        )
    }

    @Test
    fun cancelRequestIsExactAndUnknownIdsCannotMatch() {
        assertEquals(idA, BiometricPolicy.parseCancelRequest(mapOf("requestId" to idA)))
        assertNull(BiometricPolicy.parseCancelRequest(mapOf("requestId" to idA, "extra" to false)))
        assertNull(BiometricPolicy.parseCancelRequest(mapOf("requestId" to "bad")))
    }

    @Test
    fun api24Through28NeverEnablesFrameworkBiometricClasses() {
        for (sdk in 24..28) {
            assertEquals(BiometricFrameworkPolicy.UNSUPPORTED, BiometricPolicy.frameworkPolicy(sdk))
            assertEquals(
                BiometricAvailability(BiometricAvailabilityState.UNAVAILABLE, "biometric.platform_unavailable"),
                BiometricPolicy.availability(
                    sdk,
                    permissionDeclared = true,
                    permissionGranted = true,
                    platform = BiometricPlatformAvailability.SUCCESS,
                ),
            )
        }
        assertEquals(
            BiometricAvailability(
                BiometricAvailabilityState.PERMISSION_REQUIRED,
                "biometric.permission_required",
            ),
            BiometricPolicy.availability(
                24,
                permissionDeclared = false,
                permissionGranted = false,
                platform = BiometricPlatformAvailability.UNKNOWN,
            ),
        )
    }

    @Test
    fun api29UsesPlatformDefaultWhileApi30AndLaterUseStrongOnly() {
        assertEquals(BiometricFrameworkPolicy.API29_DEFAULT, BiometricPolicy.frameworkPolicy(29))
        assertEquals(BiometricFrameworkPolicy.API30_STRONG, BiometricPolicy.frameworkPolicy(30))
        assertEquals(BiometricFrameworkPolicy.API30_STRONG, BiometricPolicy.frameworkPolicy(35))
    }

    @Test
    fun missingUndeclaredOrUngrantablePermissionIsAdvisoryWithoutPrompt() {
        assertEquals(
            BiometricAvailability(BiometricAvailabilityState.PERMISSION_REQUIRED, "biometric.permission_required"),
            BiometricPolicy.availability(30, false, false, BiometricPlatformAvailability.SUCCESS),
        )
        assertEquals(
            BiometricAvailability(BiometricAvailabilityState.PERMISSION_REQUIRED, "biometric.permission_required"),
            BiometricPolicy.availability(30, true, false, BiometricPlatformAvailability.SUCCESS),
        )
        assertEquals(
            BiometricPolicy.authenticationEnvelope("denied", "biometric.permission_required", idA),
            BiometricPolicy.authenticationPreflight(
                BiometricPolicy.availability(30, false, false, BiometricPlatformAvailability.SUCCESS),
                idA,
            ),
        )
    }

    @Test
    fun availabilityMapsHardwareEnrollmentLockoutAndUnknownToFixedPairs() {
        val cases = listOf(
            BiometricPlatformAvailability.SUCCESS to
                BiometricAvailability(BiometricAvailabilityState.READY, "biometric.ready"),
            BiometricPlatformAvailability.NO_HARDWARE to
                BiometricAvailability(BiometricAvailabilityState.NO_HARDWARE, "biometric.no_hardware"),
            BiometricPlatformAvailability.NOT_ENROLLED to
                BiometricAvailability(BiometricAvailabilityState.NOT_ENROLLED, "biometric.not_enrolled"),
            BiometricPlatformAvailability.LOCKED_OUT to
                BiometricAvailability(BiometricAvailabilityState.LOCKED_OUT, "biometric.locked_out"),
            BiometricPlatformAvailability.HARDWARE_UNAVAILABLE to
                BiometricAvailability(BiometricAvailabilityState.UNAVAILABLE, "biometric.unavailable"),
            BiometricPlatformAvailability.UNKNOWN to
                BiometricAvailability(BiometricAvailabilityState.UNAVAILABLE, "biometric.platform_unavailable"),
        )
        cases.forEach { (status, expected) ->
            assertEquals(expected, BiometricPolicy.availability(29, true, true, status))
        }
    }

    @Test
    fun availabilityFrameworkFailuresBecomeFixedTypedStates() {
        assertEquals(
            BiometricAvailability(
                BiometricAvailabilityState.PERMISSION_REQUIRED,
                "biometric.permission_required",
            ),
            BiometricPolicy.availabilityFailure(BiometricAvailabilityFailure.PERMISSION),
        )
        assertEquals(
            BiometricAvailability(
                BiometricAvailabilityState.UNAVAILABLE,
                "biometric.platform_failure",
            ),
            BiometricPolicy.availabilityFailure(BiometricAvailabilityFailure.PLATFORM),
        )
    }

    @Test
    fun permissionQueryFailureDeniesButUnexpectedFrameworkQueryFailureFailsClosed() {
        val permission = BiometricPolicy.availabilityFailure(BiometricAvailabilityFailure.PERMISSION)
        val platform = BiometricPolicy.availabilityFailure(BiometricAvailabilityFailure.PLATFORM)
        val foreground = BiometricHostSnapshot(true, true, true, true, true, true, false, false)
        assertEquals(
            BiometricPolicy.authenticationEnvelope("denied", "biometric.permission_required", idA),
            BiometricPolicy.authenticationPreflight(permission, idA),
        )
        assertEquals(
            BiometricPolicy.authenticationEnvelope("failure", "biometric.platform_failure", idA),
            BiometricPolicy.authenticationPreflight(platform, idA),
        )
        assertFalse(BiometricPolicy.shouldOpenPrompt(permission, foreground))
        assertFalse(BiometricPolicy.shouldOpenPrompt(platform, foreground))
    }

    @Test
    fun availabilityEnvelopeIsAdvisoryAndHasNoAuthenticationIdentity() {
        assertEquals(
            mapOf("state" to "ready", "code" to "biometric.ready"),
            BiometricPolicy.availabilityEnvelope(
                BiometricAvailability(BiometricAvailabilityState.READY, "biometric.ready"),
            ),
        )
    }

    @Test
    fun preflightRefusalsPreserveRequestIdentityAndNeverMarkAuthenticated() {
        val pairs = listOf(
            BiometricAvailability(BiometricAvailabilityState.NO_HARDWARE, "biometric.no_hardware") to
                ("unavailable" to "biometric.no_hardware"),
            BiometricAvailability(BiometricAvailabilityState.NOT_ENROLLED, "biometric.not_enrolled") to
                ("unavailable" to "biometric.not_enrolled"),
            BiometricAvailability(BiometricAvailabilityState.LOCKED_OUT, "biometric.locked_out") to
                ("lockedOut" to "biometric.locked_out"),
            BiometricAvailability(BiometricAvailabilityState.UNAVAILABLE, "biometric.disabled") to
                ("unavailable" to "biometric.disabled"),
        )
        pairs.forEach { (available, expected) ->
            assertEquals(
                BiometricPolicy.authenticationEnvelope(expected.first, expected.second, idA),
                BiometricPolicy.authenticationPreflight(available, idA),
            )
        }
    }

    @Test
    fun promptErrorsMapOnlyToFrozenFixedCodes() {
        val cases = listOf(
            BiometricPromptError.USER_CANCELLED to ("cancelled" to "biometric.cancelled"),
            BiometricPromptError.LOCKED_OUT to ("lockedOut" to "biometric.locked_out"),
            BiometricPromptError.NO_HARDWARE to ("unavailable" to "biometric.no_hardware"),
            BiometricPromptError.NOT_ENROLLED to ("unavailable" to "biometric.not_enrolled"),
            BiometricPromptError.HARDWARE_UNAVAILABLE to ("unavailable" to "biometric.unavailable"),
            BiometricPromptError.OTHER to ("failure" to "biometric.platform_failure"),
        )
        cases.forEach { (error, expected) -> assertEquals(expected, BiometricPolicy.promptError(error)) }
    }

    @Test
    fun api30SuccessRequiresReportedBiometricTypeAndRejectsCredentialOrUnknown() {
        assertEquals("biometric.authenticated", BiometricPolicy.successCode(29, null))
        assertEquals(
            "biometric.authenticated",
            BiometricPolicy.successCode(30, BiometricAuthenticationType.BIOMETRIC),
        )
        assertNull(BiometricPolicy.successCode(30, BiometricAuthenticationType.OTHER))
        assertNull(BiometricPolicy.successCode(30, BiometricAuthenticationType.UNKNOWN))
        assertNull(BiometricPolicy.successCode(30, null))
    }

    @Test
    fun authenticationResponseContainsOnlyFrozenFields() {
        assertEquals(
            mapOf("kind" to "authenticated", "code" to "biometric.authenticated", "requestId" to idA),
            BiometricPolicy.authenticationEnvelope("authenticated", "biometric.authenticated", idA),
        )
    }

    @Test
    fun startRequiresFocusedResumedVisibleCurrentForegroundHost() {
        val ready = BiometricHostSnapshot(true, true, true, true, true, true, false, false)
        assertTrue(BiometricPolicy.canStart(ready))
        assertFalse(BiometricPolicy.canStart(ready.copy(currentActivity = false)))
        assertFalse(BiometricPolicy.canStart(ready.copy(resumed = false)))
        assertFalse(BiometricPolicy.canStart(ready.copy(processForeground = false)))
        assertFalse(BiometricPolicy.canStart(ready.copy(windowFocused = false)))
        assertFalse(BiometricPolicy.canStart(ready.copy(windowVisible = false)))
        assertFalse(BiometricPolicy.canStart(ready.copy(finishing = true)))
        assertFalse(BiometricPolicy.canStart(ready.copy(destroyed = true)))
    }

    @Test
    fun callbackAllowsOsModalPauseButRejectsStoppedBackgroundAndDetachedHost() {
        val modal = BiometricHostSnapshot(true, true, false, true, false, false, false, false)
        assertTrue(BiometricPolicy.canDeliverSuccess(modal))
        assertFalse(BiometricPolicy.canDeliverSuccess(modal.copy(started = false)))
        assertFalse(BiometricPolicy.canDeliverSuccess(modal.copy(processForeground = false)))
        assertFalse(BiometricPolicy.canDeliverSuccess(modal.copy(currentActivity = false)))
        assertFalse(BiometricPolicy.canDeliverSuccess(modal.copy(destroyed = true)))
    }

    @Test
    fun readyAndForegroundAreBothRequiredBeforePromptCanOpen() {
        val host = BiometricHostSnapshot(true, true, true, true, true, true, false, false)
        val ready = BiometricAvailability(BiometricAvailabilityState.READY, "biometric.ready")
        val unavailable = BiometricAvailability(
            BiometricAvailabilityState.NOT_ENROLLED,
            "biometric.not_enrolled",
        )
        assertTrue(BiometricPolicy.shouldOpenPrompt(ready, host))
        assertFalse(BiometricPolicy.shouldOpenPrompt(unavailable, host))
        assertFalse(BiometricPolicy.shouldOpenPrompt(ready, null))
        assertFalse(BiometricPolicy.shouldOpenPrompt(ready, host.copy(windowFocused = false)))
    }

    @Test
    fun temporaryPauseAndFocusLossDoNotCancelButStopAndDetachDo() {
        assertFalse(BiometricPolicy.shouldCancelForLifecycle(BiometricLifecycleEvent.PAUSED))
        assertTrue(BiometricPolicy.shouldCancelForLifecycle(BiometricLifecycleEvent.STOPPED))
        assertTrue(BiometricPolicy.shouldCancelForLifecycle(BiometricLifecycleEvent.DESTROYED))
    }

    @Test
    fun pendingConflictPreservesIncumbentAndOldIdCannotCancelNewOperation() {
        val fence = BiometricOperationFence()
        val first = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        assertEquals(BiometricOperationStart.Conflict, fence.begin(idB))
        assertEquals(first, fence.matchingPending(idA))
        assertNull(fence.matchingPending(idB))
        assertTrue(fence.settle(first))
        val second = (fence.begin(idB) as BiometricOperationStart.Started).ticket
        assertNull(fence.matchingPending(idA))
        assertEquals(second, fence.matchingPending(idB))
        assertFalse(fence.settle(first))
    }

    @Test
    fun repeatedAndLateCallbacksCannotSettleTwiceOrAffectReplacement() {
        val fence = BiometricOperationFence()
        val first = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        assertTrue(fence.isCurrent(first))
        assertTrue(fence.settle(first))
        assertFalse(fence.settle(first))
        val second = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        assertFalse(fence.isCurrent(first))
        assertTrue(fence.isCurrent(second))
        assertFalse(fence.settle(first))
        assertTrue(fence.isCurrent(second))
    }

    @Test
    fun androidFailedMatchIsNonterminalAndLeavesSameOperationPending() {
        val fence = BiometricOperationFence()
        val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        repeat(3) {
            assertTrue(fence.noteAuthenticationFailed(ticket))
            assertTrue(fence.isCurrent(ticket))
            assertEquals(ticket, fence.matchingPending(idA))
        }
        assertTrue(fence.settle(ticket))
        assertFalse(fence.noteAuthenticationFailed(ticket))
    }

    @Test
    fun cancellationHandleIsInvokedExactlyOnceOnEveryTerminalPath() {
        for (terminal in listOf("success", "error", "cancel", "detach")) {
            val fence = BiometricOperationFence()
            val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
            var cancellations = 0
            assertTrue(fence.installCancellation(ticket) { cancellations++ })
            assertTrue(fence.settle(ticket))
            assertFalse(fence.settle(ticket))
            assertEquals(1, cancellations)
        }
    }

    @Test
    fun synchronousCompletionBeforeNativeHandleInstallCancelsLateHandleOnce() {
        val fence = BiometricOperationFence()
        val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        var callbacks = 0
        var cancellations = 0
        // A fake prompt completes while Driver.startPrompt is executing, before its return value
        // (the native cancellation handle) can be installed into the operation fence.
        assertTrue(fence.settle(ticket))
        callbacks++
        assertFalse(fence.installCancellation(ticket) { cancellations++ })
        assertEquals(1, callbacks)
        assertEquals(1, cancellations)
        assertFalse(fence.settle(ticket))
        assertEquals(1, cancellations)
    }

    @Test
    fun securityFailureAfterDriverStartSettlesAndCancelsAlreadyInstalledSignalOnce() {
        val fence = BiometricOperationFence()
        val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        var cancelSignals = 0
        var driverAttempts = 0
        val outcome = BiometricDriverStart.start(
            fence = fence,
            ticket = ticket,
            cancelNative = { cancelSignals++ },
            startNative = {
                driverAttempts++
                // The fence owns the cancellation signal before the native authenticate call.
                assertTrue(ticket.cancellationAction != null)
                throw SecurityException("deliberately not surfaced")
            },
        )
        assertEquals(BiometricDriverStartOutcome.PERMISSION_REJECTED, outcome)
        assertEquals(
            "denied" to "biometric.permission_required",
            BiometricPolicy.promptStartFailure(outcome),
        )
        assertEquals(
            BiometricPolicy.authenticationEnvelope("denied", "biometric.permission_required", idA),
            BiometricPolicy.authenticationEnvelope(
                BiometricPolicy.promptStartFailure(outcome)!!.first,
                BiometricPolicy.promptStartFailure(outcome)!!.second,
                idA,
            ),
        )
        assertEquals(1, driverAttempts)
        assertTrue(fence.settle(ticket))
        assertEquals(1, cancelSignals)
        assertFalse(fence.settle(ticket))
        assertEquals(1, cancelSignals)
    }

    @Test
    fun genericDriverStartFailureSettlesAndCancelsAlreadyInstalledSignalOnce() {
        val fence = BiometricOperationFence()
        val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        var cancelSignals = 0
        val outcome = BiometricDriverStart.start(
            fence = fence,
            ticket = ticket,
            cancelNative = { cancelSignals++ },
            startNative = { throw IllegalStateException("message must not escape") },
        )
        assertEquals(BiometricDriverStartOutcome.FAILURE, outcome)
        assertEquals(
            "failure" to "biometric.prompt_failed",
            BiometricPolicy.promptStartFailure(outcome),
        )
        assertTrue(fence.settle(ticket))
        assertEquals(1, cancelSignals)
    }

    @Test
    fun synchronousCompletionBeforeDriverReturnsCancelsSignalAndCannotTouchReplacement() {
        val fence = BiometricOperationFence()
        val old = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        var cancellations = 0
        var driverAttempts = 0
        var replacement: BiometricOperationTicket? = null
        val outcome = BiometricDriverStart.start(
            fence = fence,
            ticket = old,
            cancelNative = { cancellations++ },
            startNative = {
                driverAttempts++
                assertTrue(fence.settle(old))
                replacement = (fence.begin(idB) as BiometricOperationStart.Started).ticket
            },
        )
        assertEquals(BiometricDriverStartOutcome.STARTED, outcome)
        assertEquals(1, driverAttempts)
        assertEquals(1, cancellations)
        assertTrue(fence.isCurrent(requireNotNull(replacement)))
        assertFalse(fence.settle(old))
        assertTrue(fence.isCurrent(requireNotNull(replacement)))
        assertEquals(1, cancellations)
    }

    @Test
    fun alreadySettledOperationCancelsHandleWithoutCallingNativeDriver() {
        val fence = BiometricOperationFence()
        val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        assertTrue(fence.settle(ticket))
        var cancellations = 0
        var driverAttempts = 0
        assertEquals(
            BiometricDriverStartOutcome.NOT_STARTED,
            BiometricDriverStart.start(
                fence = fence,
                ticket = ticket,
                cancelNative = { cancellations++ },
                startNative = { driverAttempts++ },
            ),
        )
        assertEquals(1, cancellations)
        assertEquals(0, driverAttempts)
    }

    @Test
    fun duplicateLateCancellationHandleIsImmediatelyCancelledWithoutReplacingOriginal() {
        val fence = BiometricOperationFence()
        val ticket = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        var first = 0
        var duplicate = 0
        assertTrue(fence.installCancellation(ticket) { first++ })
        assertFalse(fence.installCancellation(ticket) { duplicate++ })
        assertEquals(0, first)
        assertEquals(1, duplicate)
        assertTrue(fence.settle(ticket))
        assertEquals(1, first)
        assertEquals(1, duplicate)
    }

    @Test
    fun cleanupActionsRunOnceAndLateRegistrationIsCleanedImmediately() {
        val cleanup = BiometricOperationCleanup()
        var observersRemoved = 0
        cleanup.add { observersRemoved++ }
        cleanup.close()
        cleanup.close()
        assertEquals(1, observersRemoved)
        cleanup.add { observersRemoved++ }
        assertEquals(2, observersRemoved)
    }

    @Test
    fun channelCancellationOnlyAcknowledgesMatchingPendingIdentity() {
        val fence = BiometricOperationFence()
        val operation = (fence.begin(idA) as BiometricOperationStart.Started).ticket
        assertNull(fence.matchingPending(idB))
        assertTrue(fence.matchingPending(idA) === operation)
        assertTrue(fence.settle(operation))
        assertNull(fence.matchingPending(idA))
    }
}
