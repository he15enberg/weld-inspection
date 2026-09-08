// One persistent ARSession, shared by the live preview and the capture.
//
// The YOLO app could not do this. Its inference plugin owned the camera, ARKit
// could not open it at the same time, and Measure had to unmount the live view,
// wait for the camera to free, then start a one-shot session -- so the RGB and
// the depth came from different moments. Nothing competes for the camera here,
// because inference runs on a frame ARKit already handed us. RGB and depth are
// the same instant by construction.
//
// The session starts with the preview and stays up, so a capture is a grab of
// `session.currentFrame` rather than a start / warm-up / tear-down round trip.

import ARKit
import Flutter
import UIKit
import VideoToolbox

@available(iOS 16.0, *)
final class ARSessionManager: NSObject, ARSessionDelegate {

    static let channelName = "weld/capture"
    static let shared = ARSessionManager()

    let session = ARSession()

    private var running = false
    private var framesSeen = 0

    /// ARKit needs a moment before sceneDepth is usable. With a persistent
    /// session this is paid once at startup, not on every capture.
    private let warmupFrames = 8

    /// Built on first use: loading the model costs ~a second and there is no
    /// reason to pay it before the user presses Capture.
    private var runner: RFDetrRunner?
    private var runnerError: String?

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

    func stop() {
        session.pause()
        running = false
        framesSeen = 0
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
                                message: "Depth is not available yet. Hold still for a moment and point at a surface 0.3–3 m away.",
                                details: nil))
            return
        }

        // Inference is the slow part; keep it off the main thread so the
        // preview does not freeze while it runs.
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
            // float32, NOT bytes: a channel Uint8List is a view into a larger
            // buffer at a non-zero offset, so reinterpreting it in Dart reads
            // the message header instead of the depth. This arrives as a
            // Float32List.
            "depth": FlutterStandardTypedData(float32: depthData),
            "confidence": FlutterStandardTypedData(bytes: confidenceData),
            "fx": Double(k.columns.0.x),
            "fy": Double(k.columns.1.y),
            "cx": Double(k.columns.2.x),
            "cy": Double(k.columns.2.y),
            "imageWidth": Int(imageSize.width),
            "imageHeight": Int(imageSize.height),
        ]

        // capturedImage is 420f bi-planar YUV; everything downstream wants BGRA
        guard let bgra = bgraCopy(frame.capturedImage) else {
            payload["inferenceError"] = "Could not convert the camera frame."
            return payload
        }
        if let jpeg = jpeg(from: bgra) {
            payload["jpeg"] = FlutterStandardTypedData(bytes: jpeg)
        }

        // Inference may fail without costing the capture: depth and the point
        // cloud are useful on their own, so failures are reported in-band.
        do {
            let runner = try self.loadedRunner()
            let detections = try runner.run(pixelBuffer: bgra)
            payload["detections"] = detections.map {
                [
                    "label": $0.label,
                    "confidence": Double($0.confidence),
                    "x0": Double($0.x0), "y0": Double($0.y0),
                    "x1": Double($0.x1), "y1": Double($0.y1),
                ]
            }
            if let cg = cgImage(from: bgra),
               let png = MaskCompositor.render(base: cg, detections: detections) {
                payload["annotated"] = FlutterStandardTypedData(bytes: png)
            }
        } catch {
            payload["detections"] = []
            payload["inferenceError"] = error.localizedDescription
        }
        return payload
    }

    private func loadedRunner() throws -> RFDetrRunner {
        if let runner { return runner }
        if let runnerError { throw RFDetrError.badOutputs(runnerError) }
        do {
            let r = try RFDetrRunner()
            runner = r
            return r
        } catch {
            // Cache the failure: a missing model will not appear mid-session,
            // and retrying the load on every capture just adds latency.
            runnerError = error.localizedDescription
            throw error
        }
    }

    // MARK: - pixel plumbing

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

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    private func jpeg(from buffer: CVPixelBuffer) -> Data? {
        guard let cg = cgImage(from: buffer) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }
}
