package dev.lunardev.starterkit.platform

import android.content.pm.PackageManager
import org.junit.Assert.*
import org.junit.Test

class PushPolicyTest {
    @Test fun callsRequireNullArguments() {
        assertTrue(PushPolicy.parseNoArguments(null))
        assertFalse(PushPolicy.parseNoArguments(emptyMap<String, Any>()))
        assertFalse(PushPolicy.parseNoArguments(false))
    }

    @Test fun android33MissingManifestDeclarationIsNotConfigured() {
        assertEquals(
            PushPolicy.response("unavailable", "push.permission_not_configured"),
            PushPolicy.status(true, permissionDeclared = false, permissionGranted = false, notificationsEnabled = false),
        )
    }

    @Test fun grantedRequiresBothRuntimePermissionAndEnabledNotifications() {
        assertEquals(
            PushPolicy.response("granted", "push.permission_granted"),
            PushPolicy.status(true, true, true, true),
        )
        assertEquals(
            PushPolicy.response("denied", "push.permission_denied"),
            PushPolicy.status(true, true, false, true),
        )
        assertEquals(
            PushPolicy.response("denied", "push.permission_denied"),
            PushPolicy.status(true, true, true, false),
        )
    }

    @Test fun pre33UsesNotificationToggleWithoutRuntimePermission() {
        assertEquals(
            PushPolicy.response("granted", "push.permission_granted"),
            PushPolicy.status(false, permissionDeclared = false, permissionGranted = false, notificationsEnabled = true),
        )
        assertEquals(
            PushPolicy.response("denied", "push.permission_denied"),
            PushPolicy.status(false, permissionDeclared = false, permissionGranted = false, notificationsEnabled = false),
        )
    }

    @Test fun foregroundAndPermissionCallbackMustMatchExactRequest() {
        assertTrue(PushPolicy.foregroundActivity(true, false, false, true, true))
        assertFalse(PushPolicy.foregroundActivity(true, false, false, false, true))
        assertFalse(PushPolicy.foregroundActivity(true, true, false, true, true))
        val ticket = PushTicket(0x5500)
        val exact = arrayOf(PushPolicy.POST_NOTIFICATIONS)
        assertTrue(PushPolicy.isExpectedPermissionCallback(ticket.requestCode, ticket, exact, intArrayOf(PackageManager.PERMISSION_GRANTED)))
        assertFalse(PushPolicy.isExpectedPermissionCallback(ticket.requestCode + 1, ticket, exact, intArrayOf(PackageManager.PERMISSION_GRANTED)))
        assertFalse(PushPolicy.isExpectedPermissionCallback(ticket.requestCode, ticket, arrayOf("other.permission"), intArrayOf(PackageManager.PERMISSION_GRANTED)))
        assertFalse(PushPolicy.isExpectedPermissionCallback(ticket.requestCode, ticket, exact, intArrayOf()))
    }

    @Test fun deniedAndGrantedCallbacksMapToFixedOutcomes() {
        assertEquals(
            PushPolicy.response("granted", "push.permission_granted"),
            PushPolicy.permissionResult(true, true),
        )
        assertEquals(
            PushPolicy.response("denied", "push.permission_denied"),
            PushPolicy.permissionResult(false, true),
        )
        assertEquals(
            PushPolicy.response("denied", "push.permission_denied"),
            PushPolicy.permissionResult(true, false),
        )
    }

    @Test fun permissionRequestCodesAreMonotonicAndOperationSettlesOnce() {
        val first = PushPolicy.requestCode()!!
        val second = PushPolicy.requestCode()!!
        assertTrue(first in 0x5500..0x55ff)
        assertEquals(first + 1, second)
        val state = PushOperationState(PushTicket(first))
        assertTrue(state.settle())
        assertFalse(state.settle())
    }
}
