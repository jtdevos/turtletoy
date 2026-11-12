import Foundation
import simd

public enum ColorUtils {
    /// Convert Hue [0..360], Saturation [0..100], Lightness [0..100], Alpha [0..1] to linear-ish RGBA
    public static func hsl(_ hDegrees: Double, _ sPercent: Double, _ lPercent: Double, _ alpha: Double = 1.0) -> SIMD4<Float> {
        let h = ((hDegrees.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0) / 360.0
        let s = min(max(sPercent > 1.0 ? sPercent / 100.0 : sPercent, 0.0), 1.0)
        let l = min(max(lPercent > 1.0 ? lPercent / 100.0 : lPercent, 0.0), 1.0)
        let a = Float(min(max(alpha, 0.0), 1.0))

        if s == 0 {
            let v = Float(l)
            return SIMD4<Float>(v, v, v, a)
        }

        let q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
        let p = 2.0 * l - q

        func hueToRGB(_ p: Double, _ q: Double, _ tIn: Double) -> Double {
            var t = tIn
            if t < 0.0 { t += 1.0 }
            if t > 1.0 { t -= 1.0 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }

        let r = Float(hueToRGB(p, q, h + 1.0 / 3.0))
        let g = Float(hueToRGB(p, q, h))
        let b = Float(hueToRGB(p, q, h - 1.0 / 3.0))
        return SIMD4<Float>(r, g, b, a)
    }

    /// Inigo Quilez cosine palette: `a + b * cos(2*pi*(c*t + d))`
    public static func cosinePalette(
        t: Float,
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>,
        d: SIMD3<Float>,
        alpha: Float = 1.0
    ) -> SIMD4<Float> {
        let twoPi: Float = .pi * 2.0
        let angle = twoPi * (c * t + d)
        let rgb = a + b * SIMD3<Float>(cos(angle.x), cos(angle.y), cos(angle.z))
        return SIMD4<Float>(
            min(max(rgb.x, 0.0), 2.0),
            min(max(rgb.y, 0.0), 2.0),
            min(max(rgb.z, 0.0), 2.0),
            alpha
        )
    }

    public static func namedPalette(_ name: String, t: Float, alpha: Float = 1.0) -> SIMD4<Float> {
        switch name.lowercased() {
        case "cyberpunk", "neon", "synth":
            return cosinePalette(
                t: t,
                a: SIMD3<Float>(0.55, 0.45, 0.65),
                b: SIMD3<Float>(0.45, 0.45, 0.35),
                c: SIMD3<Float>(1.0, 1.0, 1.0),
                d: SIMD3<Float>(0.00, 0.33, 0.67),
                alpha: alpha
            )
        case "sakura", "blossom", "cherry":
            return cosinePalette(
                t: t,
                a: SIMD3<Float>(0.85, 0.55, 0.70),
                b: SIMD3<Float>(0.25, 0.35, 0.25),
                c: SIMD3<Float>(1.0, 1.0, 0.5),
                d: SIMD3<Float>(0.80, 0.90, 0.30),
                alpha: alpha
            )
        case "sunset", "fire", "solar":
            return cosinePalette(
                t: t,
                a: SIMD3<Float>(0.65, 0.40, 0.35),
                b: SIMD3<Float>(0.45, 0.40, 0.35),
                c: SIMD3<Float>(1.0, 0.7, 0.4),
                d: SIMD3<Float>(0.00, 0.15, 0.20),
                alpha: alpha
            )
        case "ocean", "aqua", "reef":
            return cosinePalette(
                t: t,
                a: SIMD3<Float>(0.20, 0.60, 0.75),
                b: SIMD3<Float>(0.25, 0.35, 0.25),
                c: SIMD3<Float>(1.0, 1.0, 1.0),
                d: SIMD3<Float>(0.50, 0.60, 0.75),
                alpha: alpha
            )
        case "aurora", "forest", "emerald":
            return cosinePalette(
                t: t,
                a: SIMD3<Float>(0.30, 0.65, 0.55),
                b: SIMD3<Float>(0.30, 0.35, 0.35),
                c: SIMD3<Float>(1.0, 1.0, 0.8),
                d: SIMD3<Float>(0.25, 0.50, 0.70),
                alpha: alpha
            )
        default:
            return hsl(Double(t * 360.0), 85.0, 60.0, Double(alpha))
        }
    }

    public static func parseHexOrName(_ raw: String, alpha: Float = 1.0) -> SIMD4<Float>? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            var value: UInt64 = 0
            guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
            if hex.count == 6 {
                let r = Float((value >> 16) & 0xFF) / 255.0
                let g = Float((value >> 8) & 0xFF) / 255.0
                let b = Float(value & 0xFF) / 255.0
                return SIMD4<Float>(r, g, b, alpha)
            } else if hex.count == 8 {
                let r = Float((value >> 24) & 0xFF) / 255.0
                let g = Float((value >> 16) & 0xFF) / 255.0
                let b = Float((value >> 8) & 0xFF) / 255.0
                let a = Float(value & 0xFF) / 255.0
                return SIMD4<Float>(r, g, b, a * alpha)
            } else if hex.count == 3 {
                let r = Float(((value >> 8) & 0xF) * 17) / 255.0
                let g = Float(((value >> 4) & 0xF) * 17) / 255.0
                let b = Float((value & 0xF) * 17) / 255.0
                return SIMD4<Float>(r, g, b, alpha)
            }
        }

        switch s {
        case "cyan", "aqua": return SIMD4<Float>(0.10, 0.95, 1.00, alpha)
        case "magenta", "pink", "hotpink": return SIMD4<Float>(1.00, 0.20, 0.75, alpha)
        case "violet", "purple": return SIMD4<Float>(0.68, 0.32, 1.00, alpha)
        case "gold", "amber", "yellow": return SIMD4<Float>(1.00, 0.84, 0.20, alpha)
        case "orange", "coral": return SIMD4<Float>(1.00, 0.45, 0.20, alpha)
        case "red", "crimson", "ruby": return SIMD4<Float>(1.00, 0.22, 0.32, alpha)
        case "lime", "green", "emerald", "mint": return SIMD4<Float>(0.20, 0.98, 0.55, alpha)
        case "blue", "azure", "cobalt": return SIMD4<Float>(0.22, 0.58, 1.00, alpha)
        case "white", "snow": return SIMD4<Float>(0.98, 0.98, 1.00, alpha)
        case "black", "ink", "charcoal": return SIMD4<Float>(0.08, 0.09, 0.12, alpha)
        case "sakura", "rose": return SIMD4<Float>(1.00, 0.62, 0.78, alpha)
        case "teal", "turquoise": return SIMD4<Float>(0.12, 0.88, 0.78, alpha)
        default: return nil
        }
    }

    public static func toHex(_ color: SIMD4<Float>) -> String {
        let r = Int(min(max(color.x, 0.0), 1.0) * 255.0)
        let g = Int(min(max(color.y, 0.0), 1.0) * 255.0)
        let b = Int(min(max(color.z, 0.0), 1.0) * 255.0)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
