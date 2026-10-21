import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FideflowDevice") {
      let channel = FlutterMethodChannel(name: "fideflow/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "deviceName" {
          let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
          result(name.isEmpty ? UIDevice.current.model : name)
        } else { result(FlutterMethodNotImplemented) }
      }
    }
  }
}
