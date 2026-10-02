package dev.lunardev.starterkit.webview

import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebViewPolicyTest {
    @Test
    fun trustedOriginRejectsAmbiguousInputs() {
        assertNull(TrustedOrigin.parse("http://example.com"))
        assertNull(TrustedOrigin.parse("https://example.com/path"))
        assertNull(TrustedOrigin.parse("https://example.com:"))
        assertNull(TrustedOrigin.parse("https://user@example.com"))
    }

    @Test
    fun trustedOriginMatchesExactEffectivePort() {
        val origin = TrustedOrigin.parse("https://example.com:8443")!!
        assertTrue(origin.matches(URI("https://example.com:8443/path")))
        assertFalse(origin.matches(URI("https://example.com/path")))
    }

    @Test
    fun navigationExternalizesOnlyMainFrameUserActions() {
        val policy =
            NavigationPolicy(
                TrustedOrigin.parse("https://example.com")!!,
                setOf("mailto"),
            )
        assertEquals(
            NavigationDecision.INTERNAL,
            policy.decide("https://example.com/a", true, false),
        )
        assertEquals(
            NavigationDecision.EXTERNAL_BROWSER,
            policy.decide("https://outside.example", true, true),
        )
        assertEquals(
            NavigationDecision.BLOCKED,
            policy.decide("https://outside.example", false, true),
        )
        assertEquals(
            NavigationDecision.BLOCKED,
            policy.decide("http://example.com", true, true),
        )
    }

    @Test
    fun bridgeProtocolIsBoundedAndAllowlistReady() {
        val request =
            BridgeProtocol.parse(
                """{"version":1,"id":"one","method":"app.getVersion","params":{}}""",
            )
        assertEquals("one", request?.id)
        assertEquals("app.getVersion", request?.method)
        assertNull(
            BridgeProtocol.parse(
                """{"version":1,"id":"","method":"x","params":{}}""",
            ),
        )
        assertNull(
            BridgeProtocol.parse(
                """{"version":1,"id":"one","method":"x","params":[]}""",
            ),
        )
    }
}
