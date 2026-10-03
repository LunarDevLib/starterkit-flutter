package dev.lunardev.starterkit.platform

import java.nio.charset.StandardCharsets

internal enum class BiometricAvailabilityState {
    READY,
    PERMISSION_REQUIRED,
    NO_HARDWARE,
    NOT_ENROLLED,
    LOCKED_OUT,
    UNAVAILABLE,
}

internal data class BiometricAvailability(
    val state: BiometricAvailabilityState,
    val code: String,
)

internal data class BiometricRequest(val requestId: String, val reason: String)

internal sealed class BiometricParseResult {
    data class Valid(val request: BiometricRequest) : BiometricParseResult()
    data class InvalidRequest(val requestId: String? = null) : BiometricParseResult()
    data class InvalidReason(val requestId: String) : BiometricParseResult()
}

internal enum class BiometricPlatformAvailability {
    SUCCESS,
    NO_HARDWARE,
    NOT_ENROLLED,
    LOCKED_OUT,
    HARDWARE_UNAVAILABLE,
    UNKNOWN,
}

internal enum class BiometricAvailabilityFailure { PERMISSION, PLATFORM }

internal enum class BiometricPromptError {
    USER_CANCELLED,
    LOCKED_OUT,
    NO_HARDWARE,
    NOT_ENROLLED,
    HARDWARE_UNAVAILABLE,
    OTHER,
}

internal enum class BiometricFrameworkPolicy { UNSUPPORTED, API29_DEFAULT, API30_STRONG }

internal enum class BiometricAuthenticationType {
    BIOMETRIC,
    OTHER,
    UNKNOWN,
}

internal data class BiometricHostSnapshot(
    val currentActivity: Boolean,
    val started: Boolean,
    val resumed: Boolean,
    val processForeground: Boolean,
    val windowFocused: Boolean,
    val windowVisible: Boolean,
    val finishing: Boolean,
    val destroyed: Boolean,
)

internal enum class BiometricLifecycleEvent { PAUSED, STOPPED, DESTROYED }

/** Pure protocol parsing, fixed response policy, and callback-generation fencing. */
internal object BiometricPolicy {
    private val requestIdPattern = Regex("^[0-9a-f]{32}$")

    fun validRequestId(value: Any?): String? =
        (value as? String)?.takeIf(requestIdPattern::matches)

    fun parseAvailabilityRequest(arguments: Any?): Boolean = arguments == null

    fun parseAuthenticateRequest(arguments: Any?): BiometricParseResult {
        val values = arguments as? Map<*, *> ?: return BiometricParseResult.InvalidRequest()
        val requestId = validRequestId(values["requestId"])
            ?: return BiometricParseResult.InvalidRequest()
        if (values.keys != setOf("requestId", "reason")) {
            return BiometricParseResult.InvalidRequest(requestId)
        }
        val reason = values["reason"] as? String
            ?: return BiometricParseResult.InvalidReason(requestId)
        if (!validReason(reason)) return BiometricParseResult.InvalidReason(requestId)
        return BiometricParseResult.Valid(BiometricRequest(requestId, reason))
    }

    fun parseCancelRequest(arguments: Any?): String? {
        val values = arguments as? Map<*, *> ?: return null
        if (values.keys != setOf("requestId")) return null
        return validRequestId(values["requestId"])
    }

    fun validReason(reason: String): Boolean =
        reason.trim().isNotEmpty() && '\u0000' !in reason &&
            reason.toByteArray(StandardCharsets.UTF_8).size in 1..BIOMETRIC_MAX_REASON_BYTES

    fun availability(
        sdkInt: Int,
        permissionDeclared: Boolean,
        permissionGranted: Boolean,
        platform: BiometricPlatformAvailability,
    ): BiometricAvailability {
        if (!permissionDeclared || !permissionGranted) {
            return BiometricAvailability(
                BiometricAvailabilityState.PERMISSION_REQUIRED,
                "biometric.permission_required",
            )
        }
        // API 24..28 deliberately never reaches the framework biometric APIs.
        if (sdkInt < BIOMETRIC_MINIMUM_API) {
            return BiometricAvailability(BiometricAvailabilityState.UNAVAILABLE, "biometric.platform_unavailable")
        }
        return when (platform) {
            BiometricPlatformAvailability.SUCCESS ->
                BiometricAvailability(BiometricAvailabilityState.READY, "biometric.ready")
            BiometricPlatformAvailability.NO_HARDWARE ->
                BiometricAvailability(BiometricAvailabilityState.NO_HARDWARE, "biometric.no_hardware")
            BiometricPlatformAvailability.NOT_ENROLLED ->
                BiometricAvailability(BiometricAvailabilityState.NOT_ENROLLED, "biometric.not_enrolled")
            BiometricPlatformAvailability.LOCKED_OUT ->
                BiometricAvailability(BiometricAvailabilityState.LOCKED_OUT, "biometric.locked_out")
            BiometricPlatformAvailability.HARDWARE_UNAVAILABLE ->
                BiometricAvailability(BiometricAvailabilityState.UNAVAILABLE, "biometric.unavailable")
            BiometricPlatformAvailability.UNKNOWN ->
                BiometricAvailability(
                    BiometricAvailabilityState.UNAVAILABLE,
                    "biometric.platform_unavailable",
                )
        }
    }

    fun availabilityFailure(failure: BiometricAvailabilityFailure): BiometricAvailability =
        when (failure) {
            BiometricAvailabilityFailure.PERMISSION ->
                BiometricAvailability(
                    BiometricAvailabilityState.PERMISSION_REQUIRED,
                    "biometric.permission_required",
                )
            BiometricAvailabilityFailure.PLATFORM ->
                BiometricAvailability(
                    BiometricAvailabilityState.UNAVAILABLE,
                    "biometric.platform_failure",
                )
        }

    fun frameworkPolicy(sdkInt: Int): BiometricFrameworkPolicy = when {
        sdkInt < BIOMETRIC_MINIMUM_API -> BiometricFrameworkPolicy.UNSUPPORTED
        sdkInt < BIOMETRIC_STRONG_API -> BiometricFrameworkPolicy.API29_DEFAULT
        else -> BiometricFrameworkPolicy.API30_STRONG
    }

    fun availabilityEnvelope(availability: BiometricAvailability): Map<String, Any> =
        mapOf("state" to availability.state.wireValue(), "code" to availability.code)

    fun authenticationPreflight(
        availability: BiometricAvailability,
        requestId: String,
    ): Map<String, Any> =
        when (availability.state) {
            BiometricAvailabilityState.READY -> error("ready availability has no refusal envelope")
            BiometricAvailabilityState.PERMISSION_REQUIRED ->
                authenticationEnvelope("denied", "biometric.permission_required", requestId)
            BiometricAvailabilityState.NO_HARDWARE ->
                authenticationEnvelope("unavailable", "biometric.no_hardware", requestId)
            BiometricAvailabilityState.NOT_ENROLLED ->
                authenticationEnvelope("unavailable", "biometric.not_enrolled", requestId)
            BiometricAvailabilityState.LOCKED_OUT ->
                authenticationEnvelope("lockedOut", "biometric.locked_out", requestId)
            BiometricAvailabilityState.UNAVAILABLE ->
                if (availability.code == "biometric.platform_failure") {
                    authenticationEnvelope("failure", "biometric.platform_failure", requestId)
                } else {
                    authenticationEnvelope(
                        "unavailable",
                        availability.code.takeIf(AUTH_UNAVAILABLE_CODES::contains)
                            ?: "biometric.platform_unavailable",
                        requestId,
                    )
                }
        }

    fun promptError(error: BiometricPromptError): Pair<String, String> = when (error) {
        BiometricPromptError.USER_CANCELLED -> "cancelled" to "biometric.cancelled"
        BiometricPromptError.LOCKED_OUT -> "lockedOut" to "biometric.locked_out"
        BiometricPromptError.NO_HARDWARE -> "unavailable" to "biometric.no_hardware"
        BiometricPromptError.NOT_ENROLLED -> "unavailable" to "biometric.not_enrolled"
        BiometricPromptError.HARDWARE_UNAVAILABLE -> "unavailable" to "biometric.unavailable"
        BiometricPromptError.OTHER -> "failure" to "biometric.platform_failure"
    }

    fun promptStartFailure(outcome: BiometricDriverStartOutcome): Pair<String, String>? = when (outcome) {
        BiometricDriverStartOutcome.PERMISSION_REJECTED ->
            "denied" to "biometric.permission_required"
        BiometricDriverStartOutcome.FAILURE -> "failure" to "biometric.prompt_failed"
        BiometricDriverStartOutcome.STARTED,
        BiometricDriverStartOutcome.NOT_STARTED -> null
    }

    fun successCode(sdkInt: Int, authenticationType: BiometricAuthenticationType?): String? = when {
        sdkInt < BIOMETRIC_STRONG_API -> "biometric.authenticated"
        authenticationType == BiometricAuthenticationType.BIOMETRIC -> "biometric.authenticated"
        else -> null
    }

    fun canStart(snapshot: BiometricHostSnapshot): Boolean =
        snapshot.currentActivity && snapshot.started && snapshot.resumed && snapshot.processForeground &&
            snapshot.windowFocused && snapshot.windowVisible && !snapshot.finishing && !snapshot.destroyed

    fun canDeliverSuccess(snapshot: BiometricHostSnapshot): Boolean =
        snapshot.currentActivity && snapshot.started && snapshot.processForeground &&
            !snapshot.finishing && !snapshot.destroyed

    fun shouldOpenPrompt(
        availability: BiometricAvailability,
        host: BiometricHostSnapshot?,
    ): Boolean = availability.state == BiometricAvailabilityState.READY &&
        host?.let(::canStart) == true

    fun shouldCancelForLifecycle(event: BiometricLifecycleEvent): Boolean =
        event == BiometricLifecycleEvent.STOPPED || event == BiometricLifecycleEvent.DESTROYED

    fun authenticationEnvelope(kind: String, code: String, requestId: String): Map<String, Any> =
        mapOf("kind" to kind, "code" to code, "requestId" to requestId)

    fun cancellationEnvelope(requestId: String, code: String): Map<String, Any> =
        authenticationEnvelope("cancelled", code, requestId)

    private fun BiometricAvailabilityState.wireValue(): String = when (this) {
        BiometricAvailabilityState.READY -> "ready"
        BiometricAvailabilityState.PERMISSION_REQUIRED -> "permissionRequired"
        BiometricAvailabilityState.NO_HARDWARE -> "noHardware"
        BiometricAvailabilityState.NOT_ENROLLED -> "notEnrolled"
        BiometricAvailabilityState.LOCKED_OUT -> "lockedOut"
        BiometricAvailabilityState.UNAVAILABLE -> "unavailable"
    }

    private val AUTH_UNAVAILABLE_CODES = setOf(
        "biometric.unavailable",
        "biometric.disabled",
        "biometric.platform_unavailable",
        "biometric.no_hardware",
        "biometric.not_enrolled",
        "biometric.face_id_not_configured",
    )
}

internal const val BIOMETRIC_MINIMUM_API = 29
internal const val BIOMETRIC_STRONG_API = 30
internal const val BIOMETRIC_MAX_REASON_BYTES = 256

internal class BiometricOperationTicket internal constructor(val requestId: String) {
    internal var settled = false
    internal var cancellationRequested = false
    internal var cancellationInvoked = false
    internal var cancellationAction: (() -> Unit)? = null
}

internal sealed class BiometricOperationStart {
    data class Started(val ticket: BiometricOperationTicket) : BiometricOperationStart()
    data object Conflict : BiometricOperationStart()
}

/** Single-pending operation identity plus a late-install-safe, exactly-once cancellation signal. */
internal class BiometricOperationFence {
    private var current: BiometricOperationTicket? = null

    @Synchronized
    fun begin(requestId: String): BiometricOperationStart {
        if (current != null) return BiometricOperationStart.Conflict
        return BiometricOperationTicket(requestId).also { current = it }
            .let(BiometricOperationStart::Started)
    }

    @Synchronized
    fun isCurrent(ticket: BiometricOperationTicket): Boolean =
        current === ticket && !ticket.settled

    @Synchronized
    fun matchingPending(requestId: String): BiometricOperationTicket? =
        current?.takeIf { !it.settled && it.requestId == requestId }

    @Synchronized
    fun noteAuthenticationFailed(ticket: BiometricOperationTicket): Boolean = isCurrent(ticket)

    fun installCancellation(ticket: BiometricOperationTicket, cancel: () -> Unit): Boolean {
        val invokeNow = synchronized(this) {
            if (ticket.cancellationAction != null || ticket.cancellationInvoked) {
                true
            } else {
                ticket.cancellationAction = cancel
                if (ticket.cancellationRequested || ticket.settled) {
                    ticket.cancellationInvoked = true
                    ticket.cancellationAction = null
                    true
                } else {
                    false
                }
            }
        }
        if (invokeNow) runCatching(cancel)
        return !invokeNow
    }

    fun settle(ticket: BiometricOperationTicket): Boolean {
        val cancellation = synchronized(this) {
            if (current !== ticket || ticket.settled) return false
            current = null
            ticket.settled = true
            ticket.cancellationRequested = true
            if (ticket.cancellationAction != null && !ticket.cancellationInvoked) {
                ticket.cancellationInvoked = true
                ticket.cancellationAction.also { ticket.cancellationAction = null }
            } else {
                null
            }
        }
        cancellation?.let { runCatching(it) }
        return true
    }
}

internal enum class BiometricDriverStartOutcome { STARTED, NOT_STARTED, PERMISSION_REJECTED, FAILURE }

/** Installs cancellation before calling native prompt code and fences completion/reentrancy. */
internal object BiometricDriverStart {
    fun start(
        fence: BiometricOperationFence,
        ticket: BiometricOperationTicket,
        cancelNative: () -> Unit,
        startNative: () -> Unit,
    ): BiometricDriverStartOutcome {
        if (!fence.installCancellation(ticket, cancelNative) || !fence.isCurrent(ticket)) {
            return BiometricDriverStartOutcome.NOT_STARTED
        }
        return try {
            startNative()
            BiometricDriverStartOutcome.STARTED
        } catch (_: SecurityException) {
            BiometricDriverStartOutcome.PERMISSION_REJECTED
        } catch (_: Throwable) {
            BiometricDriverStartOutcome.FAILURE
        }
    }
}

/** Idempotent prompt-observer cleanup, also safe when registration races with settlement. */
internal class BiometricOperationCleanup {
    private val actions = mutableListOf<() -> Unit>()
    private var closed = false

    fun add(action: () -> Unit) {
        val runNow = synchronized(this) {
            if (closed) true else {
                actions.add(action)
                false
            }
        }
        if (runNow) runCatching(action)
    }

    fun close() {
        val toRun = synchronized(this) {
            if (closed) return
            closed = true
            actions.toList().also { actions.clear() }
        }
        toRun.forEach { runCatching(it) }
    }
}
