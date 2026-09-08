// Draw RF-DETR's masks onto the captured frame, and hand the result back as PNG.
//
// The masks stay native on purpose. At 100 queries x 318x318 they are ~40 MB of
// float per capture; shipping them over a platform channel to draw in Dart
// would dominate the whole round trip. Compositing here sends one image
// instead. Boxes and the millimetre labels are still drawn in Dart, over this,
// because the mm figures are computed there from the depth frame.

import CoreGraphics
import UIKit

enum MaskCompositor {

    /// Same palette as train/overlay.py, so a phone screenshot and a desktop
    /// prediction of the same weld can be read side by side.
    private static let colors: [String: (CGFloat, CGFloat, CGFloat)] = [
        "crack":         (231, 76,  60),
        "discontinuity": (230, 126, 34),
        "overlap":       (155, 89,  182),
        "porosity":      (230, 126, 34),
        "spatter":       (26,  188, 156),
        "undercut":      (241, 196, 15),
        "weld_seam":     (46,  204, 113),
        "workpiece":     (255, 255, 0),
    ]
    private static let fallback: (CGFloat, CGFloat, CGFloat) = (200, 200, 200)

    /// Large regions get a light wash so the defects on top stay legible.
    private static let structural: Set<String> = ["workpiece", "weld_seam"]
    private static let fillAlpha: CGFloat = 0.35
    private static let structuralAlpha: CGFloat = 0.15

    static func render(base: CGImage, detections: [WeldDetection]) -> Data? {
        let w = base.width, h = base.height
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // structural first so defect masks land on top of them
        let ordered = detections.filter { structural.contains($0.label) }
            + detections.filter { !structural.contains($0.label) }

        for d in ordered where d.maskWidth > 0 {
            let alpha = structural.contains(d.label) ? structuralAlpha : fillAlpha
            guard let layer = maskImage(d, space: space) else { continue }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            // CGContext's origin is bottom-left; the mask grid is top-down.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(layer, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }

        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out).pngData()
    }

    /// One detection's mask as a coloured RGBA image at the mask grid's own
    /// resolution. CGContext.draw upsamples it to the frame; the mask is a
    /// coarse 318x318 either way, so a smooth scale is what we want here --
    /// unlike the model input, where antialiasing would change the answer.
    private static func maskImage(_ d: WeldDetection, space: CGColorSpace) -> CGImage? {
        let (r, g, b) = colors[d.label] ?? fallback
        var rgba = [UInt8](repeating: 0, count: d.maskWidth * d.maskHeight * 4)

        for i in 0..<(d.maskWidth * d.maskHeight) {
            // logits: threshold at 0, equivalent to sigmoid > 0.5
            guard d.mask[i] > 0 else { continue }
            let o = i * 4
            rgba[o] = UInt8(r); rgba[o + 1] = UInt8(g); rgba[o + 2] = UInt8(b)
            rgba[o + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: d.maskWidth, height: d.maskHeight,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: d.maskWidth * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
