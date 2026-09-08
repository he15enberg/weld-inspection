// RF-DETR Seg inference: CVPixelBuffer in, detections and a mask overlay out.
//
// This is a port of train/rfdetr/reference_postprocess.py, which was verified
// bit-for-bit against the model's own predict() on real weld images before any
// of this was written. Keep the two in step: if the maths here ever changes,
// change it there first and re-run the parity check.
//
// Why the model is driven directly rather than through Vision: the exported
// .mlpackage takes an MLMultiArray, not an image. rfdetr's converter calls
// ct.convert() with no ImageType (export/_coreml/converter.py:175), so there is
// no image input for VNCoreMLRequest to bind to, and no built-in resize or
// colour handling either. Everything below the model is ours.

import Accelerate
import CoreML
import CoreVideo
import UIKit

struct WeldDetection {
    let label: String
    let confidence: Float
    /// Normalised 0..1 in the captured image's own frame.
    let x0, y0, x1, y1: Float
    /// Row-major mask logits at the model's native mask grid.
    let mask: [Float]
    let maskWidth: Int
    let maskHeight: Int
}

enum RFDetrError: LocalizedError {
    case modelMissing
    case badOutputs(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "weld_rfdetr.mlmodelc is not in the app bundle. Add the .mlpackage to the Runner target in Xcode so it is compiled at build time."
        case .badOutputs(let detail):
            return "Unexpected model outputs: \(detail)"
        }
    }
}

final class RFDetrRunner {

    // MARK: - configuration

    /// Class list in the model's own index order. This is the data-40 (7-class)
    /// order; the combined-dataset model inserts `discontinuity` at index 1 and
    /// shifts everything after it, so this list moves with the checkpoint.
    /// `classNames.count` is checked against the head width at load time.
    static let classNames = [
        "crack", "overlap", "porosity", "spatter",
        "undercut", "weld_seam", "workpiece",
    ]

    /// Matches PostProcess's default; the cap applies before thresholding.
    static let numSelect = 300

    /// ImageNet statistics, as the exported model expects.
    private static let mean: (Float, Float, Float) = (0.485, 0.456, 0.406)
    private static let std: (Float, Float, Float) = (0.229, 0.224, 0.225)

    private let model: MLModel
    private let inputName: String
    private let side: Int

    /// True when the logits are one wider than the class list, i.e. the head
    /// carries a background slot. Detected rather than hardcoded — the data-40
    /// checkpoint has one at the LAST index, and dropping the wrong column
    /// shifts every label.
    private let hasBackground: Bool

    // MARK: - loading

    init(modelName: String = "weld_rfdetr") throws {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw RFDetrError.modelMissing
        }
        let config = MLModelConfiguration()
        // .all lets Core ML place work on the ANE when it can. The deformable
        // attention may not map, in which case it silently falls back to GPU or
        // CPU -- slower, but correct.
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)

        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.first,
              let shape = input.value.multiArrayConstraint?.shape,
              shape.count == 4 else {
            throw RFDetrError.badOutputs("model input is not a rank-4 MLMultiArray")
        }
        inputName = input.key
        side = shape[2].intValue

        // Head width vs class list, checked once so a mismatched checkpoint
        // fails loudly here instead of mislabelling every detection.
        let logitWidth = desc.outputDescriptionsByName.values
            .compactMap { $0.multiArrayConstraint?.shape }
            .filter { $0.count == 3 && $0[2].intValue != 4 }
            .map { $0[2].intValue }
            .first
        let n = Self.classNames.count
        switch logitWidth {
        case .some(n):      hasBackground = false
        case .some(n + 1):  hasBackground = true
        case .some(let w):
            throw RFDetrError.badOutputs("logits width \(w) matches neither \(n) classes nor \(n)+background")
        case .none:
            throw RFDetrError.badOutputs("no logits output found")
        }
    }

    // MARK: - inference

    func run(pixelBuffer: CVPixelBuffer, threshold: Float = 0.25) throws -> [WeldDetection] {
        let input = try preprocess(pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
        let out = try model.prediction(from: provider)
        let (dets, logits, masks) = try bind(out)
        return postprocess(dets: dets, logits: logits, masks: masks, threshold: threshold)
    }

    // MARK: - preprocessing

    /// BGRA pixel buffer -> (1, 3, side, side) float32 NCHW, ImageNet-normalised.
    ///
    /// A plain STRETCH to square: no letterbox, no aspect preservation. That is
    /// what predict() does, and it is why postprocess() can multiply normalised
    /// boxes straight by the original size.
    ///
    /// The resample is hand-written bilinear with half-pixel centres and NO
    /// antialiasing, because that is what torchvision does with antialias=False.
    /// vImageScale and Core Image both antialias when downscaling, which shifts
    /// pixel values and therefore confidences -- silently, with no error. Doing
    /// the sampling here costs a few million multiply-adds on a one-shot
    /// capture and buys exact parity with the Python reference.
    private func preprocess(_ buffer: CVPixelBuffer) throws -> MLMultiArray {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw RFDetrError.badOutputs("pixel buffer has no base address")
        }
        let src = base.assumingMemoryBound(to: UInt8.self)

        // ARKit's capturedImage is 420f (bi-planar YUV), so the caller converts
        // to BGRA first; see ARSessionManager.bgraCopy.
        let bgra = CVPixelBufferGetPixelFormatType(buffer)
        guard bgra == kCVPixelFormatType_32BGRA else {
            throw RFDetrError.badOutputs("expected 32BGRA, got \(bgra)")
        }

        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let plane = side * side
        let scaleX = Float(srcW) / Float(side)
        let scaleY = Float(srcH) / Float(side)
        let means = [Self.mean.0, Self.mean.1, Self.mean.2]
        let stds = [Self.std.0, Self.std.1, Self.std.2]

        for dy in 0..<side {
            // half-pixel centres == align_corners=false
            let fy = max(0, (Float(dy) + 0.5) * scaleY - 0.5)
            let y0 = min(Int(fy), srcH - 1)
            let y1 = min(y0 + 1, srcH - 1)
            let wy = fy - Float(y0)

            for dx in 0..<side {
                let fx = max(0, (Float(dx) + 0.5) * scaleX - 0.5)
                let x0 = min(Int(fx), srcW - 1)
                let x1 = min(x0 + 1, srcW - 1)
                let wx = fx - Float(x0)

                let r00 = y0 * stride, r10 = y1 * stride
                let o00 = r00 + x0 * 4, o01 = r00 + x1 * 4
                let o10 = r10 + x0 * 4, o11 = r10 + x1 * 4
                let outIdx = dy * side + dx

                // BGRA in memory; channel c of RGB reads byte (2 - c)
                for c in 0..<3 {
                    let b = 2 - c
                    let top = Float(src[o00 + b]) * (1 - wx) + Float(src[o01 + b]) * wx
                    let bot = Float(src[o10 + b]) * (1 - wx) + Float(src[o11 + b]) * wx
                    let v = (top * (1 - wy) + bot * wy) / 255.0
                    dst[c * plane + outIdx] = (v - means[c]) / stds[c]
                }
            }
        }
        return array
    }

    // MARK: - output binding

    /// coremltools does not preserve the ONNX output names, so outputs are
    /// matched by rank and last dimension exactly as the reference does:
    /// boxes are the rank-3 tensor with last dim 4, logits the other rank-3,
    /// masks the rank-4.
    private func bind(_ out: MLFeatureProvider) throws -> (MLMultiArray, MLMultiArray, MLMultiArray?) {
        var arrays: [MLMultiArray] = []
        for name in out.featureNames {
            if let a = out.featureValue(for: name)?.multiArrayValue { arrays.append(a) }
        }
        let rank3 = arrays.filter { $0.shape.count == 3 }
        guard let dets = rank3.first(where: { $0.shape[2].intValue == 4 }),
              let logits = rank3.first(where: { $0.shape[2].intValue != 4 })
        else {
            throw RFDetrError.badOutputs(arrays.map { $0.shape.description }.joined(separator: " "))
        }
        return (dets, logits, arrays.first { $0.shape.count == 4 })
    }

    // MARK: - postprocessing

    private func postprocess(dets: MLMultiArray,
                             logits: MLMultiArray,
                             masks: MLMultiArray?,
                             threshold: Float) -> [WeldDetection] {
        let q = logits.shape[1].intValue
        let cAll = logits.shape[2].intValue
        // Background sits at the LAST slot when present, so the kept columns
        // are simply the first `c` of them and class index == column index.
        let c = hasBackground ? cAll - 1 : cAll

        let lp = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
        let bp = dets.dataPointer.bindMemory(to: Float.self, capacity: dets.count)

        // 1. per-class sigmoid -- NOT softmax; the classes are independent
        var scored: [(score: Float, query: Int, cls: Int)] = []
        scored.reserveCapacity(q * c)
        for i in 0..<q {
            for j in 0..<c {
                let z = min(max(lp[i * cAll + j], -88), 88)
                scored.append((1 / (1 + exp(-z)), i, j))
            }
        }

        // 2. top-k over the FLATTENED (Q, C) grid, then threshold.
        //    Not an argmax per query: a query can clear the threshold on more
        //    than one class, and taking one class per query drops the rest
        //    silently. Measured on real welds: harmless at 0.25, loses ~20% of
        //    detections at 0.05, and collapses at 0.01.
        //    Tie-break is score descending then flattened index ascending, so
        //    equal scores come out in the same order as the reference.
        let ranked = scored.enumerated()
            .sorted { a, b in
                a.element.score != b.element.score
                    ? a.element.score > b.element.score
                    : a.offset < b.offset
            }
            .prefix(Self.numSelect)
            .filter { $0.element.score > threshold }

        // mask grid, if this is a segmentation head
        let mp = masks?.dataPointer.bindMemory(to: Float.self, capacity: masks!.count)
        let mh = masks?.shape[2].intValue ?? 0
        let mw = masks?.shape[3].intValue ?? 0

        return ranked.map { entry in
            let (_, query, cls) = entry.element

            // 3. gather by query index -- repeats are expected and fine
            let o = query * 4
            let cx = bp[o], cy = bp[o + 1], bw = bp[o + 2], bh = bp[o + 3]

            // 4. cxcywh -> xyxy, still normalised
            var mask: [Float] = []
            if let mp, mh > 0 {
                let start = query * mh * mw
                mask = Array(UnsafeBufferPointer(start: mp + start, count: mh * mw))
            }

            return WeldDetection(
                label: cls < Self.classNames.count ? Self.classNames[cls] : "class\(cls)",
                confidence: entry.element.score,
                x0: cx - bw / 2, y0: cy - bh / 2,
                x1: cx + bw / 2, y1: cy + bh / 2,
                mask: mask, maskWidth: mw, maskHeight: mh
            )
        }
    }
}
