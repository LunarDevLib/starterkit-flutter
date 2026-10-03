package dev.lunardev.starterkit.platform

import org.junit.Assert.*
import org.junit.Test

class SharePolicyTest {
    private val presented = SharePolicy.response("presented", "share.presented")
    private val invalid = SharePolicy.response("invalid", "share.invalid_payload")

    @Test fun invalidArgumentsNeverInvokeFileOrLaunchSeams() {
        var checks = 0
        var launches = 0
        for (bad in listOf(null, emptyMap<String, Any>(), mapOf("unknown" to "x"), mapOf("text" to null), mapOf("text" to ""))) {
            assertEquals(invalid, SharePolicy.execute(bad, true, { checks++; true }) { launches++ })
        }
        assertEquals(0, checks)
        assertEquals(0, launches)
    }

    @Test fun textRequiresUnicodeCodepointAndUtf8BoundsAndRejectsControls() {
        assertTrue(SharePolicy.validText("x".repeat(4000)))
        assertFalse(SharePolicy.validText("x".repeat(4001)))
        assertTrue(SharePolicy.validText("🌍".repeat(4000))) // 4 UTF-8 bytes * 4000 codepoints
        assertFalse(SharePolicy.validText("🌍".repeat(4001)))
        assertFalse(SharePolicy.validText("a\u0000b"))
        assertFalse(SharePolicy.validText("a\u0085b"))
        assertFalse(SharePolicy.validText("\ud800"))
        assertFalse(SharePolicy.validText("\udc00"))
    }

    @Test fun httpsRequiresSafeAsciiDnsAuthorityAndNoSensitiveQueryKeys() {
        for (url in listOf(
            "http://example.com", "https://user@example.com", "https://example.com:444",
            "https://example.com.", "https://example.com/#fragment", "https://example.com/a b",
            "https://example.com/?token=value", "https://example.com/?%61ccess_token=value",
            "https://example.com/?%2561ccess_token=value", "https://éxample.com/", "https://example.com:bad",
        )) assertFalse(url, SharePolicy.validHttpsUrl(url))
        assertTrue(SharePolicy.validHttpsUrl("https://example.com/path?q=ordinary"))
        assertTrue(SharePolicy.validHttpsUrl("https://example.com:443/"))
        assertFalse(SharePolicy.validHttpsUrl("https://example.com/" + "x".repeat(2048)))
    }

    @Test fun fileUriMustBeContentWithoutQueryOrFragmentAndMetadataMustBeKnownBoundedImage() {
        assertTrue(SharePolicy.validFileUri("content://com.example.images/items/1"))
        for (uri in listOf(
            "file:///tmp/image.png", "https://example.com/image.png", "content://provider/image?x=1",
            "content://provider/image#fragment", "content:///image", "content://user@provider/image",
        )) assertFalse(uri, SharePolicy.validFileUri(uri))
        assertTrue(SharePolicy.isReadableImageSize("image/jpeg", 1))
        assertTrue(SharePolicy.isReadableImageSize("image/png", SharePolicy.MAX_FILE_BYTES))
        assertFalse(SharePolicy.isReadableImageSize("image/png", null))
        assertFalse(SharePolicy.isReadableImageSize("image/png", 0))
        assertFalse(SharePolicy.isReadableImageSize("image/png", SharePolicy.MAX_FILE_BYTES + 1))
        assertFalse(SharePolicy.isReadableImageSize("text/plain", 12))
    }

    @Test fun anchorIsStrictFiniteAndValidatedEvenThoughAndroidDoesNotUseIt() {
        val valid = mapOf("x" to 1.0, "y" to 0.0, "width" to 20.0, "height" to 10.0)
        assertTrue(SharePolicy.parse(mapOf("text" to "x", "anchor" to valid)) is ShareParseResult.Valid)
        assertEquals(invalid, SharePolicy.execute(mapOf("text" to "x", "anchor" to (valid + ("extra" to 1.0))), true, { true }) {})
        assertEquals(invalid, SharePolicy.execute(mapOf("text" to "x", "anchor" to (valid + ("x" to Double.NaN))), true, { true }) {})
        assertEquals(invalid, SharePolicy.execute(mapOf("text" to "x", "anchor" to (valid + ("width" to 0.0))), true, { true }) {})
    }

    @Test fun sharePayloadMapsToNarrowIntentSpecificationAndPreservesText() {
        var spec: ShareIntentSpec? = null
        assertEquals(presented, SharePolicy.execute(mapOf("text" to "  unchanged ", "httpsUrl" to "https://example.com"), true, { false }) { spec = it })
        assertEquals("android.intent.action.SEND", spec?.action)
        assertEquals("text/plain", spec?.mimeType)
        assertEquals("  unchanged \nhttps://example.com", spec?.extraText)
        assertNull(spec?.streamUri)
        assertFalse(spec!!.grantReadUriPermission)

        assertEquals(presented, SharePolicy.execute(mapOf("fileUri" to "content://provider/images/1"), true, { true }) { spec = it })
        assertEquals("image/*", spec?.mimeType)
        assertEquals("content://provider/images/1", spec?.streamUri)
        assertEquals(spec?.streamUri, spec?.clipUri)
        assertTrue(spec!!.grantReadUriPermission)
    }

    @Test fun unavailableHostAndProviderDoNotLaunchAndFailuresAreFixed() {
        var launches = 0
        assertEquals(SharePolicy.response("unavailable", "share.host_unavailable"),
            SharePolicy.execute(mapOf("text" to "hi"), false, { error("not called") }) { launches++ })
        assertEquals(SharePolicy.response("unavailable", "share.file_unavailable"),
            SharePolicy.execute(mapOf("fileUri" to "content://provider/image"), true, { false }) { launches++ })
        assertEquals(0, launches)
        assertEquals(SharePolicy.response("unavailable", "share.platform_unavailable"),
            SharePolicy.execute(mapOf("text" to "hi"), true, { true }) { throw ShareLaunchFailure(ShareLaunchFailureKind.UNAVAILABLE) })
        assertEquals(SharePolicy.response("unavailable", "share.file_unavailable"),
            SharePolicy.execute(mapOf("fileUri" to "content://provider/image"), true, { true }) { throw ShareLaunchFailure(ShareLaunchFailureKind.FILE_UNAVAILABLE) })
        assertEquals(SharePolicy.response("failure", "share.platform_failure"),
            SharePolicy.execute(mapOf("text" to "hi"), true, { true }) { throw IllegalStateException("private detail") })
    }
}
