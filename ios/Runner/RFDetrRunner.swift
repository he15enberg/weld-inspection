// RF-DETR Seg inference: CVPixelBuffer in, detections and mask logits out.
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
//
// All tensor reads go through MLTensor, which honours dtype and strides. The
// first version bound raw pointers as Float32 and assumed row-major, which is
// how 800 logits silently came back as ~0 and every detection scored 50%.

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

    /// Class list in the model's own index order: the annotated COCO categories,
    /// filtered and sorted, enumerated from 0 — exactly what rfdetr's dataset
    /// loader derives for cat2label, so these indices are the model's.
    ///
    /// This is the **dataset-combined (8-class)** order. The earlier data-40
    /// checkpoint had 7 and no `discontinuity`; adding it at index 1 shifts
    /// every class after it, which is why this list moves with the checkpoint
    /// rather than being a fixed alphabet.
    static let classNames = [
        "crack", "discontinuity", "overlap", "porosity",
        "spatter", "undercut", "weld_seam", "workpiece",
    ]

    /// Matches PostProcess's default; the cap applies before thresholding.
    static let numSelect = 300

    /// ImageNet statistics, as the exported model expects.
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]

    /// Set false once this is trusted; the logging costs a few ms per capture.
    static var verbose = true

    private let model: MLModel
    private let inputName: String
    private let side: Int

    /// True when the logits are one wider than the class list, i.e. the head
    /// carries a background slot. Detected rather than hardcoded — the data-40
    /// checkpoint has one at the LAST index, and dropping the wrong column
    /// shifts every label.
    private var hasBackground = false

    // MARK: - loading

    init(modelName: String = "weld_rfdetr") throws {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw RFDetrError.modelMissing
        }
        let config = MLModelConfiguration()
        // .all lets Core ML place work on the ANE when it can. That is also why
        // output dtype cannot be assumed: the ANE returns what suits it.
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

        if Self.verbose {
            print("[RFDetr] ---- model loaded ----")
            print("[RFDetr] input '\(inputName)' shape \(shape.map(\.intValue)) side \(side)")
            for (name, d) in desc.outputDescriptionsByName {
                let s = d.multiArrayConstraint?.shape.map(\.intValue) ?? []
                let t = d.multiArrayConstraint?.dataType
                print("[RFDetr] declared output '\(name)' shape \(s)"
                      + (t.map { " \(MLTensor.typeName($0))" } ?? ""))
            }
            print("[RFDetr] classNames (\(Self.classNames.count)): \(Self.classNames)")
        }
    }

    // MARK: - inference

    func run(pixelBuffer: CVPixelBuffer, threshold: Float = 0.25) throws -> [WeldDetection] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let input = try preprocess(pixelBuffer)
        let t1 = CFAbsoluteTimeGetCurrent()

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
        let out = try model.prediction(from: provider)
        let t2 = CFAbsoluteTimeGetCurrent()

        let (dets, logits, masks) = try bind(out)

        if Self.verbose {
            print("[RFDetr] ---- capture ----")
            print(MLTensor.describe("input", input))
            print(MLTensor.describe("dets", dets))
            print(MLTensor.describe("logits", logits))
            if let masks { print(MLTensor.describe("masks", masks)) }
        }

        let result = postprocess(dets: dets, logits: logits, masks: masks, threshold: threshold)
        let t3 = CFAbsoluteTimeGetCurrent()

        if Self.verbose {
            print(String(format: "[RFDetr] timing  pre %.0f ms  predict %.0f ms  post %.0f ms",
                         (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
            print("[RFDetr] detections: \(result.count) at threshold \(threshold)")
            for d in result.prefix(10) {
                print(String(format: "[RFDetr]   %@ %.3f  box [%.4f %.4f %.4f %.4f]",
                             d.label, d.confidence, d.x0, d.y0, d.x1, d.y1))
            }
            if result.count == Self.numSelect {
                print("[RFDetr] !! hit the numSelect cap — scores are probably degenerate")
            }
        }
        return result
    }

    // MARK: - preprocessing

    /// BGRA pixel buffer -> (1, 3, side, side) float32 NCHW, ImageNet-normalised.
    ///
    /// A plain STRETCH to square: no letterbox, no aspect preservation. That is
    /// what predict() does, and it is why postprocess() can multiply normalised
    /// boxes straight by the original size.
    ///
    /// The resample is hand-written bilinear with half-pixel centres and NO
    /// antialiasing, because that is what torchvision does with antialias=false.
    /// vImageScale and Core Image both antialias when downscaling, which shifts
    /// pixel values and therefore confidences -- silently, with no error.
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

        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw RFDetrError.badOutputs("expected 32BGRA, got \(format)")
        }
        if Self.verbose {
            print("[RFDetr] source \(srcW)x\(srcH) bytesPerRow \(stride) "
                  + "(packed would be \(srcW * 4)) -> \(side)x\(side) stretch")
        }

        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let plane = side * side
        let scaleX = Float(srcW) / Float(side)
        let scaleY = Float(srcH) / Float(side)

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

                let r0 = y0 * stride, r1 = y1 * stride
                let o00 = r0 + x0 * 4, o01 = r0 + x1 * 4
                let o10 = r1 + x0 * 4, o11 = r1 + x1 * 4
                let outIdx = dy * side + dx

                // BGRA in memory; channel c of RGB reads byte (2 - c)
                for c in 0..<3 {
                    let b = 2 - c
                    let top = Float(src[o00 + b]) * (1 - wx) + Float(src[o01 + b]) * wx
                    let bot = Float(src[o10 + b]) * (1 - wx) + Float(src[o11 + b]) * wx
                    let v = (top * (1 - wy) + bot * wy) / 255.0
                    dst[c * plane + outIdx] = (v - Self.mean[c]) / Self.std[c]
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
        var named: [(String, MLMultiArray)] = []
        for name in out.featureNames {
            if let a = out.featureValue(for: name)?.multiArrayValue { named.append((name, a)) }
        }
        if Self.verbose {
            let summary = named.map { "\($0.0)\($0.1.shape.map(\.intValue))" }.joined(separator: " ")
            print("[RFDetr] raw outputs: \(summary)")
        }

        let arrays = named.map(\.1)
        let rank3 = arrays.filter { $0.shape.count == 3 }
        guard let dets = rank3.first(where: { $0.shape[2].intValue == 4 }),
              let logits = rank3.first(where: { $0.shape[2].intValue != 4 })
        else {
            throw RFDetrError.badOutputs(arrays.map { $0.shape.description }.joined(separator: " "))
        }

        // Head width vs class list, checked on the real tensor rather than the
        // declared description, which can carry symbolic dimensions.
        let width = logits.shape[2].intValue
        let n = Self.classNames.count
        switch width {
        case n:      hasBackground = false
        case n + 1:  hasBackground = true
        default:
            throw RFDetrError.badOutputs(
                "logits width \(width) matches neither \(n) classes nor \(n)+background")
        }
        if Self.verbose {
            print("[RFDetr] logits width \(width) vs \(n) classes -> "
                  + (hasBackground ? "background slot present (last column dropped)"
                                   : "no background slot"))
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
        // are the first `c` and class index == column index.
        let c = hasBackground ? cAll - 1 : cAll

        // Materialised through MLTensor: dtype-aware and stride-aware. Both are
        // small (100x9 and 100x4), so the copy is trivial.
        let lg = MLTensor.floats(logits)
        let bx = MLTensor.floats(dets)

        // 1. per-class sigmoid -- NOT softmax; the classes are independent
        var scored: [(score: Float, query: Int, cls: Int)] = []
        scored.reserveCapacity(q * c)
        for i in 0..<q {
            for j in 0..<c {
                let z = min(max(lg[i * cAll + j], -88), 88)
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

        if Self.verbose {
            let top = scored.map(\.score).sorted(by: >).prefix(5)
            print("[RFDetr] top 5 scores: " + top.map { String(format: "%.4f", $0) }
                .joined(separator: " "))
        }

        let mh = masks?.shape[2].intValue ?? 0
        let mw = masks?.shape[3].intValue ?? 0

        return ranked.map { entry in
            let (_, query, cls) = entry.element

            // 3. gather by query index -- repeats are expected and fine
            let o = query * 4
            let cx = bx[o], cy = bx[o + 1], bw = bx[o + 2], bh = bx[o + 3]

            // 4. cxcywh -> xyxy, still normalised
            var mask: [Float] = []
            if let masks, mh > 0 {
                mask = MLTensor.gather(masks, query: query)
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
