import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Retain the original engine and window while its UI is hidden.
  var playbackWindow: MainFlutterWindow?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Do not let Launch Services foreground a half-initialized AppKit app.
    // The captured failures were already system-frontmost while NSApp never
    // became active; repeating either activation API did not repair them.
    // Keep activation disabled until finishLaunching has fully returned.
    NSApp.setActivationPolicy(.prohibited)
    // The app owns one persistent player window, not native document tabs.
    NSWindow.allowsAutomaticWindowTabbing = false
    // Point OpenSSL at the packaged CA bundle and prove the packaged audio
    // libraries load before the Flutter engine or any playback work starts.
    NativeLibraries.prepare()
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    (playbackWindow ?? mainFlutterWindow as? MainFlutterWindow)?.logFocusState(
      "launch-playback-bound-\(playbackWindow != nil)")
    // FlutterAppDelegate does not implement this optional delegate callback.
    // Request activation after AppKit has finished launching, not from nib
    // initialization. Key-window state is repaired on actual activation.
    DispatchQueue.main.async { [weak self] in
      // Restore regular policy even if the window outlet is unavailable.
      // Prohibited policy can prevent initial window ordering, so show the
      // original window explicitly before making the activation request.
      NSApp.setActivationPolicy(.regular)
      guard let window = self?.playbackWindow else { return }
      window.logFocusState("launch-activation-enabled")
      window.restoreFromDock()
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return playbackWindow?.requestTermination() ?? .terminateCancel
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication,
                                              hasVisibleWindows flag: Bool) -> Bool {
    playbackWindow?.restoreFromDock()
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
