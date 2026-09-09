// Reading an MLMultiArray without assuming anything about it.
//
// The previous version did this:
//
//     let p = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
//     let v = p[i * cols + j]
//
// which quietly assumes float32, standard row-major strides, and a CPU-backed
// contiguous buffer. Core ML guarantees none of those. With
// `computeUnits = .all` the ANE commonly returns Float16 even from an
// fp32-exported model, and reading Float16 pairs as Float32 does not crash --
// it yields values near zero, so every sigmoid comes back at ~0.5 and every
// detection looks equally confident.
//
// So: check the dtype, honour the strides, and use withUnsafeBytes rather than
// the deprecated dataPointer.

import CoreML
import Foundation

enum MLTensor {

    // MARK: - dtype

    static func typeName(_ t: MLMultiArrayDataType) -> String {
        switch t {
        case .double:  return "float64"
        case .float32: return "float32"
        case .float16: return "float16"
        case .int32:   return "int32"
        @unknown default: return "unknown(\(t.rawValue))"
        }
    }

    static func byteWidth(_ t: MLMultiArrayDataType) -> Int {
        switch t {
        case .double:  return 8
        case .float32: return 4
        case .float16: return 2
        case .int32:   return 4
        @unknown default: return 4
        }
    }

    /// IEEE half -> single, done by hand rather than via Swift's `Float16`,
    /// which is not available on every architecture this may be built for.
    @inline(__always)
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp  = UInt32((h >> 10) & 0x1F)
        let man  = UInt32(h & 0x03FF)

        if exp == 0 {
            if man == 0 { return Float(bitPattern: sign) }      // +/- zero
            // subnormal: renormalise
            var m = man
            var e: UInt32 = 0
            while m & 0x0400 == 0 { m <<= 1; e += 1 }
            m &= 0x03FF
            return Float(bitPattern: sign | ((113 - e) << 23) | (m << 13))
        }
        if exp == 0x1F {                                        // inf / nan
            return Float(bitPattern: sign | 0x7F80_0000 | (man << 13))
        }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (man << 13))
    }

    @inline(__always)
    static func element(_ base: UnsafeRawPointer,
                        _ index: Int,
                        _ type: MLMultiArrayDataType) -> Float {
        switch type {
        case .float32:
            return base.load(fromByteOffset: index * 4, as: Float.self)
        case .float16:
            return halfToFloat(base.load(fromByteOffset: index * 2, as: UInt16.self))
        case .double:
            return Float(base.load(fromByteOffset: index * 8, as: Double.self))
        case .int32:
            return Float(base.load(fromByteOffset: index * 4, as: Int32.self))
        @unknown default:
            return 0
        }
    }

    // MARK: - reading

    /// Whole array as Float in logical row-major order, dtype and strides
    /// honoured. For the small outputs (boxes, logits) only -- a 100x318x318
    /// mask tensor would be 40 MB of Float, so use `gather` for those.
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)
        let type = a.dataType
        let total = shape.reduce(1, *)

        var out = [Float](repeating: 0, count: total)
        a.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // walk logical indices, convert to a strided offset
            var idx = [Int](repeating: 0, count: shape.count)
            for flat in 0..<total {
                var offset = 0
                for d in 0..<shape.count { offset += idx[d] * strides[d] }
                out[flat] = element(base, offset, type)

                var d = shape.count - 1
                while d >= 0 {
                    idx[d] += 1
                    if idx[d] < shape[d] { break }
                    idx[d] = 0
                    d -= 1
                }
            }
        }
        return out
    }

    /// One `[query]` plane of a rank-4 `(1, Q, H, W)` tensor, as Float.
    static func gather(_ a: MLMultiArray, query: Int) -> [Float] {
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)
        guard shape.count == 4 else { return [] }
        let h = shape[2], w = shape[3]
        let type = a.dataType

        var out = [Float](repeating: 0, count: h * w)
        a.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let planeStart = query * strides[1]
            for y in 0..<h {
                let rowStart = planeStart + y * strides[2]
                let rowOut = y * w
                for x in 0..<w {
                    out[rowOut + x] = element(base, rowStart + x * strides[3], type)
                }
            }
        }
        return out
    }

    // MARK: - diagnostics

    /// Everything needed to tell a dtype problem from a stride problem from a
    /// bad pointer, in one line per tensor.
    static func describe(_ name: String, _ a: MLMultiArray) -> String {
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)

        // what the strides WOULD be if the array were plain row-major
        var expected = [Int](repeating: 1, count: shape.count)
        for d in stride(from: shape.count - 2, through: 0, by: -1) {
            expected[d] = expected[d + 1] * shape[d + 1]
        }
        let contiguous = strides == expected

        var line = "[RFDetr] \(name): \(typeName(a.dataType)) shape \(shape) "
            + "strides \(strides)\(contiguous ? "" : "  <-- NOT ROW-MAJOR") "
            + "count \(a.count)"

        // sample without materialising the whole thing
        let n = min(8, a.count)
        var head: [Float] = []
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        var sum: Double = 0
        var nonZero = 0
        let probe = min(a.count, 20_000)

        a.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<n { head.append(element(base, i, a.dataType)) }
            for i in 0..<probe {
                let v = element(base, i, a.dataType)
                lo = min(lo, v); hi = max(hi, v); sum += Double(v)
                if v != 0 { nonZero += 1 }
            }
        }

        let fmt = head.map { String(format: "%.4g", $0) }.joined(separator: " ")
        line += "\n[RFDetr]   first \(n): [\(fmt)]"
        line += String(format: "\n[RFDetr]   over %d flat elems: min %.5g  max %.5g  mean %.5g  nonzero %d/%d",
                       probe, lo, hi, sum / Double(max(probe, 1)), nonZero, probe)
        if nonZero == 0 {
            line += "\n[RFDetr]   !! ALL ZERO — the buffer being read was never written"
        }
        return line
    }
}
