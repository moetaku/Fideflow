import Cocoa
import FlutterMacOS
import XCTest
import MediaPlayer
@testable import fideflow

class RunnerTests: XCTestCase {

  func testNativeWindowButtonsRemainVisibleForAppKitInteractions() throws {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.layoutIfNeeded()
    window.showNativeWindowButtons()
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      let button = try XCTUnwrap(window.standardWindowButton(kind))
      XCTAssertFalse(button.isHidden)
      XCTAssertNotNil(button.action)
    }
  }

  func testCustomMaximizeInvokesTheNativeGreenButtonAction() throws {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let button = try XCTUnwrap(window.standardWindowButton(.zoomButton))
    let probe = WindowButtonActionProbe()
    button.target = probe
    button.action = #selector(WindowButtonActionProbe.clicked(_:))
    window.showNativeWindowButtons()
    XCTAssertTrue(window.performNativeZoom())
    XCTAssertEqual(probe.clicks, 1)
    button.isEnabled = false
    XCTAssertFalse(window.performNativeZoom())
    XCTAssertEqual(probe.clicks, 1)
  }

  func testSidebarExpansionTargets840AndClampsToWorkArea() throws {
    let work = NSRect(x: -1200, y: 30, width: 1200, height: 800)
    let frame = NSRect(x: -650, y: 80, width: 600, height: 700)
    let target = try XCTUnwrap(MainFlutterWindow.expandedSidebarFrame(frame, in: work))
    XCTAssertEqual(target.width, 840)
    XCTAssertEqual(target.maxX, work.maxX)
    XCTAssertEqual(target.origin.y, frame.origin.y)
    XCTAssertEqual(target.height, frame.height)
    for width in [440.0, 599.0, 839.0, 840.0, 1000.0] {
      let initial = NSRect(x: -1200, y: 80, width: width, height: 700)
      let expanded = try XCTUnwrap(MainFlutterWindow.expandedSidebarFrame(initial, in: work))
      XCTAssertEqual(expanded.width, max(width, 840))
      XCTAssertEqual(expanded.height, initial.height)
    }
    XCTAssertNil(MainFlutterWindow.expandedSidebarFrame(
      NSRect(x: 0, y: 30, width: 440, height: 700),
      in: NSRect(x: 0, y: 0, width: 800, height: 800)))
  }

  func testFocusLogKeepsLatestCompleteRecordsWithinSizeLimit() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "focus-log-test-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try XCTUnwrap(FocusLogWriter(url: url, maximumBytes: 96))
    for index in 0..<20 {
      writer.append("event=activation-request-\(index) active=false key=false\n")
      XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 96)
    }
    let latest = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(latest.contains("activation-request-19"))
    XCTAssertTrue(latest.hasSuffix("\n"))
    XCTAssertFalse(latest.contains("activation-request-0 "))
    writer.append(String(repeating: "x", count: 97))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), latest)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testLaunchRequestsActivationAfterLaunchCallbackReturns() {
    let window = ActivationProbeWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    let delegate = AppDelegate()
    delegate.playbackWindow = window
    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp))
    XCTAssertEqual(window.activationRequests, 0)
    let finished = expectation(description: "post-launch activation")
    DispatchQueue.main.async {
      XCTAssertEqual(window.activationRequests, 1)
      XCTAssertEqual(window.repairRequests, 1)
      XCTAssertEqual(NSApp.activationPolicy(), .regular)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 2)
  }

  func testClickRetriesActivationButHoverHiddenAndSheetWindowsDoNot() {
    let window = ActivationProbeWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    func interaction(_ type: NSEvent.EventType) {
      let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
      window.activateForWindowInteraction(event)
    }
    interaction(.mouseMoved)
    XCTAssertEqual(window.activationRequests, 0)
    interaction(.leftMouseDown)
    interaction(.leftMouseUp)
    XCTAssertEqual(window.activationRequests, 1)
    XCTAssertEqual(window.repairRequests, 1)
    // A request must not mark the native window as key before AppKit confirms.
    XCTAssertFalse(window.isKeyWindow)
    window.simulatedVisible = false
    interaction(.leftMouseDown)
    XCTAssertEqual(window.activationRequests, 1)
    window.simulatedVisible = true
    window.simulatedSheet = NSPanel()
    interaction(.leftMouseDown)
    XCTAssertEqual(window.activationRequests, 1)
    let laterClick = expectation(description: "a declined request can be retried by a later click")
    DispatchQueue.main.async {
      window.simulatedSheet = nil
      interaction(.leftMouseDown)
      XCTAssertEqual(window.activationRequests, 2)
      laterClick.fulfill()
    }
    wait(for: [laterClick], timeout: 2)
  }

  func testMainWindowCloseWaitsForDecisionAndCoalescesRequests() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.delegate = window
    var requests = 0
    var complete: ((String) -> Void)?
    window.closeRequest = { callback in requests += 1; complete = callback }
    defer { window.orderOut(nil) }
    window.makeKeyAndOrderFront(nil)
    window.performClose(nil)
    window.performClose(nil)
    XCTAssertEqual(requests, 1)
    XCTAssertTrue(window.isVisible)
    complete?("cancel")
    XCTAssertTrue(window.isVisible)
    window.performClose(nil)
    XCTAssertEqual(requests, 2)
    complete?("background")
    XCTAssertFalse(window.isVisible)
    window.restoreFromDock()
    XCTAssertTrue(window.isVisible)
  }

  func testCloseHidesWindowAndDockReopenKeepsOriginalController() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.delegate = window
    window.closeRequest = { complete in complete("background") }
    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 720))
    window.contentViewController = controller
    let delegate = AppDelegate()
    delegate.playbackWindow = window
    defer { window.orderOut(nil); window.contentViewController = nil }

    XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    let closeItem = NSApp.windowsMenu?.items.first { $0.action == #selector(NSWindow.performClose(_:)) }
    XCTAssertNotNil(closeItem)
    XCTAssertEqual(closeItem?.keyEquivalent, "w")
    XCTAssertEqual(closeItem?.keyEquivalentModifierMask, .command)
    XCTAssertNil(closeItem?.target)
    // The test host has no key window. Assert responder-chain wiring above,
    // then supply the fixture target to exercise the real menu command.
    closeItem?.target = window
    defer { closeItem?.target = nil }
    let closeEvent = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
    for _ in 0..<3 {
      window.makeKeyAndOrderFront(nil)
      NSApp.windowsMenu?.update()
      XCTAssertEqual(closeItem?.isEnabled, true)
      XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: closeEvent) == true)
      XCTAssertFalse(window.isVisible)
      XCTAssertTrue(window.contentViewController === controller)
      XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
      XCTAssertTrue(window.isVisible)
      XCTAssertTrue(delegate.playbackWindow === window)
      XCTAssertTrue(window.contentViewController === controller)
    }
    window.miniaturize(nil)
    XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    XCTAssertFalse(window.isMiniaturized)
    XCTAssertTrue(window.isVisible)
  }

  func testNativeWindowMenusHaveStableTargets() {
    let close = NSApp.windowsMenu?.items.first { $0.action == #selector(NSWindow.performClose(_:)) }
    XCTAssertNil(close?.target)
    let minimize = NSApp.windowsMenu?.items.first { $0.action == #selector(NSWindow.performMiniaturize(_:)) }
    let target = minimize?.target as? MainFlutterWindow
    XCTAssertNotNil(target)
    for action in [#selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:))] {
      let item = NSApp.windowsMenu?.items.first { $0.action == action }
      XCTAssertNotNil(item)
      XCTAssertTrue(item?.target === target)
    }
    let viewMenu = NSApp.mainMenu?.items.first { $0.tag == 8102 }?.submenu
    let fullscreen = viewMenu?.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
    XCTAssertNotNil(fullscreen)
    XCTAssertTrue(fullscreen?.target === target)
  }

  func testCloseShortcutClosesAuxiliaryWindowWithoutHidingPlayer() {
    let player = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    player.isReleasedWhenClosed = false
    player.delegate = player
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    defer { panel.orderOut(nil); player.orderOut(nil) }
    player.makeKeyAndOrderFront(nil)
    panel.makeKeyAndOrderFront(nil)
    let closeItem = NSApp.windowsMenu?.items.first { $0.action == #selector(NSWindow.performClose(_:)) }
    XCTAssertNotNil(closeItem)
    XCTAssertNil(closeItem?.target)
    // Explicitly provide the auxiliary responder in the noninteractive host.
    closeItem?.target = panel
    defer { closeItem?.target = nil }
    NSApp.windowsMenu?.update()
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: panel.windowNumber, context: nil,
      characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
    XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
    XCTAssertFalse(panel.isVisible)
    XCTAssertTrue(player.isVisible)
  }

  func testNativeTextFieldSupportsEditingMenu() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 250, height: 24))
    field.stringValue = "music folder"
    window.contentView?.addSubview(field)
    defer { window.orderOut(nil) }
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(field))
    guard let editor = field.currentEditor() as? NSTextView else {
      XCTFail("Expected native field editor")
      return
    }
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    let editMenu = NSApp.mainMenu?.items.first { $0.tag == 8101 }?.submenu
    let selectAll = editMenu?.items.first { $0.action == #selector(NSText.selectAll(_:)) }
    XCTAssertNotNil(selectAll)
    XCTAssertNil(selectAll?.target)
    selectAll?.target = editor
    defer { selectAll?.target = nil }
    editMenu?.update()
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: field.stringValue.utf16.count))
    // Verify clipboard shortcuts use the responder chain and native actions.
    for action in [#selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.paste(_:))] {
      let item = editMenu?.items.first { $0.action == action }
      XCTAssertNotNil(item)
      XCTAssertNil(item?.target)
      let key = action == #selector(NSText.copy(_:)) ? "c" : action == #selector(NSText.cut(_:)) ? "x" : "v"
      XCTAssertEqual(item?.keyEquivalent, key)
      XCTAssertEqual(item?.keyEquivalentModifierMask, .command)
      XCTAssertTrue(editor.responds(to: action))
    }
  }

  func testPlaybackLifecyclePairsNotificationsAndCleansUpIndependently() {
    let controller = FlutterViewController()
    let center = NotificationCenter()
    let lifecycle = PlaybackLifecycle(messenger: controller.engine.binaryMessenger, center: center)
    var events: [[String: Any]] = []
    lifecycle.onEvent = { events.append($0) }
    XCTAssertEqual(lifecycle.observerCount, 2)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    XCTAssertTrue(events.isEmpty)
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    XCTAssertEqual(events.count, 1)
    let first = events[0]["interruptionId"] as? String
    XCTAssertEqual(events[0]["active"] as? Bool, true)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[1]["interruptionId"] as? String, first)
    XCTAssertEqual(events[1]["active"] as? Bool, false)
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    XCTAssertNotEqual(events.last?["interruptionId"] as? String, first)
    lifecycle.dispose()
    lifecycle.dispose()
    XCTAssertEqual(lifecycle.observerCount, 0)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    XCTAssertEqual(events.count, 3)
  }


  func testGlobalRegistrationRollbackAndCleanup() {
    let controller = FlutterViewController()
    let owner = PlayerControls(messenger: controller.engine.binaryMessenger)
    let contender = PlayerControls(messenger: controller.engine.binaryMessenger)
    defer { owner.dispose(); contender.dispose() }
    func settings(_ key: Int) -> [String: Any] {
      return ["globalEnabled": true, "mediaEnabled": false,
        "global": ["toggle": ["key": key, "meta": true, "control": true, "alt": true, "shift": true]]]
    }
    XCTAssertTrue(owner.configure(settings(68)).isEmpty)
    XCTAssertTrue(contender.configure(settings(69)).isEmpty)
    XCTAssertEqual(contender.registrationCount, 1)
    XCTAssertTrue(contender.setSuspended(true).isEmpty)
    XCTAssertEqual(contender.registrationCount, 0)
    XCTAssertFalse(contender.configure(settings(68)).isEmpty)
    XCTAssertTrue(contender.setSuspended(false).isEmpty)
    XCTAssertEqual(contender.registrationCount, 1)
    XCTAssertFalse(contender.configure(settings(68)).isEmpty)
    XCTAssertEqual(contender.registrationCount, 1)
    owner.dispose()
    XCTAssertTrue(contender.configure(settings(68)).isEmpty)
    XCTAssertEqual(contender.registrationCount, 1)
    XCTAssertTrue(contender.configure(["globalEnabled": false, "mediaEnabled": false]).isEmpty)
    XCTAssertEqual(contender.registrationCount, 0)
  }

  func testNowPlayingProjectionAndStaleArtwork() {
    let controller = FlutterViewController()
    let controls = PlayerControls(messenger: controller.engine.binaryMessenger)
    defer { controls.dispose() }
    XCTAssertTrue(controls.configure(["globalEnabled": false, "mediaEnabled": true]).isEmpty)
    XCTAssertEqual(controls.remoteTargetCount, 7)
    var state: [String: Any] = ["token": "1", "hasTrack": true, "title": "Track",
      "artist": "Artist", "album": "Album", "duration": 180.0, "position": 10.0,
      "playing": true, "status": "playing", "canSeek": true]
    controls.publish(state)
    XCTAssertEqual(controls.remoteAction("seek", position: -1), .commandFailed)
    XCTAssertEqual(controls.remoteAction("seek", position: .nan), .commandFailed)
    XCTAssertEqual(controls.remoteAction("seek"), .commandFailed)
    XCTAssertEqual(controls.remoteAction("unknown"), .commandFailed)
    let center = MPNowPlayingInfoCenter.default()
    XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Track")
    XCTAssertEqual(center.playbackState, .playing)
    state["playing"] = false; state["status"] = "buffering"
    controls.publish(state)
    XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    XCTAssertEqual(center.playbackState, .paused)
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
    let data = image.tiffRepresentation!
    controls.setArtwork(token: "old", data: data)
    XCTAssertNil(center.nowPlayingInfo?[MPMediaItemPropertyArtwork])
    controls.setArtwork(token: "1", data: data)
    XCTAssertNotNil(center.nowPlayingInfo?[MPMediaItemPropertyArtwork])
    state["token"] = "2"; state["status"] = "idle"
    controls.publish(state)
    XCTAssertNil(center.nowPlayingInfo?[MPMediaItemPropertyArtwork])
    XCTAssertEqual(center.playbackState, .stopped)
    controls.publish(["hasTrack": false, "token": "3"])
    XCTAssertNil(center.nowPlayingInfo)
    XCTAssertEqual(controls.remoteAction("play"), .noSuchContent)
    XCTAssertFalse(MPRemoteCommandCenter.shared().playCommand.isEnabled)
    XCTAssertTrue(controls.configure(["globalEnabled": false, "mediaEnabled": false]).isEmpty)
    XCTAssertEqual(controls.remoteTargetCount, 0)
    controls.setArtwork(token: "3", data: data)
    XCTAssertNil(center.nowPlayingInfo)
  }

  func testBindingMappingRequiresSupportedKeyAndModifier() {
    XCTAssertNil(PlayerControls.Binding(["key": 44]))
    XCTAssertNil(PlayerControls.Binding(["key": 224, "meta": true]))
    XCTAssertEqual(PlayerControls.Binding(["key": 44, "meta": true])?.key, 49)
  }

  func testMouseTrackingRefreshReplacesAreaWithoutAccumulatingDuplicates() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let controller = FlutterViewController()
    window.contentViewController = controller
    window.contentView?.layoutSubtreeIfNeeded()

    func trackingAreas(in view: NSView) -> [NSTrackingArea] {
      return view.trackingAreas + view.subviews.flatMap { trackingAreas(in: $0) }
    }

    let original = trackingAreas(in: controller.view).filter { $0.owner === controller }
    XCTAssertEqual(original.count, 1)
    for _ in 0..<5 {
      window.acceptsMouseMovedEvents = false
      window.refreshMouseTracking()
      let areas = trackingAreas(in: controller.view).filter { $0.owner === controller }
      XCTAssertTrue(window.acceptsMouseMovedEvents)
      XCTAssertEqual(controller.mouseTrackingMode, .inActiveApp)
      XCTAssertEqual(areas.count, 1)
      XCTAssertTrue(areas.first?.options.contains(.activeInActiveApp) == true)
      XCTAssertFalse(areas.first === original.first)
    }
    // Keep the test controller from outliving its attached window.
    window.contentViewController = nil
  }

}

private final class ActivationProbeWindow: MainFlutterWindow {
  var simulatedVisible = true
  var simulatedSheet: NSWindow?
  var activationRequests = 0
  var repairRequests = 0
  override var isVisible: Bool { simulatedVisible }
  override var isKeyWindow: Bool { false }
  override var attachedSheet: NSWindow? { simulatedSheet }
  override func requestNativeApplicationActivation() { activationRequests += 1 }
  override func repairWindowFocus() { repairRequests += 1 }
}

private final class WindowButtonActionProbe: NSObject {
  var clicks = 0
  @objc func clicked(_ sender: Any?) { clicks += 1 }
}
