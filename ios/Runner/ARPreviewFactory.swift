// The live ARKit view, exposed to Flutter as a platform view.
//
// It renders the shared ARSessionManager.session rather than owning one, so the
// preview and the capture are the same session -- mounting this view is what
// starts the camera, and a capture is then just a grab of its current frame.

import ARKit
import Flutter
import UIKit

@available(iOS 16.0, *)
final class ARPreviewFactory: NSObject, FlutterPlatformViewFactory {

    /// Must match ArPreview.viewType in ar_preview.dart.
    static let viewType = "weldz/ar_preview"

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        ARPreviewView(frame: frame)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

@available(iOS 16.0, *)
final class ARPreviewView: NSObject, FlutterPlatformView {

    // Not named `view`: FlutterPlatformView requires a `view()` method, and a
    // stored property of the same name is a redeclaration.
    private let arView: ARSCNView

    init(frame: CGRect) {
        arView = ARSCNView(frame: frame)
        // The shared session, not a new one. ARSCNView would otherwise create
        // its own and the two would fight over the camera -- exactly the
        // problem this app exists to avoid.
        arView.session = ARSessionManager.shared.session
        arView.automaticallyUpdatesLighting = true
        super.init()
        ARSessionManager.shared.start()
    }

    func view() -> UIView { arView }

    // Flutter disposes the platform view when the widget unmounts. The session
    // is deliberately left running: the result screen sits over the preview
    // only briefly, and restarting ARKit means paying the warm-up again.
    deinit {}
}
