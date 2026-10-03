package dev.lunardev.starterkit.platform

import java.util.concurrent.atomic.AtomicInteger

internal enum class PushPermissionState { GRANTED, DENIED, NOT_CONFIGURED, INVALID }

internal data class PushTicket(val requestCode: Int, val identity: Any = Any())

/** Narrow notification-permission protocol policy shared by the real handler and JVM tests. */
internal object PushPolicy {
    const val POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"
    private val requestCodes = AtomicInteger(0x5500)

    fun parseNoArguments(arguments: Any?): Boolean = arguments == null

    fun status(api33OrLater: Boolean, permissionDeclared: Boolean, permissionGranted: Boolean, notificationsEnabled: Boolean): Map<String, String> {
        if (api33OrLater && !permissionDeclared) return response("unavailable", "push.permission_not_configured")
        return if (notificationsEnabled && (!api33OrLater || permissionGranted)) {
            response("granted", "push.permission_granted")
        } else {
            // Android does not expose whether a runtime denial is the first request or a prior denial.
            response("denied", "push.permission_denied")
        }
    }

    fun requestCode(): Int? {
        val next = requestCodes.getAndIncrement()
        return next.takeIf { it in 0x5500..0x55ff }
    }

    fun foregroundActivity(attached: Boolean, finishing: Boolean, destroyed: Boolean, focused: Boolean, visible: Boolean): Boolean =
        attached && !finishing && !destroyed && focused && visible

    fun response(kind: String, code: String): Map<String, String> = mapOf("kind" to kind, "code" to code)

    fun isExpectedPermissionCallback(requestCode: Int, ticket: PushTicket, permissions: Array<out String>, grantResults: IntArray): Boolean =
        requestCode == ticket.requestCode && permissions.contentEquals(arrayOf(POST_NOTIFICATIONS)) && grantResults.size == 1

    fun permissionResult(granted: Boolean, notificationsEnabled: Boolean): Map<String, String> =
        if (granted && notificationsEnabled) response("granted", "push.permission_granted")
        else response("denied", "push.permission_denied")
}

/** Per-request terminal fence: detach/callback can only consume the ticket once. */
internal class PushOperationState(val ticket: PushTicket) {
    private var settled = false

    @Synchronized fun settle(): Boolean {
        if (settled) return false
        settled = true
        return true
    }
}
