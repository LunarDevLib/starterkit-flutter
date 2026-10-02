package dev.lunardev.starterkit.webview

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.http.SslError
import android.view.View
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.net.URI
import java.util.Locale

class StarterkitWebViewPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            StarterkitWebViewFactory(binding.binaryMessenger),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit

    companion object {
        private const val VIEW_TYPE = "starterkit/webview"
    }
}

private data class NativeConfiguration(
    val trustedOrigin: TrustedOrigin,
    val startUrl: String,
    val bridgeEnabled: Boolean,
    val externalSchemes: Set<String>,
) {
    companion object {
        fun parse(arguments: Any?): NativeConfiguration? {
            val map = arguments as? Map<*, *> ?: return null
            val origin =
                TrustedOrigin.parse(map["trustedOrigin"] as? String ?: return null) ?: return null
            val startUrl = map["startUrl"] as? String ?: return null
            val bridgeEnabled = map["bridgeEnabled"] as? Boolean ?: false
            val rawSchemes =
                (map["allowedExternalSchemes"] as? List<*>)
                    ?.filterIsInstance<String>()
                    ?: emptyList()
            val externalSchemes = rawSchemes.map { it.lowercase(Locale.ROOT) }.toSet()
            if (externalSchemes.any { !validExternalScheme(it) }) return null
            if (startUrl != BUNDLED_LOCAL) {
                val start = runCatching { URI(startUrl) }.getOrNull() ?: return null
                if (!origin.matches(start)) return null
            }
            return NativeConfiguration(origin, startUrl, bridgeEnabled, externalSchemes)
        }

        private fun validExternalScheme(value: String): Boolean =
            Regex("^[a-z][a-z0-9+.-]*$").matches(value) &&
                value !in
                    setOf(
                        "http",
                        "https",
                        "file",
                        "content",
                        "javascript",
                        "data",
                        "about",
                    )

        private const val BUNDLED_LOCAL = "BUNDLED_LOCAL"
    }
}

private class StarterkitWebViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        StarterkitWebViewPlatformView(context, messenger, viewId, NativeConfiguration.parse(args))
}

private class StarterkitWebViewPlatformView(
    private val context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    private val configuration: NativeConfiguration?,
) : PlatformView, MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "starterkit/webview/$viewId")
    private val webView = WebView(context)
    private val navigationPolicy =
        configuration?.let { NavigationPolicy(it.trustedOrigin, it.externalSchemes) }
    private var disposed = false
    private var bridgeInstalled = false
    private var bridgeScript: ScriptHandler? = null

    init {
        channel.setMethodCallHandler(this)
        configureWebView()
        installBridgeIfRequested()
    }

    override fun getView(): View = webView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed && call.method != "dispose") {
            result.error("DISPOSED", "WebView has been disposed", null)
            return
        }
        when (call.method) {
            "loadStart" -> {
                if (loadStart()) result.success(null)
                else result.error("INVALID_CONFIG", "WebView configuration is invalid", null)
            }
            "load" -> {
                val raw = call.argument<String>("url")
                if (raw != null && loadTrusted(raw)) result.success(null)
                else result.error("INVALID_URL", "URL is outside trustedOrigin", null)
            }
            "bridgeAvailable" -> result.success(isBridgeFeatureAvailable())
            "dispose" -> {
                disposeInternal()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun configureWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture = true
            setGeolocationEnabled(false)
        }
        android.webkit.CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false)
        webView.webChromeClient =
            object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) {
                    request.deny()
                }

                override fun onGeolocationPermissionsShowPrompt(
                    origin: String,
                    callback: GeolocationPermissions.Callback,
                ) {
                    callback.invoke(origin, false, false)
                }

                override fun onShowFileChooser(
                    webView: WebView,
                    filePathCallback: ValueCallback<Array<Uri>>,
                    fileChooserParams: FileChooserParams,
                ): Boolean {
                    filePathCallback.onReceiveValue(null)
                    return true
                }
            }
        webView.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ): Boolean =
                    handleNavigation(
                        request.url.toString(),
                        request.isForMainFrame,
                        request.hasGesture(),
                    )

                @Suppress("DEPRECATION")
                override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
                    handleNavigation(url, mainFrame = true, userGesture = false)

                override fun onReceivedSslError(
                    view: WebView,
                    handler: SslErrorHandler,
                    error: SslError,
                ) {
                    handler.cancel()
                }
            }
    }

    private fun handleNavigation(raw: String, mainFrame: Boolean, userGesture: Boolean): Boolean {
        val decision =
            navigationPolicy?.decide(raw, mainFrame, userGesture) ?: NavigationDecision.BLOCKED
        return when (decision) {
            NavigationDecision.INTERNAL,
            NavigationDecision.LOCAL_ASSET,
            -> false
            NavigationDecision.EXTERNAL_BROWSER,
            NavigationDecision.EXTERNAL_APP,
            -> {
                openExternal(raw)
                true
            }
            NavigationDecision.BLOCKED -> true
        }
    }

    private fun openExternal(raw: String) {
        val uri = runCatching { Uri.parse(raw) }.getOrNull() ?: return
        val intent = Intent(Intent.ACTION_VIEW, uri)
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    private fun loadStart(): Boolean {
        val config = configuration ?: return false
        if (config.startUrl == BUNDLED_LOCAL) {
            webView.loadDataWithBaseURL(
                NavigationPolicy.LOCAL_START_URL,
                LOCAL_HTML,
                "text/html",
                "UTF-8",
                null,
            )
            return true
        }
        return loadTrusted(config.startUrl)
    }

    private fun loadTrusted(raw: String): Boolean {
        val config = configuration ?: return false
        val uri = runCatching { URI(raw) }.getOrNull() ?: return false
        if (!config.trustedOrigin.matches(uri)) return false
        webView.loadUrl(raw)
        return true
    }

    private fun isBridgeFeatureAvailable(): Boolean =
        WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) &&
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)

    private fun installBridgeIfRequested() {
        val config = configuration ?: return
        if (!config.bridgeEnabled || !isBridgeFeatureAvailable()) return
        val rules = setOf(config.trustedOrigin.originRule())
        WebViewCompat.addWebMessageListener(
            webView,
            "StarterkitNative",
            rules,
        ) { _, message, sourceOrigin, isMainFrame, replyProxy ->
            val source =
                runCatching { URI(sourceOrigin.toString()) }
                    .getOrNull()
            if (!isMainFrame || source == null || !config.trustedOrigin.matches(source)) {
                replyProxy.postMessage(
                    BridgeProtocol.failure("", "INVALID_ORIGIN_OR_ENVELOPE"),
                )
                return@addWebMessageListener
            }
            val request = message.data?.let(BridgeProtocol::parse)
            if (request == null) {
                replyProxy.postMessage(BridgeProtocol.failure("", "INVALID_REQUEST"))
                return@addWebMessageListener
            }
            val response =
                if (request.method == "app.getVersion") {
                    BridgeProtocol.success(request.id, appVersion())
                } else {
                    BridgeProtocol.failure(request.id, "METHOD_NOT_ALLOWED")
                }
            if (response.toByteArray(Charsets.UTF_8).size <= BridgeProtocol.MAX_ENVELOPE_BYTES) {
                replyProxy.postMessage(response)
            } else {
                replyProxy.postMessage(
                    BridgeProtocol.failure(request.id, "RESPONSE_TOO_LARGE"),
                )
            }
        }
        bridgeScript =
            WebViewCompat.addDocumentStartJavaScript(
                webView,
                BridgeScript.source,
                rules,
            )
        bridgeInstalled = true
    }

    private fun appVersion(): String =
        runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
        }.getOrDefault("0")

    override fun dispose() = disposeInternal()

    private fun disposeInternal() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        if (bridgeInstalled) {
            runCatching { WebViewCompat.removeWebMessageListener(webView, "StarterkitNative") }
            bridgeInstalled = false
        }
        bridgeScript?.remove()
        bridgeScript = null
        webView.stopLoading()
        webView.webChromeClient = null
        webView.removeAllViews()
        webView.destroy()
    }

    companion object {
        private const val BUNDLED_LOCAL = "BUNDLED_LOCAL"
        private const val LOCAL_HTML =
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>Starter WebView</title></head>" +
                "<body><main><h1>Starter WebView</h1><p>Bundled local content.</p></main></body></html>"
    }
}
