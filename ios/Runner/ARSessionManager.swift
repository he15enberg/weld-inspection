// One persistent ARSession, shared by the live preview and the capture.
//
// Nothing competes for the camera here, so RGB and depth come out of the SAME
// ARFrame -- the same instant, by construction. A capture is a grab of
// `session.currentFrame`, not a start / warm-up / tear-down round trip.
//
// This file only captures. Inference lives on the server.

import ARKit
import Flutter
import UIKit
import VideoToolbox

@available(iOS 16.0, *)
final class ARSessionManager: NSObject, ARSessionDelegate {

    static let channelName = "weldz/capture"
    static let shared = ARSessionManager()

    let session = ARSession()

    private var running = false
    private var framesSeen = 0

    /// ARKit needs a moment before sceneDepth is usable. With a persistent
    /// session this is paid once at startup, not on every capture.
    private let warmupFrames = 8

    private override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - registration

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName,
                                           binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { call, result in
            guard #available(iOS 16.0, *) else {
                result(FlutterError(code: "unsupported",
                                    message: "Requires iOS 16 or newer.", details: nil))
                return
            }
            switch call.method {
            case "isSupported":
                result(ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
            case "capture":
                shared.capture(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - session lifecycle

    func start() {
        guard !running,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .sceneDepth
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        framesSeen += 1
    }

    // MARK: - capture

    private func capture(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            result(FlutterError(code: "unsupported",
                                message: "This device has no LiDAR scanner (iPhone 12 Pro or newer Pro required).",
                                details: nil))
            return
        }
        start()

        guard framesSeen >= warmupFrames,
              let frame = session.currentFrame,
              let depth = frame.sceneDepth else {
            result(FlutterError(code: "not_ready",
                                message: "Depth is not ready. Hold still a moment and point at a surface 0.3–3 m away.",
                                details: nil))
            return
        }

        // JPEG encoding is the slow part; keep it off the main thread so the
        // preview does not stutter.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let payload = self.encode(frame: frame, depth: depth)
            DispatchQueue.main.async { result(payload) }
        }
    }

    private func encode(frame: ARFrame, depth: ARDepthData) -> [String: Any] {
        let depthMap = depth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // Intrinsics describe the CAPTURED IMAGE, not the 256x192 depth grid.
        // Both sizes go up; whoever indexes the depth grid rescales. Mixing the
        // two pixel spaces is the classic ARKit depth bug and it produces
        // plausible, wrong millimetres.
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution

        var payload: [String: Any] = [
            "depthWidth": width,
            "depthHeight": height,
            "depth": FlutterStandardTypedData(bytes: millimetres(depthMap)),
            "confidence": FlutterStandardTypedData(
                bytes: depth.confidenceMap.map { copyPlane($0, bytesPerPixel: 1) }
                    // ARConfidenceLevel.high == 2
                    ?? Data(repeating: 2, count: width * height)),
            "fx": Double(k.columns.0.x),
            "fy": Double(k.columns.1.y),
            "cx": Double(k.columns.2.x),
            "cy": Double(k.columns.2.y),
            "imageWidth": Int(size.width),
            "imageHeight": Int(size.height),
        ]

        // capturedImage is 420f bi-planar YUV; JPEG wants BGRA first
        if let bgra = bgraCopy(frame.capturedImage), let data = jpeg(from: bgra) {
            payload["jpeg"] = FlutterStandardTypedData(bytes: data)
        }
        return payload
    }

    // MARK: - pixel plumbing

    /// Float32 metres -> uint16 millimetres, little-endian. Zero already means
    /// "no reading" in ARKit's map, so the sentinel survives.
    ///
    /// Halves the upload versus float32 and compresses far better, because
    /// millimetre integers are not near-random the way float mantissas are. The
    /// 1 mm quantisation sits an order of magnitude under ARKit's own noise
    /// (~1% of range, so ~3 mm at 300 mm).
    private func millimetres(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Data(count: w * h * 2)
        }

        var out = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            // rows are padded: bytesPerRow is not width * 4
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let metres = row[x]
                guard metres.isFinite, metres > 0 else { continue }
                out[y * w + x] = UInt16(min(metres * 1000, 65535))
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Copy a locked plane out row by row, because the buffer is padded and
    /// bytesPerRow is not width * bytesPerPixel.
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
            out.append(Data(bytes: base.advanced(by: row * stride), count: rowBytes))
        }
        return out
    }

    private func bgraCopy(_ yuv: CVPixelBuffer) -> CVPixelBuffer? {
        let ci = CIImage(cvPixelBuffer: yuv)
        let w = CVPixelBufferGetWidth(yuv), h = CVPixelBufferGetHeight(yuv)
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }
        CIContext().render(ci, to: buffer)
        return buffer
    }

    private func jpeg(from buffer: CVPixelBuffer) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let cg = image else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }
}
