package dev.lunardev.starterkit.platform

import java.net.URI
import java.net.URLDecoder

internal data class NativeShareRequest(
    val text: String?,
    val httpsUrl: String?,
    val fileUri: String?,
    val anchor: ShareAnchor?,
)

internal data class ShareAnchor(val x: Double, val y: Double, val width: Double, val height: Double)

internal data class ShareIntentSpec(
    val action: String,
    val mimeType: String,
    val extraText: String?,
    val streamUri: String?,
    val clipUri: String?,
    val grantReadUriPermission: Boolean,
)

internal sealed class ShareParseResult {
    data class Valid(val request: NativeShareRequest) : ShareParseResult()
    data object Invalid : ShareParseResult()
}

internal enum class ShareLaunchFailureKind { UNAVAILABLE, FILE_UNAVAILABLE, FAILURE }

internal class ShareLaunchFailure(val failureKind: ShareLaunchFailureKind) : RuntimeException()

internal object SharePolicy {
    const val MAX_TEXT_CODEPOINTS = 4000
    const val MAX_TEXT_UTF8 = 16 * 1024
    const val MAX_URL_UTF8 = 2048
    const val MAX_FILE_URI_UTF8 = 2048
    const val MAX_FILE_BYTES = 10L * 1024L * 1024L

    private val sensitiveQueryKeys = listOf(
        "token", "access_token", "authorization", "auth", "api_key", "key", "password",
        "secret", "session", "code",
    )
    private val anchorKeys = setOf("x", "y", "width", "height")

    fun parse(arguments: Any?): ShareParseResult {
        val map = arguments as? Map<*, *> ?: return ShareParseResult.Invalid
        if (map.keys.any { it !is String || it !in setOf("text", "httpsUrl", "fileUri", "anchor") }) {
            return ShareParseResult.Invalid
        }
        val text = if (map.containsKey("text")) map["text"] as? String ?: return ShareParseResult.Invalid else null
        val url = if (map.containsKey("httpsUrl")) map["httpsUrl"] as? String ?: return ShareParseResult.Invalid else null
        val file = if (map.containsKey("fileUri")) map["fileUri"] as? String ?: return ShareParseResult.Invalid else null
        val anchor = if (map.containsKey("anchor")) parseAnchor(map["anchor"]) ?: return ShareParseResult.Invalid else null
        if (text == null && url == null && file == null) return ShareParseResult.Invalid
        if (listOfNotNull(text, url, file).none { it.isNotEmpty() }) return ShareParseResult.Invalid
        if (text != null && !validText(text)) return ShareParseResult.Invalid
        if (url != null && !validHttpsUrl(url)) return ShareParseResult.Invalid
        if (file != null && !validFileUri(file)) return ShareParseResult.Invalid
        return ShareParseResult.Valid(NativeShareRequest(text, url, file, anchor))
    }

    fun intentSpec(request: NativeShareRequest): ShareIntentSpec {
        val text = listOfNotNull(request.text, request.httpsUrl).filter { it.isNotEmpty() }.joinToString("\n").ifEmpty { null }
        return ShareIntentSpec(
            action = "android.intent.action.SEND",
            mimeType = if (request.fileUri != null) "image/*" else "text/plain",
            extraText = text,
            streamUri = request.fileUri,
            clipUri = request.fileUri,
            grantReadUriPermission = request.fileUri != null,
        )
    }

    fun response(kind: String, code: String): Map<String, String> = mapOf("kind" to kind, "code" to code)

    /** Pure call/launch seam used by the Android adapter and JVM tests. */
    fun execute(
        arguments: Any?,
        hostAvailable: Boolean,
        fileAvailable: (String) -> Boolean,
        launch: (ShareIntentSpec) -> Unit,
    ): Map<String, String> {
        val request = when (val parsed = parse(arguments)) {
            is ShareParseResult.Valid -> parsed.request
            ShareParseResult.Invalid -> return response("invalid", "share.invalid_payload")
        }
        if (!hostAvailable) return response("unavailable", "share.host_unavailable")
        if (request.fileUri != null && !runCatching { fileAvailable(request.fileUri) }.getOrDefault(false)) {
            return response("unavailable", "share.file_unavailable")
        }
        return try {
            launch(intentSpec(request))
            response("presented", "share.presented")
        } catch (failure: ShareLaunchFailure) {
            when (failure.failureKind) {
                ShareLaunchFailureKind.UNAVAILABLE -> response("unavailable", "share.platform_unavailable")
                ShareLaunchFailureKind.FILE_UNAVAILABLE -> response("unavailable", "share.file_unavailable")
                ShareLaunchFailureKind.FAILURE -> response("failure", "share.platform_failure")
            }
        } catch (_: Throwable) {
            response("failure", "share.platform_failure")
        }
    }

    fun isReadableImageSize(mimeType: String?, byteLength: Long?): Boolean =
        mimeType?.startsWith("image/", ignoreCase = true) == true &&
            byteLength != null && byteLength in 1..MAX_FILE_BYTES

    fun validText(value: String): Boolean =
        validUnicodeAndControls(value) && value.codePointCount(0, value.length) <= MAX_TEXT_CODEPOINTS &&
            value.toByteArray(Charsets.UTF_8).size <= MAX_TEXT_UTF8

    fun validHttpsUrl(value: String): Boolean {
        if (value.isEmpty() || value.toByteArray(Charsets.UTF_8).size > MAX_URL_UTF8 || !validUnicodeAndControls(value)) return false
        if (value.any { it.isWhitespace() }) return false
        val uri = try { URI(value) } catch (_: Exception) { return false }
        if (!uri.scheme.equals("https", ignoreCase = true) || uri.rawUserInfo != null || uri.rawFragment != null) return false
        if (uri.port != -1 && uri.port != 443) return false
        val authority = uri.rawAuthority ?: return false
        if (authority.isEmpty() || authority.any { it.code > 0x7f || it == '%' || it == '\\' || it == '@' }) return false
        val host = uri.host ?: return false
        if (host.endsWith('.') || host.length > 253 || !host.all { it.code < 128 }) return false
        val labels = host.split('.')
        if (labels.any { label ->
                label.isEmpty() || label.length > 63 ||
                    !label.first().isLetterOrDigit() || !label.last().isLetterOrDigit() ||
                    label.any { !it.isLetterOrDigit() && it != '-' }
            }
        ) return false
        val expectedAuthority = if (uri.port == 443) "$host:443" else host
        if (!authority.equals(expectedAuthority, ignoreCase = true)) return false
        return !hasSensitiveQuery(uri.rawQuery)
    }

    fun validFileUri(value: String): Boolean {
        if (value.isEmpty() || value.toByteArray(Charsets.UTF_8).size > MAX_FILE_URI_UTF8 || !validUnicodeAndControls(value)) return false
        val uri = try { URI(value) } catch (_: Exception) { return false }
        val authority = uri.rawAuthority ?: return false
        return uri.scheme.equals("content", ignoreCase = true) && authority.isNotEmpty() &&
            '@' !in authority && ':' !in authority && '\\' !in authority && '?' !in value && '#' !in value &&
            uri.rawQuery == null && uri.rawFragment == null && uri.rawPath?.isNotEmpty() == true
    }

    private fun parseAnchor(value: Any?): ShareAnchor? {
        val map = value as? Map<*, *> ?: return null
        if (map.keys != anchorKeys) return null
        fun number(key: String): Double? = (map[key] as? Double)?.takeIf { it.isFinite() }
        val x = number("x") ?: return null
        val y = number("y") ?: return null
        val width = number("width") ?: return null
        val height = number("height") ?: return null
        if (x < 0.0 || y < 0.0 || width <= 0.0 || height <= 0.0) return null
        return ShareAnchor(x, y, width, height)
    }

    private fun validUnicodeAndControls(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val current = value[index]
            val codePoint = when {
                current.isHighSurrogate() -> {
                    if (index + 1 >= value.length || !value[index + 1].isLowSurrogate()) return false
                    Character.toCodePoint(current, value[++index])
                }
                current.isLowSurrogate() -> return false
                else -> current.code
            }
            if (codePoint in 0..0x1f || codePoint in 0x7f..0x9f) return false
            index++
        }
        return true
    }

    private fun hasSensitiveQuery(query: String?): Boolean {
        if (query == null) return false
        for (pair in query.split('&')) {
            val encodedKey = pair.substringBefore('=')
            var key = encodedKey
            repeat(3) {
                val decoded = try { URLDecoder.decode(key, Charsets.UTF_8.name()) } catch (_: Exception) { return true }
                if (!validUnicodeAndControls(decoded) || decoded.length > MAX_URL_UTF8) return true
                key = decoded.lowercase()
                if (sensitiveQueryKeys.any { sensitive -> encodedKey.lowercase().contains(sensitive) || key.contains(sensitive) }) return true
            }
        }
        return false
    }
}
