import Flutter
import Network

public final class ConnectivityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventChannel: FlutterEventChannel?
  private var monitor: NWPathMonitor?
  private let monitorQueue = DispatchQueue(label: "dev.lunardev.starterkit.connectivity.monitor")
  private var generation: UInt64 = 0
  private var isAttached = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ConnectivityPlugin()
    instance.isAttached = true
    registrar.publish(instance)
    let channel = FlutterEventChannel(
      name: "starterkit/connectivity/events",
      binaryMessenger: registrar.messenger()
    )
    instance.eventChannel = channel
    channel.setStreamHandler(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    isAttached = false
    eventChannel?.setStreamHandler(nil)
    eventChannel = nil
    stopMonitoring()
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stopMonitoring()
    generation &+= 1
    let token = generation
    let pathMonitor = NWPathMonitor()
    monitor = pathMonitor
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let status = path.status == .satisfied ? "onlineLike" : "offline"
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isAttached, self.generation == token else { return }
        events(status)
      }
    }
    pathMonitor.start(queue: monitorQueue)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopMonitoring()
    return nil
  }

  private func stopMonitoring() {
    generation &+= 1
    let oldMonitor = monitor
    monitor = nil
    oldMonitor?.pathUpdateHandler = nil
    oldMonitor?.cancel()
  }

  deinit {
    isAttached = false
    stopMonitoring()
  }
}
