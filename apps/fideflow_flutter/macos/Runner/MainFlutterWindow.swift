import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowDragEvent: NSEvent?
  private var focusInputMonitor: Any?
  private var playerControls: PlayerControls?
  private var playbackLifecycle: PlaybackLifecycle?
  private var activationObserver: NSObjectProtocol?
  private var deactivationObserver: NSObjectProtocol?

  private let widthKey = "fideflow_normal_window_width"
  private let heightKey = "fideflow_normal_window_height"
  private let zoomKey = "fideflow_window_is_zoomed"

  private var isWindowInitialized = false
  private var isPointerRefreshScheduled = false
  private var isActivationRequestPending = false
  private var desktopChannel: FlutterMethodChannel?
  private var desktopReady = false
  private var closePending = false
  private var closeInFlight = false
  private var terminationInFlight = false
  private var terminationPending = false
  // Injectable close handler for native tests; production uses the channel.
  var closeRequest: ((@escaping (String) -> Void) -> Void)?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Configure this before attaching/loading the view: Flutter's default
    // tracking area is active only in the key window. During launch the view,
    // restored window frame and app activation can become ready in any order.
    flutterViewController.mouseTrackingMode = .inActiveApp
    self.contentViewController = flutterViewController
    self.acceptsMouseMovedEvents = true
    self.delegate = self
    self.isReleasedWhenClosed = false
    self.tabbingMode = .disallowed
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) { titlebarSeparatorStyle = .none }
    isMovableByWindowBackground = false
    (NSApp.delegate as? AppDelegate)?.playbackWindow = self
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
    ) { [weak self] _ in
      // Activation and window ordering can finish in separate run-loop turns.
      DispatchQueue.main.async { [weak self] in self?.repairWindowFocus() }
    }
    deactivationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
    ) { [weak self] _ in self?.logFocusState("app-resigned-active") }

    // Disable system-level state restoration to avoid position/frame conflicts
    self.isRestorable = false

    // Clean up any legacy autosave frame from previous versions
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame fideflow_main_window")

    let minWidth: CGFloat = 440
    let minHeight: CGFloat = 560
    self.minSize = NSSize(width: minWidth, height: minHeight)

    let savedWidth = UserDefaults.standard.double(forKey: widthKey)
    let savedHeight = UserDefaults.standard.double(forKey: heightKey)

    var normalWidth = savedWidth > 0 ? CGFloat(savedWidth) : 1024
    var normalHeight = savedHeight > 0 ? CGFloat(savedHeight) : 720

    if let screen = self.screen ?? NSScreen.main {
      let maxVisibleWidth = screen.visibleFrame.width
      let maxVisibleHeight = screen.visibleFrame.height
      normalWidth = min(normalWidth, maxVisibleWidth)
      normalHeight = min(normalHeight, maxVisibleHeight)
    }

    normalWidth = max(normalWidth, minWidth)
    normalHeight = max(normalHeight, minHeight)

    self.setContentSize(NSSize(width: normalWidth, height: normalHeight))
    self.center()

    let wasZoomed = UserDefaults.standard.bool(forKey: zoomKey)
    if wasZoomed && !self.isZoomed {
      self.zoom(nil)
    }

    isWindowInitialized = true

    RegisterGeneratedPlugins(registry: flutterViewController)
    desktopChannel = FlutterMethodChannel(name: "fideflow/desktop",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    desktopChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "deviceName" {
        result(Host.current().localizedName ?? Host.current().name)
      } else if call.method == "initialize" {
        self.desktopReady = true
        result(nil)
        if self.terminationPending {
          self.terminationPending = false
          DispatchQueue.main.async { NSApp.terminate(nil) }
        } else if self.closePending { self.closePending = false; self.requestClose() }
      } else if call.method == "expandForSidebar" {
        if self.isZoomed || self.styleMask.contains(.fullScreen) { result(true); return }
        guard let screen = self.screen else { result(false); return }
        guard let target = Self.expandedSidebarFrame(self.frame, in: screen.visibleFrame) else {
          result(false); return
        }
        self.setFrame(target, display: true)
        result(true)
      } else if call.method == "startDragging" {
        guard NSEvent.pressedMouseButtons & 1 != 0, let event = self.windowDragEvent else {
          result(false); return
        }
        self.performDrag(with: event)
        result(true)
      } else if call.method == "toggleMaximize" {
        result(self.performNativeZoom())
      } else if call.method == "titlebarDoubleClick" {
        self.zoom(nil); result(true)
      } else if call.method == "minimize" {
        self.miniaturize(nil); result(true)
      } else if call.method == "closeWindow" {
        self.performClose(nil); result(true)
      } else { result(FlutterMethodNotImplemented) }
    }

    // The user's own file selection is the only content source a sandboxed build
    // can read, so the panel bridge is part of the launch surface.
    playbackLifecycle = PlaybackLifecycle(messenger: flutterViewController.engine.binaryMessenger)
    playerControls = PlayerControls(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
    showNativeWindowButtons()
    installFocusDiagnostics()
    logFocusState("window-ready")
    scheduleMouseTrackingRefresh()
  }

  private func scheduleMouseTrackingRefresh() {
    guard !isPointerRefreshScheduled else { return }
    isPointerRefreshScheduled = true
    // Coalesce launch and activation callbacks; geometry changes are already
    // handled by Flutter's NSTrackingInVisibleRect area.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.isPointerRefreshScheduled = false
      guard self.isKeyWindow, !self.inLiveResize else { return }
      self.refreshMouseTracking()
    }
  }

  func refreshMouseTracking() {
    guard let controller = contentViewController as? FlutterViewController,
          controller.isViewLoaded, controller.view.window === self else { return }
    acceptsMouseMovedEvents = true
    // Setting the same mode is a no-op in Flutter. Disable first so the old
    // NSTrackingArea is removed rather than accumulating duplicate areas.
    controller.mouseTrackingMode = .none
    controller.mouseTrackingMode = .inActiveApp
  }

  override func sendEvent(_ event: NSEvent) {
    // Retain the initiating mouse-down; the Flutter drag gesture reaches the
    // method channel on a later mouse-drag event, after native dispatch returns.
    if event.type == .leftMouseDown { windowDragEvent = event }
    if event.type == .leftMouseUp { windowDragEvent = nil }
    // Keep native hit testing, window dragging and live resize in AppKit.
    super.sendEvent(event)
    // Titlebar dragging can run a nested event loop inside super.sendEvent.
    // Check the resulting activation state after that loop has returned.
    activateForWindowInteraction(event)
  }

  func activateForWindowInteraction(_ event: NSEvent) {
    // Activation can fail independently of Flutter hover tracking. A real
    // click (including release after a titlebar drag) is a new user request;
    // ordinary pointer movement must never bring a background app forward.
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp: break
    default: return
    }
    guard event.windowNumber == windowNumber,
          !NSApp.isActive || !isKeyWindow else { return }
    requestWindowActivation()
  }

  // MARK: - Window State Saving

  private func saveWindowState() {
    guard isWindowInitialized else { return }
    UserDefaults.standard.set(self.isZoomed, forKey: zoomKey)
    if !self.isZoomed {
      let contentSize = self.contentRect(forFrameRect: self.frame).size
      UserDefaults.standard.set(Double(contentSize.width), forKey: widthKey)
      UserDefaults.standard.set(Double(contentSize.height), forKey: heightKey)
    }
  }

  // MARK: - NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    requestClose()
    return false
  }

  private func requestClose() {
    guard desktopReady || closeRequest != nil else { closePending = true; return }
    guard !closeInFlight, !terminationInFlight else { return }
    closeInFlight = true
    let complete: (String) -> Void = { [weak self] action in
      guard let self = self else { return }
      self.closeInFlight = false
      guard !self.terminationInFlight else { return }
      if action == "background" { self.hideForPlayback() }
      else if action == "quit" { NSApp.terminate(nil) }
    }
    if let request = closeRequest { request(complete) }
    else {
      desktopChannel?.invokeMethod("closeRequested", arguments: ["canBackground": true]) {
        complete($0 as? String ?? "cancel")
      }
    }
  }

  func hideForPlayback() {
    saveWindowState()
    orderOut(nil)
  }

  func requestTermination() -> NSApplication.TerminateReply {
    guard desktopReady, let channel = desktopChannel else {
      terminationPending = true
      return .terminateCancel
    }
    if terminationInFlight { return .terminateLater }
    terminationInFlight = true
    channel.invokeMethod("quit", arguments: nil) { [weak self] result in
      let accepted = result as? Bool == true
      if !accepted { self?.terminationInFlight = false; self?.restoreFromDock() }
      NSApp.reply(toApplicationShouldTerminate: accepted)
    }
    return .terminateLater
  }

  func restoreFromDock() {
    if isMiniaturized { deminiaturize(nil) }
    orderFront(nil)
    requestWindowActivation()
  }

  func requestWindowActivation() {
    guard isVisible, !isMiniaturized, attachedSheet == nil,
          NSApp.modalWindow == nil else { logFocusState("activation-skipped-hidden-or-modal"); return }
    guard !NSApp.isActive || !isKeyWindow else { logFocusState("activation-skipped-already-key"); return }
    guard !isActivationRequestPending else { logFocusState("activation-coalesced"); return }
    isActivationRequestPending = true
    // Coalesce startup/reopen/click callbacks in one turn. Clear even if the
    // OS declines activation so a later explicit click can try again.
    DispatchQueue.main.async { [weak self] in self?.isActivationRequestPending = false }
    logFocusState("activation-request")
    requestNativeApplicationActivation()
    logFocusState("activation-request-returned")
    // A successful API call is not proof of activation. If activation is
    // asynchronous, the didBecomeActive observer completes this operation.
    repairWindowFocus()
  }

  func requestNativeApplicationActivation() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func repairWindowFocus() {
    // Do not reopen a hidden player or steal focus from a picker/dialog.
    guard NSApp.isActive, isVisible, !isMiniaturized,
          attachedSheet == nil, NSApp.modalWindow == nil else { return }
    if !isKeyWindow && (NSApp.keyWindow == nil || NSApp.keyWindow === self) {
      makeKeyAndOrderFront(nil)
    }
    if NSApp.mainWindow == nil { makeMain() }
    logFocusState("activation-confirmed")
    scheduleMouseTrackingRefresh()
  }

  private func installFocusDiagnostics() {
    guard FocusDiagnostics.enabled, focusInputMonitor == nil else { return }
    // Observe before NSApplication dispatch: an inactive-window activating
    // click may be consumed before MainFlutterWindow.sendEvent receives it.
    // This monitor never activates anything and always returns the same event.
    focusInputMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    ) { [weak self] event in
      guard let self = self, event.windowNumber == self.windowNumber,
            !NSApp.isActive || !self.isKeyWindow else { return event }
      self.logFocusState("input-\(event.type.rawValue)-before-dispatch")
      DispatchQueue.main.async { [weak self] in
        self?.logFocusState("input-\(event.type.rawValue)-next-turn")
      }
      return event
    }
  }

  func logFocusState(_ event: String) {
    guard FocusDiagnostics.enabled else { return }
    let running = NSRunningApplication.current
    let frontmost = NSWorkspace.shared.frontmostApplication
    FocusDiagnostics.record("event=\(event) pid=\(running.processIdentifier) " +
      "active=\(NSApp.isActive) runningActive=\(running.isActive) " +
      "frontmostPID=\(frontmost?.processIdentifier ?? -1) " +
      "frontmostBundle=\(frontmost?.bundleIdentifier ?? "none") " +
      "window=\(windowNumber) key=\(isKeyWindow) main=\(isMainWindow) " +
      "appKey=\(NSApp.keyWindow?.windowNumber ?? -1) appMain=\(NSApp.mainWindow?.windowNumber ?? -1) " +
      "visible=\(isVisible) miniaturized=\(isMiniaturized) " +
      "canKey=\(canBecomeKey) ignoresMouse=\(ignoresMouseEvents) " +
      "sheet=\(attachedSheet != nil) modal=\(NSApp.modalWindow != nil) " +
      "policy=\(NSApp.activationPolicy().rawValue) style=\(styleMask.rawValue)")
  }

  deinit {
    if let monitor = focusInputMonitor { NSEvent.removeMonitor(monitor) }
    if let observer = activationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = deactivationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    logFocusState("window-became-key")
    scheduleMouseTrackingRefresh()
  }

  func windowDidResignKey(_ notification: Notification) {
    logFocusState("window-resigned-key")
  }

  static func expandedSidebarFrame(_ frame: NSRect, in work: NSRect) -> NSRect? {
    var target = frame
    target.size.width = max(frame.width, 840)
    guard target.width <= work.width else { return nil }
    target.origin.x = max(work.minX, min(target.minX, work.maxX - target.width))
    return target
  }

  func showNativeWindowButtons() {
    // Keep AppKit's native traffic lights so the zoom button can present the
    // system window tiling and full-screen actions on hover.
    standardWindowButton(.closeButton)?.superview?.superview?.isHidden = false
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(kind)?.isHidden = false
    }
  }

  func performNativeZoom() -> Bool {
    guard let button = standardWindowButton(.zoomButton), button.isEnabled else { return false }
    // Preserve AppKit's green-button action rather than substituting zoom().
    button.performClick(nil)
    return true
  }

  func windowDidEnterFullScreen(_ notification: Notification) { showNativeWindowButtons() }
  func windowDidExitFullScreen(_ notification: Notification) { showNativeWindowButtons() }

  func windowDidResize(_ notification: Notification) {
    showNativeWindowButtons()
    if !self.inLiveResize {
      saveWindowState()
    }
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    saveWindowState()
  }

  func windowWillClose(_ notification: Notification) {
    playbackLifecycle?.dispose()
    playerControls?.dispose()
    saveWindowState()
  }
}

enum FocusDiagnostics {
  static let enabled: Bool = {
    let value = ProcessInfo.processInfo.environment["FIDEFLOW_FOCUS_DIAGNOSTICS"]
    if let value = value { return value == "1" }
    #if DEBUG
    return true
    #else
    return false
    #endif
  }()

  private static let writer: FocusLogWriter? = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fideflow-focus-\(ProcessInfo.processInfo.processIdentifier).log")
    let writer = FocusLogWriter(url: url)
    NSLog("[Fideflow focus] diagnostic file: %@", url.path)
    return writer
  }()

  static func record(_ message: String) {
    guard enabled else { return }
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    writer?.append(line)
    NSLog("[Fideflow focus] %@", message)
  }
}

// Main-thread, bounded local diagnostics. No timers or network transmission.
final class FocusLogWriter {
  private let handle: FileHandle
  private let maximumBytes: Int
  private var bytesWritten = 0

  init?(url: URL, maximumBytes: Int = 64 * 1024) {
    guard maximumBytes > 0,
          FileManager.default.createFile(atPath: url.path, contents: Data(),
            attributes: [.posixPermissions: 0o600]),
          let handle = try? FileHandle(forWritingTo: url) else { return nil }
    self.handle = handle
    self.maximumBytes = maximumBytes
  }

  func append(_ line: String) {
    let data = Data(line.utf8)
    guard data.count <= maximumBytes else { return }
    do {
      if bytesWritten + data.count > maximumBytes {
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        bytesWritten = 0
      }
      try handle.write(contentsOf: data)
      bytesWritten += data.count
    } catch {
      // A diagnostics failure must not affect input or playback.
    }
  }

  deinit { try? handle.close() }
}
