import Cocoa
import FlutterMacOS

/// Owns sleep/wake notifications even when system media controls are disabled.
final class PlaybackLifecycle {
  private let channel: FlutterMethodChannel
  private let center: NotificationCenter
  private var observers: [NSObjectProtocol] = []
  private var ready = false
  private var closed = false
  private(set) var interruptionId: String?
  var observerCount: Int { observers.count }
  var onEvent: (([String: Any]) -> Void)?

  init(messenger: FlutterBinaryMessenger,
       center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
    self.center = center
    channel = FlutterMethodChannel(name: "fideflow/playback_lifecycle", binaryMessenger: messenger)
    observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
      object: nil, queue: .main) { [weak self] _ in self?.begin() })
    observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
      object: nil, queue: .main) { [weak self] _ in self?.end() })
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, !self.closed else { result(nil); return }
      switch call.method {
      case "initialize":
        self.ready = true
        if let id = self.interruptionId {
          self.emit(["interruptionId": id, "active": true])
        }
        result(nil)
      case "dispose": self.dispose(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func begin() {
    guard !closed, interruptionId == nil else { return }
    let id = UUID().uuidString
    interruptionId = id
    emit(["interruptionId": id, "active": true])
  }

  private func end() {
    guard !closed, let id = interruptionId else { return }
    interruptionId = nil
    emit(["interruptionId": id, "active": false])
  }

  private func emit(_ event: [String: Any]) {
    onEvent?(event)
    if ready { channel.invokeMethod("interruption", arguments: event) }
  }

  func dispose() {
    guard !closed else { return }
    closed = true
    ready = false
    observers.forEach { center.removeObserver($0) }
    observers.removeAll()
    onEvent = nil
    channel.setMethodCallHandler(nil)
  }
  deinit { dispose() }
}
