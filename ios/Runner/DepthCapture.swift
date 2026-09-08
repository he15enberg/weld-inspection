// One-shot ARKit LiDAR depth capture, exposed to Flutter on "weld/depth".
//
// The session is started on demand and torn down immediately after the grab.
// That is deliberate: YOLOView holds the camera for the live view, and ARKit
// cannot open it at the same time. Dart unmounts YOLOView before calling here.
//
// NOTE: written on Windows and never compiled. Treat as unverified until it
// builds on a Mac.

import ARKit
import Flutter
import UIKit

@available(iOS 14.0, *)
final class DepthCapture: NSObject, ARSessionDelegate {

    static let channelName = "weld/depth"

    private var session: ARSession?
    private var pending: FlutterResult?
    private var framesSeen = 0

    /// Discard the first few frames: ARKit needs a moment to expose the depth
    /// buffer and settle exposure, and the earliest frames are unusable.
    private let warmupFrames = 8

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName,
                                          binaryMessenger: registrar.messenger())
        let instance = DepthCapture()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
        case "capture":
            capture(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - capture

    private func capture(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            result(FlutterError(code: "unsupported",
                                message: "This device has no LiDAR scanner (iPhone 12 Pro or newer Pro required).",
                                details: nil))
            return
        }
        guard pending == nil else {
            result(FlutterError(code: "busy", message: "A capture is already running.", details: nil))
            return
        }

        pending = result
        framesSeen = 0

        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .sceneDepth

        let session = ARSession()
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        self.session = session

        // never leave the caller hanging if depth never arrives
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let pending = self.pending else { return }
            self.finish()
            pending(FlutterError(code: "timeout",
                                 message: "No depth frame within 6 s. Point at a surface 0.3–3 m away.",
                                 details: nil))
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard pending != nil else { return }
        framesSeen += 1
        guard framesSeen >= warmupFrames, let depth = frame.sceneDepth else { return }

        let payload = encode(frame: frame, depth: depth)
        let result = pending
        finish()
        result?(payload)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard let pending else { return }
        finish()
        pending(FlutterError(code: "ar_failed", message: error.localizedDescription, details: nil))
    }

    private func finish() {
        session?.pause()
        session?.delegate = nil
        session = nil
        pending = nil
    }

    // MARK: - encoding

    private func encode(frame: ARFrame, depth: ARDepthData) -> [String: Any] {
        let depthMap = depth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        let depthData = copyPlane(depthMap, bytesPerPixel: 4)
        let confidenceData = depth.confidenceMap.map { copyPlane($0, bytesPerPixel: 1) }
            // ARConfidenceLevel.high == 2, matching DepthFrame.confidenceHigh
            ?? Data(repeating: 2, count: width * height)

        // Intrinsics describe the CAPTURED IMAGE, not the depth grid. They are
        // sent as-is together with the image size; Dart rescales them. Mixing
        // the two pixel spaces is the classic ARKit depth bug.
        let k = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution

        var payload: [String: Any] = [
            "width": width,
            "height": height,
            // float32, NOT bytes: sending raw bytes forces Dart to reinterpret
            // them, and a channel Uint8List is a view into a larger buffer with
            // a non-zero offset, so that reinterpretation reads the message
            // header instead of the depth. This arrives as a Float32List.
            "depth": FlutterStandardTypedData(float32: depthData),
            "confidence": FlutterStandardTypedData(bytes: confidenceData),
            "fx": Double(k.columns.0.x),
            "fy": Double(k.columns.1.y),
            "cx": Double(k.columns.2.x),
            "cy": Double(k.columns.2.y),
            "imageWidth": Int(imageSize.width),
            "imageHeight": Int(imageSize.height),
        ]

        if let jpeg = jpegFrom(pixelBuffer: frame.capturedImage) {
            payload["jpeg"] = FlutterStandardTypedData(bytes: jpeg)
        }
        return payload
    }

    /// Copy a locked pixel buffer plane out row by row, because the buffer is
    /// padded and bytesPerRow is not width * bytesPerPixel.
    private func copyPlane(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * bytesPerPixel

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Data(count: rowBytes * height)
        }

        var out = Data(capacity: rowBytes * height)
        for row in 0..<height {
            let start = base.advanced(by: row * stride)
            out.append(Data(bytes: start, count: rowBytes))
        }
        return out
    }

    private func jpegFrom(pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }
}
