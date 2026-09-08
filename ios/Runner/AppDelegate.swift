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

    // ARKit sceneDepth and the CoreML mlprogram both need iOS 16+. Below that
    // the channel still answers isSupported=false rather than crashing.
    if #available(iOS 16.0, *) {
      let registry = engineBridge.pluginRegistry
      let registrar = registry.registrar(forPlugin: "WeldCapture")!
      ARSessionManager.register(with: registrar)
      registrar.register(ARPreviewFactory(), withId: ARPreviewFactory.viewType)
    }
  }
}
