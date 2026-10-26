import SwiftUI

// === Aurora UI 按钮（iOS / SwiftUI）===
// 硬规则：按钮文字必须居中 —— 统一用 Button + 居中的 label，
// 不要自己拼 HStack 挤文案。

/// 按钮文字：图标 + 文案，整体水平垂直居中。
///
/// - `expands`: 是否撑满父容器宽度。
///   主按钮（底部操作条里成对出现的那种）用 `true`；
///   列表行里的小按钮用 `false`，否则会抢掉整行的空间。
struct AuroraButtonLabel: View {

    let text: String
    var systemIcon: String? = nil
    var height: CGFloat = AuroraMetrics.primaryButtonHeight
    var font: Font = AuroraFont.labelLarge
    var expands: Bool = true

    var body: some View {
        content
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: height)
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(text)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: !expands, vertical: false)
    }
}

/// 主按钮：品牌色实心、白字。
struct PrimaryButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Color.white)
            .background(AuroraShape.button.fill(Aurora.brand))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 次按钮：品牌浅底（primaryContainer）。
struct TonalButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Aurora.onBrandContainer)
            .background(AuroraShape.button.fill(Aurora.brandContainer))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 主 CTA：品牌渐变底、白字。禁用时渐变换成 muted 实色。
///
/// 一个页面最多一个。
struct GradientButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Color.white)
            .background(
                enabled
                    ? AnyShapeStyle(Aurora.brandGradient)
                    : AnyShapeStyle(Aurora.muted)
            )
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
    }
}

/// 小按钮（38pt 高，13pt 圆角）。
struct SmallTonalButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                height: AuroraMetrics.smallButtonHeight,
                font: AuroraFont.labelMedium,
                expands: expands
            )
            .foregroundStyle(Aurora.onBrandContainer)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Aurora.brandContainer)
            )
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 危险操作按钮（玫瑰浅底）。
struct DangerTonalButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Aurora.onRoseContainer)
            .background(AuroraShape.button.fill(Aurora.roseContainer))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 文字按钮（对应 Material 的 TextButton）。
struct TextLinkButton: View {

    let text: String
    var systemIcon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(text)
                    .font(AuroraFont.labelMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(Aurora.brand)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
