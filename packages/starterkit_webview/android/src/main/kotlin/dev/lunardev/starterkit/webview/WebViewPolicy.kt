package dev.lunardev.starterkit.webview

import java.net.URI
import java.util.Locale
import org.json.JSONObject

internal data class TrustedOrigin(val host: String, val port: Int) {
    fun originRule(): String {
        val normalizedHost = if (host.contains(':')) "[$host]" else host
        return "https://$normalizedHost" + if (port == 443) "" else ":$port"
    }

    fun matches(uri: URI): Boolean =
        uri.scheme.equals("https", true) &&
            uri.host?.equals(host, true) == true &&
            uri.rawAuthority?.contains('%') == false &&
            uri.rawAuthority?.endsWith(':') == false &&
            uri.rawUserInfo == null &&
            uri.port in -1..65535 &&
            (if (uri.port == -1) 443 else uri.port) == port

    companion object {
        fun parse(raw: String): TrustedOrigin? = runCatching {
            require(raw.isNotBlank() && raw == raw.trim() && !raw.any(Char::isWhitespace))
            val uri = URI(raw)
            val authority = requireNotNull(uri.rawAuthority)
            require(
                uri.scheme.equals("https", true) &&
                    uri.rawUserInfo == null &&
                    uri.rawQuery == null &&
                    uri.rawFragment == null,
            )
            require(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")
            require(!authority.contains('%') && !authority.endsWith(':'))
            val host = requireNotNull(uri.host).lowercase(Locale.ROOT)
            val port = if (uri.port == -1) 443 else uri.port.also { require(it in 1..65535) }
            TrustedOrigin(host, port)
        }.getOrNull()
    }
}

internal enum class NavigationDecision {
    INTERNAL,
    LOCAL_ASSET,
    EXTERNAL_BROWSER,
    EXTERNAL_APP,
    BLOCKED,
}

internal class NavigationPolicy(
    private val origin: TrustedOrigin,
    externalSchemes: Set<String>,
) {
    private val schemes = externalSchemes.map { it.lowercase(Locale.ROOT) }.toSet()

    fun decide(raw: String?, mainFrame: Boolean, userGesture: Boolean): NavigationDecision {
        val uri = runCatching { URI(raw ?: "") }.getOrNull() ?: return NavigationDecision.BLOCKED
        if (isLocal(uri)) return NavigationDecision.LOCAL_ASSET
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return NavigationDecision.BLOCKED
        if (scheme == "https") {
            if (!validAuthority(uri)) return NavigationDecision.BLOCKED
            if (origin.matches(uri)) return NavigationDecision.INTERNAL
            return if (mainFrame && userGesture) {
                NavigationDecision.EXTERNAL_BROWSER
            } else {
                NavigationDecision.BLOCKED
            }
        }
        return if (
            scheme in schemes &&
                mainFrame &&
                userGesture &&
                uri.rawUserInfo == null
        ) {
            NavigationDecision.EXTERNAL_APP
        } else {
            NavigationDecision.BLOCKED
        }
    }

    private fun validAuthority(uri: URI): Boolean =
        uri.rawAuthority != null &&
            !uri.rawAuthority.contains('%') &&
            !uri.rawAuthority.endsWith(':') &&
            uri.rawUserInfo == null &&
            !uri.host.isNullOrEmpty() &&
            uri.port in -1..65535

    private fun isLocal(uri: URI): Boolean =
        uri.scheme.equals("https", true) &&
            uri.host.equals(LOCAL_HOST, true) &&
            uri.rawUserInfo == null &&
            uri.rawQuery == null &&
            uri.rawFragment == null &&
            (uri.port == -1 || uri.port == 443) &&
            uri.rawPath?.startsWith(LOCAL_PATH_PREFIX) == true &&
            uri.rawPath.split('/').none {
                it == "." || it == ".." || it.contains('%') || it.contains('\\')
            }

    companion object {
        const val LOCAL_HOST = "appassets.starterkit.invalid"
        const val LOCAL_ORIGIN = "https://$LOCAL_HOST"
        const val LOCAL_START_URL = "$LOCAL_ORIGIN/starterkit-webview/index.html"
        const val LOCAL_PATH_PREFIX = "/starterkit-webview/"
    }
}

internal data class BridgeRequest(val id: String, val method: String)

internal object BridgeProtocol {
    const val MAX_ENVELOPE_BYTES = 16_384
    const val MAX_STRING_LENGTH = 128

    fun parse(raw: String): BridgeRequest? {
        if (raw.toByteArray(Charsets.UTF_8).size > MAX_ENVELOPE_BYTES) return null
        return runCatching {
            val json = JSONObject(raw)
            val id = json.opt("id") as? String ?: return null
            val method = json.opt("method") as? String ?: return null
            val version = json.opt("version")
            val params = json.optJSONObject("params") ?: return null
            if (
                id.length !in 1..MAX_STRING_LENGTH ||
                    method.length !in 1..MAX_STRING_LENGTH ||
                    version !is Number ||
                    version.toDouble() != 1.0 ||
                    version is Double ||
                    version is Float
            ) {
                return null
            }
            val keys = params.keys()
            while (keys.hasNext()) if (keys.next().isEmpty()) return null
            BridgeRequest(id, method)
        }.getOrNull()
    }

    fun success(id: String, version: String): String =
        JSONObject()
            .put("id", id.take(MAX_STRING_LENGTH))
            .put("success", true)
            .put("result", JSONObject().put("version", version.take(1024)))
            .toString()

    fun failure(id: String, code: String): String =
        JSONObject()
            .put("id", id.take(MAX_STRING_LENGTH))
            .put("success", false)
            .put("error", JSONObject().put("code", code))
            .toString()
}

internal object BridgeScript {
    val source = """
        window.NativeBridge = (() => {
          const pending = new Map(), timeoutMs = 30000;
          function fail(code) { return {code: code || 'NATIVE_ERROR'}; }
          if (window.StarterkitNative) {
            window.StarterkitNative.onmessage = function(event) {
              let response;
              try { response = JSON.parse(event.data); } catch (_) { return; }
              const item = pending.get(response && response.id);
              if (!item) return;
              pending.delete(response.id);
              clearTimeout(item.timer);
              response.success ? item.resolve(response.result) : item.reject(fail(response.error && response.error.code));
            };
          }
          function request(message) {
            if (!message || typeof message !== 'object' || message.version !== 1 ||
                typeof message.id !== 'string' || message.id.length < 1 || message.id.length > 128 ||
                typeof message.method !== 'string' || message.method.length < 1 || message.method.length > 128 ||
                !message.params || typeof message.params !== 'object' || Array.isArray(message.params) ||
                pending.has(message.id) ||
                new TextEncoder().encode(JSON.stringify(message)).length > 16384 ||
                !window.StarterkitNative) {
              return Promise.reject(fail('INVALID_REQUEST'));
            }
            return new Promise((resolve, reject) => {
              const timer = setTimeout(() => {
                pending.delete(message.id);
                reject(fail('TIMEOUT'));
              }, timeoutMs);
              pending.set(message.id, {resolve, reject, timer});
              window.StarterkitNative.postMessage(JSON.stringify(message));
            });
          }
          return {request};
        })();
    """.trimIndent()
}
