import Carbon
import Cocoa
import FlutterMacOS
import MediaPlayer

/// Owns only OS registrations and a projection of the session. Commands always
/// return to the existing Dart application controller, never a second player.
final class PlayerControls {
  static let channelName = "fideflow/player_controls"
  static let keyCodes: [Int: UInt32] = [
    4: 0, 5: 11, 6: 8, 7: 2, 8: 14, 9: 3, 10: 5, 11: 4, 12: 34, 13: 38, 14: 40, 15: 37,
    16: 46, 17: 45, 18: 31, 19: 35, 20: 12, 21: 15, 22: 1, 23: 17, 24: 32, 25: 9, 26: 13, 27: 7,
    28: 16, 29: 6,
    30: 18, 31: 19, 32: 20, 33: 21, 34: 23, 35: 22, 36: 26, 37: 28, 38: 25, 39: 29,
    40: 36, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24, 47: 33, 48: 30, 49: 42, 51: 41, 52: 39, 53: 50,
    54: 43, 55: 47, 56: 44,
    58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103,
    69: 111,
    74: 115, 75: 116, 76: 117, 77: 119, 78: 121, 79: 124, 80: 123, 81: 125, 82: 126,
  ]
  struct Binding: Equatable {
    let key: UInt32
    let modifiers: UInt32
    init?(_ raw: [String: Any]) {
      guard let usage = raw["key"] as? Int, let key = PlayerControls.keyCodes[usage] else {
        return nil
      }
      self.key = key
      var flags: UInt32 = 0
      if raw["meta"] as? Bool == true { flags |= UInt32(cmdKey) }
      if raw["control"] as? Bool == true { flags |= UInt32(controlKey) }
      if raw["alt"] as? Bool == true { flags |= UInt32(optionKey) }
      if raw["shift"] as? Bool == true { flags |= UInt32(shiftKey) }
      guard flags & UInt32(cmdKey | controlKey) != 0 else { return nil }
      modifiers = flags
    }
  }
  struct Registration {
    let binding: Binding
    let reference: EventHotKeyRef
    let id: UInt32
  }
  private let channel: FlutterMethodChannel
  private var registrations: [String: Registration] = [:]
  private var handler: EventHandlerRef?
  private var handlerStatus: OSStatus = noErr
  private var nextID: UInt32 = 0
  private var desired: [String: Binding] = [:]
  private var suspended = false
  private var mediaEnabled = false
  private var targets: [(MPRemoteCommand, Any)] = []
  private var repeatTimer: Timer?
  private var heldID: UInt32?
  private(set) var projection: [String: Any] = [:]
  private var closed = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    var events = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event = event, let userData = userData else {
          return OSStatus(eventNotHandledErr)
        }
        let owner = Unmanaged<PlayerControls>.fromOpaque(userData).takeUnretainedValue()
        var hotKey = EventHotKeyID()
        let result = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        guard result == noErr else { return result }
        guard hotKey.signature == 0x5841_5552 else { return OSStatus(eventNotHandledErr) }
        owner.hotKey(hotKey.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
        return noErr
      }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, !self.closed else {
        result(false)
        return
      }
      switch call.method {
      case "configure":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "controls.invalid", message: nil, details: nil))
          return
        }
        result(self.configure(args))
      case "suspend":
        let value = call.arguments as? Bool == true
        let errors = self.setSuspended(value)
        if errors.isEmpty {
          result(nil)
        } else {
          result(FlutterError(code: "controls.registration", message: nil, details: errors))
        }
      case "publish":
        if let args = call.arguments as? [String: Any] { self.publish(args) }
        result(nil)
      case "localize":
        if let labels = call.arguments as? [String: String], let menu = NSApp.mainMenu {
          self.localizeMenu(menu, labels: labels)
        }
        result(nil)
      case "artwork":
        if let args = call.arguments as? [String: Any], let token = args["token"] as? String,
          let bytes = args["bytes"] as? FlutterStandardTypedData
        {
          self.setArtwork(token: token, data: bytes.data)
        }
        result(nil)
      case "dispose":
        self.dispose()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  var registrationCount: Int { registrations.count }
  // Only app-owned tagged items are updated. Cocoa's dynamic window and service
  // entries retain their original titles and all action selectors stay intact.
  private func localizeMenu(_ menu: NSMenu, labels: [String: String]) {
    for item in menu.items {
      if let title = labels["menu\(item.tag)"] {
        item.title = title
        item.submenu?.title = title
      }
      if let submenu = item.submenu { localizeMenu(submenu, labels: labels) }
    }
  }
  var remoteTargetCount: Int { targets.count }
  func configure(_ args: [String: Any]) -> [String: String] {
    let enabled = args["globalEnabled"] as? Bool == true
    let bindings = args["global"] as? [String: Any] ?? [:]
    var proposed: [String: Binding] = [:]
    for (action, raw) in bindings where enabled {
      guard ["toggle", "previous", "next", "volumeUp", "volumeDown", "favorite"].contains(action)
      else {
        return [action: "controls.unsupportedAction"]
      }
      if raw is NSNull { continue }
      guard let raw = raw as? [String: Any], let binding = Binding(raw) else {
        return [action: "controls.unsupportedBinding"]
      }
      if proposed.values.contains(binding) { return [action: "controls.duplicate"] }
      proposed[action] = binding
    }
    if !proposed.isEmpty && handlerStatus != noErr {
      return ["globalEnabled": "controls.registration"]
    }
    let failures = replace(proposed)
    if suspended { _ = replace([:]) }
    if failures.isEmpty {
      desired = proposed
      setMediaEnabled(args["mediaEnabled"] as? Bool == true)
    }
    return failures
  }

  func setSuspended(_ value: Bool) -> [String: String] {
    let failures = replace(value ? [:] : desired)
    if failures.isEmpty { suspended = value }
    return failures
  }

  /// Register new combinations first; on failure release only those additions.
  /// Reused registrations allow swaps without losing previously working keys.
  private func replace(_ bindings: [String: Binding]) -> [String: String] {
    stopRepeat()
    var next: [String: Registration] = [:]
    var added: [Registration] = []
    var failures: [String: String] = [:]
    for (action, binding) in bindings {
      if let reused = registrations.values.first(where: { $0.binding == binding }) {
        next[action] = reused
        continue
      }
      nextID += 1
      var reference: EventHotKeyRef?
      let id = EventHotKeyID(signature: 0x5841_5552, id: nextID)
      let status = RegisterEventHotKey(
        binding.key, binding.modifiers, id, GetApplicationEventTarget(),
        OptionBits(kEventHotKeyExclusive), &reference)
      if status == noErr, let reference = reference {
        let registration = Registration(binding: binding, reference: reference, id: nextID)
        next[action] = registration
        added.append(registration)
      } else {
        failures[action] = "controls.occupied"
      }
    }
    if !failures.isEmpty {
      for item in added { UnregisterEventHotKey(item.reference) }
      return failures
    }
    for item in registrations.values where !next.values.contains(where: { $0.id == item.id }) {
      UnregisterEventHotKey(item.reference)
    }
    registrations = next
    return [:]
  }
  private func hotKey(_ id: UInt32, pressed: Bool) {
    if !pressed {
      if heldID == id { stopRepeat() }
      return
    }
    guard !suspended, let action = registrations.first(where: { $0.value.id == id })?.key else {
      return
    }
    if heldID == id { return }
    stopRepeat()
    heldID = id
    send(action)
    if action == "volumeUp" || action == "volumeDown" {
      repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
        guard let self = self, self.heldID == id else { return }
        self.send(action)
        self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) {
          [weak self] _ in self?.send(action)
        }
      }
    }
  }
  private func stopRepeat() {
    repeatTimer?.invalidate()
    repeatTimer = nil
    heldID = nil
  }
  private func send(_ action: String, position: Double? = nil) {
    guard !closed, !suspended else { return }
    var args: [String: Any] = ["action": action]
    if let position = position { args["position"] = position }
    channel.invokeMethod("action", arguments: args)
  }
  private func setMediaEnabled(_ enabled: Bool) {
    guard enabled != mediaEnabled else { return }
    mediaEnabled = enabled
    let center = MPRemoteCommandCenter.shared()
    if enabled {
      let commands: [(MPRemoteCommand, String)] = [
        (center.playCommand, "play"), (center.pauseCommand, "pause"),
        (center.togglePlayPauseCommand, "toggle"),
        (center.previousTrackCommand, "previous"), (center.nextTrackCommand, "next"),
        (center.stopCommand, "stop"),
        (center.changePlaybackPositionCommand, "seek"),
      ]
      for (command, action) in commands {
        let target = command.addTarget { [weak self] event in
          guard let self = self else { return .commandFailed }
          let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
          if Thread.isMainThread { return self.remoteAction(action, position: position) }
          return DispatchQueue.main.sync { self.remoteAction(action, position: position) }
        }
        targets.append((command, target))
      }
      publish(projection)
    } else {
      for (command, target) in targets {
        command.removeTarget(target)
        command.isEnabled = false
      }
      targets.removeAll()
      clearNowPlaying()
      projection = [:]
    }
  }
  func remoteAction(_ action: String, position: Double? = nil) -> MPRemoteCommandHandlerStatus {
    guard mediaEnabled, !closed, !suspended, projection["hasTrack"] as? Bool == true else {
      return .noSuchContent
    }
    guard ["play", "pause", "toggle", "previous", "next", "stop", "seek"].contains(action) else {
      return .commandFailed
    }
    if action == "seek" {
      guard projection["canSeek"] as? Bool == true, let position = position,
        position.isFinite, position >= 0
      else { return .commandFailed }
    }
    // Acknowledge dispatch; only a session snapshot changes the OS state.
    send(action, position: position)
    return .success
  }

  func publish(_ state: [String: Any]) {
    let oldToken = projection["token"] as? String
    projection = state
    guard mediaEnabled else { return }
    let hasTrack = state["hasTrack"] as? Bool == true
    for (command, _) in targets {
      command.isEnabled =
        hasTrack
        && (command !== MPRemoteCommandCenter.shared().changePlaybackPositionCommand
          || state["canSeek"] as? Bool == true)
    }
    guard hasTrack else {
      clearNowPlaying()
      return
    }
    let center = MPNowPlayingInfoCenter.default()
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: state["title"] as? String ?? "",
      MPMediaItemPropertyArtist: state["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: state["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: state["duration"] as? Double ?? 0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: state["position"] as? Double ?? 0,
      MPNowPlayingInfoPropertyPlaybackRate: state["playing"] as? Bool == true ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if oldToken == state["token"] as? String,
      let cover = center.nowPlayingInfo?[MPMediaItemPropertyArtwork]
    {
      info[MPMediaItemPropertyArtwork] = cover
    }
    center.nowPlayingInfo = info
    center.playbackState =
      state["playing"] as? Bool == true
      ? .playing : (state["status"] as? String == "idle" ? .stopped : .paused)
  }
  func setArtwork(token: String, data: Data) {
    guard mediaEnabled, projection["hasTrack"] as? Bool == true,
      projection["token"] as? String == token, let image = NSImage(data: data)
    else { return }
    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    center.nowPlayingInfo = info
  }
  private func clearNowPlaying() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .unknown
  }
  func dispose() {
    guard !closed else { return }
    closed = true
    _ = replace([:])
    desired = [:]
    if let handler = handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
    setMediaEnabled(false)
    channel.setMethodCallHandler(nil)
  }
  deinit { dispose() }
}
