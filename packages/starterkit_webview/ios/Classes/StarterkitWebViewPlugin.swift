import Flutter
import UIKit
import WebKit

public final class StarterkitWebViewPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(
      StarterkitWebViewFactory(messenger: registrar.messenger()),
      withId: "starterkit/webview"
    )
  }
}

private final class StarterkitWebViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    StarterkitWebViewPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args,
      messenger: messenger
    )
  }
}

private struct NativeConfiguration {
  let trustedOrigin: TrustedOrigin
  let startURL: String
  let bridgeEnabled: Bool
  let externalSchemes: Set<String>

  static func parse(_ arguments: Any?) -> NativeConfiguration? {
    guard let map = arguments as? [String: Any],
      let originRaw = map["trustedOrigin"] as? String,
      let origin = TrustedOrigin(configured: originRaw),
      let startURL = map["startUrl"] as? String
    else { return nil }

    if startURL != "BUNDLED_LOCAL" {
      guard let url = URL(string: startURL), origin.matches(url) else { return nil }
    }

    let rawSchemes = map["allowedExternalSchemes"] as? [String] ?? []
    let reserved = Set(["http", "https", "file", "content", "javascript", "data", "about"])
    let normalized = rawSchemes.map { $0.lowercased() }
    guard normalized.allSatisfy({
      $0.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression) != nil &&
        !reserved.contains($0)
    }) else { return nil }

    return NativeConfiguration(
      trustedOrigin: origin,
      startURL: startURL,
      bridgeEnabled: map["bridgeEnabled"] as? Bool ?? false,
      externalSchemes: Set(normalized)
    )
  }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

private final class StarterkitWebViewPlatformView: NSObject, FlutterPlatformView,
  WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler
{
  private let webView: WKWebView
  private let channel: FlutterMethodChannel
  private let configuration: NativeConfiguration?
  private let navigationPolicy: NavigationPolicy?
  private var scriptHandler: WeakScriptMessageHandler?
  private var disposed = false

  init(
    frame: CGRect,
    viewId: Int64,
    arguments: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    let configuration = NativeConfiguration.parse(arguments)
    self.configuration = configuration
    self.navigationPolicy = configuration.map {
      NavigationPolicy(trustedOrigin: $0.trustedOrigin, externalSchemes: $0.externalSchemes)
    }

    let userContentController = WKUserContentController()
    let webConfiguration = WKWebViewConfiguration()
    webConfiguration.userContentController = userContentController
    webConfiguration.preferences.javaScriptEnabled = true
    webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
    webConfiguration.mediaTypesRequiringUserActionForPlayback = .all
    webConfiguration.allowsInlineMediaPlayback = false

    self.webView = WKWebView(frame: frame, configuration: webConfiguration)
    self.channel = FlutterMethodChannel(
      name: "starterkit/webview/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    installBridgeIfRequested()
  }

  func view() -> UIView { webView }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if disposed && call.method != "dispose" {
      result(FlutterError(code: "DISPOSED", message: "WebView has been disposed", details: nil))
      return
    }
    switch call.method {
    case "loadStart":
      if loadStart() {
        result(nil)
      } else {
        result(FlutterError(code: "INVALID_CONFIG", message: "Invalid WebView config", details: nil))
      }
    case "load":
      let map = call.arguments as? [String: Any]
      if let raw = map?["url"] as? String, loadTrusted(raw) {
        result(nil)
      } else {
        result(
          FlutterError(
            code: "INVALID_URL",
            message: "URL is outside trustedOrigin",
            details: nil
          )
        )
      }
    case "bridgeAvailable":
      result(true)
    case "dispose":
      disposeInternal()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func loadStart() -> Bool {
    guard let configuration else { return false }
    if configuration.startURL == "BUNDLED_LOCAL" {
      guard let baseURL = URL(string: NavigationPolicy.localStartURL) else { return false }
      webView.loadHTMLString(Self.localHTML, baseURL: baseURL)
      return true
    }
    return loadTrusted(configuration.startURL)
  }

  private func loadTrusted(_ raw: String) -> Bool {
    guard let configuration, let url = URL(string: raw), configuration.trustedOrigin.matches(url)
    else { return false }
    webView.load(URLRequest(url: url))
    return true
  }

  private func installBridgeIfRequested() {
    guard let configuration, configuration.bridgeEnabled else { return }
    let script = WKUserScript(
      source: Self.bridgeScript,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
    webView.configuration.userContentController.addUserScript(script)
    let handler = WeakScriptMessageHandler(target: self)
    scriptHandler = handler
    webView.configuration.userContentController.add(handler, name: "StarterkitNative")
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard !disposed, let url = navigationAction.request.url, let navigationPolicy else {
      decisionHandler(.cancel)
      return
    }
    let decision = navigationPolicy.decide(
      url,
      isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
      linkActivated: navigationAction.navigationType == .linkActivated
    )
    switch decision {
    case .trustedInternal, .localAsset:
      decisionHandler(.allow)
    case .externalBrowser, .externalApp:
      guard webView.window?.windowScene?.activationState == .foregroundActive else {
        decisionHandler(.cancel)
        return
      }
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      decisionHandler(.cancel)
    case .blocked:
      decisionHandler(.cancel)
    }
  }

  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.performDefaultHandling, nil)
  }

  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard !disposed,
      configuration?.bridgeEnabled == true,
      message.name == "StarterkitNative",
      message.frameInfo.isMainFrame,
      let configuration,
      let url = message.frameInfo.request.url,
      configuration.trustedOrigin.matches(url),
      configuration.trustedOrigin.matches(
        protocol: message.frameInfo.securityOrigin.protocol,
        host: message.frameInfo.securityOrigin.host,
        port: message.frameInfo.securityOrigin.port
      ),
      let body = message.body as? [String: Any],
      let request = BridgeRequestValidator.validate(body)
    else {
      sendBridge([
        "id": "",
        "success": false,
        "error": ["code": "INVALID_ORIGIN_OR_ENVELOPE"],
      ])
      return
    }

    if request.method == "app.getVersion" {
      let version =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
      sendBridge([
        "id": request.id,
        "success": true,
        "result": ["version": String(version.prefix(1024))],
      ])
    } else {
      sendBridge([
        "id": request.id,
        "success": false,
        "error": ["code": "METHOD_NOT_ALLOWED"],
      ])
    }
  }

  private func sendBridge(_ response: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(response),
      let data = try? JSONSerialization.data(withJSONObject: response),
      data.count <= BridgeRequestValidator.maxEnvelopeBytes,
      let json = String(data: data, encoding: .utf8)
    else { return }
    webView.evaluateJavaScript(
      "window.__starterkitBridgeResolve(\(json));",
      completionHandler: nil
    )
  }

  private func disposeInternal() {
    guard !disposed else { return }
    disposed = true
    channel.setMethodCallHandler(nil)
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "StarterkitNative"
    )
    webView.configuration.userContentController.removeAllUserScripts()
    scriptHandler = nil
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  deinit {
    disposeInternal()
  }

  private static let localHTML =
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>Starter WebView</title></head>" +
    "<body><main><h1>Starter WebView</h1><p>Bundled local content.</p></main></body></html>"

  private static let bridgeScript = #"""
    window.NativeBridge = (() => {
      const pending = new Map(), timeoutMs = 30000;
      function fail(code) { return {code: code || 'NATIVE_ERROR'}; }
      window.__starterkitBridgeResolve = function(response) {
        const item = pending.get(response && response.id);
        if (!item) return;
        pending.delete(response.id);
        clearTimeout(item.timer);
        response.success ? item.resolve(response.result) : item.reject(fail(response.error && response.error.code));
      };
      function request(message) {
        if (!message || typeof message !== 'object' || message.version !== 1 ||
            typeof message.id !== 'string' || message.id.length < 1 || message.id.length > 128 ||
            typeof message.method !== 'string' || message.method.length < 1 || message.method.length > 128 ||
            !message.params || typeof message.params !== 'object' || Array.isArray(message.params) ||
            pending.has(message.id) ||
            new TextEncoder().encode(JSON.stringify(message)).length > 16384) {
          return Promise.reject(fail('INVALID_REQUEST'));
        }
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            pending.delete(message.id);
            reject(fail('TIMEOUT'));
          }, timeoutMs);
          pending.set(message.id, {resolve, reject, timer});
          window.webkit.messageHandlers.StarterkitNative.postMessage(message);
        });
      }
      return {request};
    })();
    """#
}
