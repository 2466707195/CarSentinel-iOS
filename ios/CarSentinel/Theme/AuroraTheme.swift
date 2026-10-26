import SwiftUI

// === Aurora UI 设计 token（iOS / SwiftUI）===
// 与 Android 版 `ui/theme/Theme.kt` 一一对应，数值完全一致。

enum Aurora {

    // MARK: - 品牌三色

    static let brand = Color(hex: 0x4F46E5)        // 主色：主按钮、选中态、强调文字、进度条
    static let brandDeep = Color(hex: 0x3730C0)    // 渐变起点、按下态
    static let teal = Color(hex: 0x0F9D9D)         // 正常/成功的辅助色
    static let rose = Color(hex: 0xD6336C)         // 提醒、警示、删除类操作

    // MARK: - 中性色

    static let canvas = Color(hex: 0xF8F7FC)       // 画布（近白、微冷）
    static let surface = Color.white               // 卡片（**不透明**）
    static let ink = Color(hex: 0x17171F)          // 主文字
    static let inkSoft = Color(hex: 0x5C5C70)      // 次文字
    static let line = Color(hex: 0xE7E5F0)         // 描边
    static let surfaceVariant = Color(hex: 0xEFEDF7)
    static let outline = Color(hex: 0xC6C3D6)

    // MARK: - 容器色（Material 3 primary/secondary/tertiary container）

    static let brandContainer = Color(hex: 0xE5E2FF)
    static let onBrandContainer = Color(hex: 0x1B1464)
    static let tealContainer = Color(hex: 0xCAF2F1)
    static let onTealContainer = Color(hex: 0x003737)
    static let roseContainer = Color(hex: 0xFFD9E3)
    static let onRoseContainer = Color(hex: 0x3E0021)

    // MARK: - 语义色（M3 之外额外需要的）

    static let success = Color(hex: 0x11875A)
    static let successContainer = Color(hex: 0xD8F5E8)
    static let warning = Color(hex: 0xB26A00)
    static let warningContainer = Color(hex: 0xFFEDCB)
    static let info = Color(hex: 0x2563EB)
    static let infoContainer = Color(hex: 0xDDE8FF)
    static let muted = Color(hex: 0x8A8AA0)
    static let hairline = Color(hex: 0xEFEDF6)
    static let danger = Color(hex: 0xC62828)

    // MARK: - 渐变（仅用于主 CTA 底色）

    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x5B54F0), Color(hex: 0x8B5CF6)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - 阴影

    static let cardShadow = Color.black.opacity(0.05)
    static let barShadow = Color(red: 0.06, green: 0.06, blue: 0.16).opacity(0.10)
}

// MARK: - 字阶

/// 中文优先：层级靠字重拉开，不靠字号堆叠；中文标题带负字距，视觉更紧实。
/// 负字距用 SwiftUI 的 `tracking` 表达（单位 pt，等价 Android 的 sp 偏移）。
enum AuroraFont {

    static let headlineMedium = Font.system(size: 28, weight: .bold)
    static let headlineSmall = Font.system(size: 24, weight: .bold)
    static let titleLarge = Font.system(size: 19, weight: .bold)
    static let titleMedium = Font.system(size: 16, weight: .semibold)
    static let titleSmall = Font.system(size: 14, weight: .semibold)
    static let bodyLarge = Font.system(size: 15, weight: .regular)
    static let bodyMedium = Font.system(size: 14, weight: .regular)
    static let bodySmall = Font.system(size: 12.5, weight: .regular)
    static let labelLarge = Font.system(size: 14, weight: .semibold)
    static let labelMedium = Font.system(size: 12, weight: .semibold)
    static let labelSmall = Font.system(size: 11, weight: .medium)
}

// MARK: - 间距与尺寸（8pt 网格）

enum AuroraMetrics {
    static let pagePadding: CGFloat = 14      // 页面左右边距
    static let cardPadding: CGFloat = 16      // 卡片内边距
    static let cardSpacing: CGFloat = 10      // 卡片间距
    static let listBottomInset: CGFloat = 168 // 列表底部留白（避开底部操作条）
    static let barBottomInset: CGFloat = 68   // 底部导航条占用的高度（含留白）
    static let primaryButtonHeight: CGFloat = 50
    static let smallButtonHeight: CGFloat = 38
    static let iconButtonSize: CGFloat = 44
}

// MARK: - 形状

enum AuroraShape {
    static let control = RoundedRectangle(cornerRadius: 14, style: .continuous) // 表单控件 / 小按钮
    static let button = RoundedRectangle(cornerRadius: 16, style: .continuous)  // 主按钮
    static let card = RoundedRectangle(cornerRadius: 20, style: .continuous)     // 卡片
    static let sheet = RoundedRectangle(cornerRadius: 24, style: .continuous)    // 弹窗
    static let bar = RoundedRectangle(cornerRadius: 26, style: .continuous)      // 底部操作条
    static let badge = RoundedRectangle(cornerRadius: 12, style: .continuous)    // 小方块
}

// MARK: - 状态等级 → 颜色

/// 1=信息 2=成功 3=警告 4=错误 其他=中性
func statusColor(_ level: Int) -> Color {
    switch level {
    case 1: return Aurora.info
    case 2: return Aurora.success
    case 3: return Aurora.warning
    case 4: return Aurora.danger
    default: return Aurora.muted
    }
}

// MARK: - 按压反馈

/// 卡片按下时轻微缩放，给实体感。
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.982

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
