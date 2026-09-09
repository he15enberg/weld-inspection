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

    // ARKit sceneDepth needs iOS 16+. Below that the channel still answers
    // isSupported = false rather than crashing.
    if #available(iOS 16.0, *) {
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WeldzCapture")!
      ARSessionManager.register(with: registrar)
      registrar.register(ARPreviewFactory(), withId: ARPreviewFactory.viewType)
    }
  }
}
