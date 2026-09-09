// Draw RF-DETR's masks onto the captured frame, and hand the result back as PNG.
//
// The masks stay native on purpose. At 100 queries x 318x318 they are ~40 MB of
// float per capture; shipping them over a platform channel to draw in Dart
// would dominate the whole round trip. Compositing here sends one image
// instead. Boxes and the millimetre labels are still drawn in Dart, over this,
// because the mm figures are computed there from the depth frame.
//
// Three things this gets right that the first version did not:
//
//   1. NO FLIP. A raw CGBitmapContext already places row 0 of a drawn CGImage
//      at the top of the buffer -- the translate/scale(1,-1) idiom belongs to
//      UIKit contexts, which are y-flipped relative to Quartz. Applying it to
//      the masks but not the base photo mirrored every mask vertically, which
//      is why they sat above the thing they belonged to.
//
//   2. UPSAMPLE, THEN THRESHOLD. The verified Python reference interpolates the
//      mask LOGITS to full size and only then tests > 0. Thresholding first, on
//      the 318x318 grid, gives a staircase edge at a sixth of the resolution.
//
//   3. Sampling by hand rather than letting CGContext scale a binary bitmap,
//      which produced a soft grey halo that then got alpha-blended outward.
//
// Bilinear with half-pixel centres, matching F.interpolate(align_corners: false).

import CoreGraphics
import UIKit

enum MaskCompositor {

    /// Same palette as train/overlay.py, so a phone screenshot and a desktop
    /// prediction of the same weld can be read side by side.
    private static let colors: [String: (Float, Float, Float)] = [
        "crack":         (231, 76,  60),
        "discontinuity": (230, 126, 34),
        "overlap":       (155, 89,  182),
        "porosity":      (230, 126, 34),
        "spatter":       (26,  188, 156),
        "undercut":      (241, 196, 15),
        "weld_seam":     (46,  204, 113),
        "workpiece":     (255, 255, 0),
    ]
    private static let fallback: (Float, Float, Float) = (200, 200, 200)

    /// Large regions get a light wash so the defects on top stay legible.
    private static let structural: Set<String> = ["workpiece", "weld_seam"]
    private static let fillAlpha: Float = 0.35
    private static let structuralAlpha: Float = 0.15

    /// Per-axis bilinear taps, precomputed once per (source, destination) pair
    /// because every detection shares the same mask grid.
    private struct Taps {
        let lo: [Int]
        let hi: [Int]
        let frac: [Float]

        init(from src: Int, to dst: Int) {
            var lo = [Int](repeating: 0, count: dst)
            var hi = [Int](repeating: 0, count: dst)
            var frac = [Float](repeating: 0, count: dst)
            let scale = Float(src) / Float(dst)
            for i in 0..<dst {
                let f = max(0, (Float(i) + 0.5) * scale - 0.5)   // half-pixel centres
                let a = min(Int(f), src - 1)
                lo[i] = a
                hi[i] = min(a + 1, src - 1)
                frac[i] = f - Float(a)
            }
            self.lo = lo; self.hi = hi; self.frac = frac
        }
    }

    static func render(base: CGImage, detections: [WeldDetection]) -> Data? {
        let w = base.width, h = base.height
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // No transform: for a CGBitmapContext this already lands the photo's
        // top row at buffer row 0. Anything drawn afterwards must use the same
        // convention -- that was the alignment bug.
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let rowBytes = ctx.bytesPerRow

        // structural first so defect masks land on top of them
        let ordered = detections.filter { structural.contains($0.label) }
            + detections.filter { !structural.contains($0.label) }

        var xTaps: [Int: Taps] = [:]
        var yTaps: [Int: Taps] = [:]

        for d in ordered where d.maskWidth > 0 && d.maskHeight > 0 {
            let mw = d.maskWidth, mh = d.maskHeight
            let tx = xTaps[mw] ?? Taps(from: mw, to: w); xTaps[mw] = tx
            let ty = yTaps[mh] ?? Taps(from: mh, to: h); yTaps[mh] = ty

            let (r, g, b) = colors[d.label] ?? fallback
            let a = structural.contains(d.label) ? structuralAlpha : fillAlpha
            let keep = 1 - a

            d.mask.withUnsafeBufferPointer { m in
                for y in 0..<h {
                    let r0 = ty.lo[y] * mw, r1 = ty.hi[y] * mw
                    let wy = ty.frac[y], iwy = 1 - wy
                    let out = y * rowBytes

                    for x in 0..<w {
                        let x0 = tx.lo[x], x1 = tx.hi[x]
                        let wx = tx.frac[x], iwx = 1 - wx

                        // interpolate the LOGIT, then threshold -- the order the
                        // reference uses. Threshold 0 == sigmoid 0.5.
                        let top = m[r0 + x0] * iwx + m[r0 + x1] * wx
                        let bot = m[r1 + x0] * iwx + m[r1 + x1] * wx
                        guard top * iwy + bot * wy > 0 else { continue }

                        let o = out + x * 4
                        px[o]     = UInt8(Float(px[o])     * keep + r * a)
                        px[o + 1] = UInt8(Float(px[o + 1]) * keep + g * a)
                        px[o + 2] = UInt8(Float(px[o + 2]) * keep + b * a)
                    }
                }
            }
        }

        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out).pngData()
    }
}
