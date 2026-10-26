import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Color {

    /// 以 0xRRGGBB 形式构造颜色（等价 Android 的 0xFFxxxxxx 去掉 alpha 位）
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// 与白色按比例混合，得到**不透明**的浅色底。
    ///
    /// Aurora UI 硬规则：需要浅色底一律用这个，不要用 `color.opacity(0.1)` 铺面，
    /// 否则半透明底会把底层阴影透出来，看起来像垫了一块灰方块。
    func tint(_ strength: Double) -> Color {
        let s = max(0, min(1, strength))
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) {
            let mix = { (c: CGFloat) -> Double in Double(c * s + (1 - s)) }
            return Color(
                .sRGB,
                red: mix(r),
                green: mix(g),
                blue: mix(b),
                opacity: Double(a * s + (1 - s))
            )
        }
        #endif
        // 兜底：非 RGB 空间（如 pattern color）无法混色，原样返回
        return self
    }

    /// 十六进制字符串形式的 ARGB（Android 侧对齐用）
    var argbHex: String {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "00000000" }
        return String(
            format: "%02X%02X%02X%02X",
            Int(round(a * 255)), Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255))
        )
        #else
        return "00000000"
        #endif
    }
}
