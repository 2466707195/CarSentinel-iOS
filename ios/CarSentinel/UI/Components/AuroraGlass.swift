import SwiftUI

// === Aurora UI · iOS 26 Liquid Glass 适配层 ===
//
// 设计原则（重要，别改）：
//   Aurora UI 的核心是「**背景可以淡，内容必须实**」。
//   Liquid Glass 是半透明材质，和这条原则天然冲突。
//   所以本文件的约定是：
//     · 卡片（SectionCard）永远实白不透明 —— **不要**给卡片上玻璃
//     · 玻璃只用于**浮动控件层**：悬浮底栏、浮动按钮、悬浮筛选条
//     · iOS 26 以下自动回退到 Aurora 的实白样式，视觉不退化
//
// 用法：
//     AuroraGlassPanel(cornerRadius: 26) { ... }     // 面板：26+ 玻璃，低版本实白
//     SomeView.auroraGlassEffect(in: .capsule)       // 只加玻璃，不改背景
//     AuroraGlassContainer(spacing: 20) { ... }       // 多元素融合
//
// 详见 references/ios-components.md

// MARK: - 玻璃配置

/// Aurora 风格的玻璃配置（iOS 26 才有实际效果，低版本是 no-op）
///
/// 注意：不继承 `Equatable` —— SwiftUI 的 `Color` 不遵守 `Equatable`，
/// 加了会让整个结构体编译不过。这里也不需要比较。
struct AuroraGlassConfig {

    enum Variant: Equatable {
        /// 标准玻璃：平衡的透明度 + 自适应
        case regular
        /// 极清玻璃：高透明度，需要自己垫一层暗化背景，否则内容会看不清
        case clear
    }

    var variant: Variant
    /// 语义色染色。只用于表达含义（主操作 / 状态 / 危险），**别拿来做装饰**
    var tint: Color?
    /// 交互反馈：按压缩放、弹跳、微光（仅 iOS）
    var interactive: Bool

    init(variant: Variant = .regular, tint: Color? = nil, interactive: Bool = false) {
        self.variant = variant
        self.tint = tint
        self.interactive = interactive
    }

    static let regular = AuroraGlassConfig()
    static let clear = AuroraGlassConfig(variant: .clear)
}

/// 转成系统 `Glass`。只能在 iOS 26+ 调用。
@available(iOS 26.0, *)
extension AuroraGlassConfig {
    func makeGlass() -> Glass {
        var g: Glass = (variant == .clear) ? .clear : .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

// MARK: - 玻璃修饰器

extension View {

    /// 给任意视图加 Liquid Glass 效果（iOS 26+ 生效，低版本原样返回）。
    ///
    /// 两条硬规则：
    /// · `glassEffect` 要放在**影响外观的修饰符之后**，否则渲染不对
    /// · 玻璃视图上**不要**再套 `.clipShape()`，玻璃自带形状
    @ViewBuilder
    func auroraGlassEffect<S: Shape>(
        _ config: AuroraGlassConfig = .regular,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(config.makeGlass(), in: shape)
        } else {
            self
        }
    }

    /// 默认胶囊形状的玻璃
    @ViewBuilder
    func auroraGlassEffect(_ config: AuroraGlassConfig = .regular) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(config.makeGlass())
        } else {
            self
        }
    }
}

// MARK: - 玻璃面板

/// 浮动面板：iOS 26+ 用 Liquid Glass，低版本回退到 Aurora 的实白浮层。
///
/// 这是**唯一**推荐的玻璃容器用法 —— 它保证低版本用户的观感不退化。
struct AuroraGlassPanel<Content: View>: View {

    private let content: Content
    private let cornerRadius: CGFloat
    private let config: AuroraGlassConfig

    init(
        cornerRadius: CGFloat = 26,
        config: AuroraGlassConfig = .regular,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.config = config
        self.content = content()
    }

    var body: some View {
        panelContent
    }

    @ViewBuilder
    private var panelContent: some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    config.makeGlass(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: Aurora.barShadow, radius: 10, x: 0, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Aurora.line.opacity(0.55), lineWidth: 1)
                )
        }
    }
}

// MARK: - 玻璃融合容器

/// 多个玻璃元素融合成一个整体。
///
/// 关键点：**玻璃采不到别的玻璃**。要让两个玻璃控件靠近时互相融合 / 变形，
/// 必须放进同一个 `GlassEffectContainer`，只靠 `glassEffect` 是没用的。
///
/// - Parameter spacing: 融合阈值（点）。元素间距小于它就开始融合。
struct AuroraGlassContainer<Content: View>: View {

    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - 玻璃按钮样式

/// 玻璃按钮（iOS 26+）。
///
/// 系统在 iOS 26 提供了 `.glass` / `.glassProminent` 按钮样式；
/// 这里包一层是为了统一到 Aurora 品牌色，并给低版本提供实色回退。
struct AuroraGlassButtonStyle: ButtonStyle {

    private let config: AuroraGlassConfig
    private let cornerRadius: CGFloat

    init(config: AuroraGlassConfig = .regular, cornerRadius: CGFloat = 16) {
        self.config = config
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        buttonBody(configuration: configuration)
    }

    @ViewBuilder
    private func buttonBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .glassEffect(
                    config.makeGlass(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        } else {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(config.tint ?? Aurora.brand)
                )
                .foregroundStyle(Color.white)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}
