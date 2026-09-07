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

    // LiDAR depth capture, hand-registered because it is app-local rather
    // than a pub package.
    if #available(iOS 14.0, *) {
      DepthCapture.register(
        with: engineBridge.pluginRegistry.registrar(forPlugin: "DepthCapture")!)
    }
  }
}
