import Flutter
import Foundation

public final class StarterkitPreferencesPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private let handler = PreferencesHandler(schedule: { operation in
    DispatchQueue.main.async(execute: operation)
  })

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StarterkitPreferencesPlugin()
    registrar.publish(instance)
    let channel = FlutterMethodChannel(name: "starterkit/preferences", binaryMessenger: registrar.messenger())
    instance.channel = channel
    channel.setMethodCallHandler { [weak instance] call, result in
      guard let instance else {
        result(FlutterError(code: "preference.unavailable", message: nil, details: nil))
        return
      }
      instance.handle(call, result: result)
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    handler.detach()
    channel?.setMethodCallHandler(nil)
    channel = nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    handler.handle(method: call.method, arguments: call.arguments) { outcome in
      switch outcome {
      case .success(let value): result(value)
      case .failure(let failure): result(FlutterError(code: failure.code, message: nil, details: nil))
      }
    }
  }
}
