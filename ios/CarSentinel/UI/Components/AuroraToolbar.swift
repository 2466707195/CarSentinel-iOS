import SwiftUI

// === Aurora UI · Toolbar 适配层（iOS / SwiftUI）===
//
// iOS 26 起，导航栏和工具栏**自动获得 Liquid Glass**，而且系统会把相邻的
// toolbar 项自动分组、每组共享一块玻璃背景。
// Apple 的官方建议是：**把自定义背景全部删掉**，才能拿到这个效果。
// 所以本文件的策略是：
//   · iOS 26+  → 只统一品牌色，背景交给系统
//   · iOS 16-25 → 铺一层 Aurora 画布色，保持风格一致
//
// 详见 references/ios-components.md

// MARK: - 统一修饰

/// Aurora 工具栏修饰：统一品牌色 + 按版本处理背景。
///
/// ```swift
/// NavigationStack {
///     ContentView()
///         .auroraToolbar()
///         .toolbar {
///             ToolbarItem(placement: .topBarTrailing) { Button("搜索", systemImage: "magnifyingglass") { } }
///         }
/// }
/// ```
extension View {

    func auroraToolbar() -> some View {
        modifier(AuroraToolbarModifier())
    }

    /// 工具栏文字/图标统一用品牌色（等价旧版的 `.accentColor`）
    func auroraToolbarTint() -> some View {
        tint(Aurora.brand)
    }
}

struct AuroraToolbarModifier: ViewModifier {

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // iOS 26：别加背景。加了会把系统的玻璃盖掉，变成一块丑的实色。
            content
                .tint(Aurora.brand)
        } else {
            content
                .tint(Aurora.brand)
                .toolbarBackground(Aurora.canvas, for: .navigationBar)
                .toolbarBackground(Aurora.canvas, for: .bottomBar)
        }
    }
}

// MARK: - ToolbarSpacer（iOS 26+）

/// 工具栏间隔。**只能出现在 `.toolbar { }` 里**，不能当普通视图用
/// （`ToolbarContentBuilder` 只收 `ToolbarContent`）。
@available(iOS 26.0, *)
struct AuroraToolbarSpacer: ToolbarContent {

    private let sizing: SpacerSizing
    private let placement: ToolbarItemPlacement

    /// - Parameters:
    ///   - sizing: `.fixed` 固定宽度 / `.flexible` 把两边顶开
    ///   - placement: 放哪个栏。默认 `.automatic`
    init(_ sizing: SpacerSizing = .fixed, placement: ToolbarItemPlacement = .automatic) {
        self.sizing = sizing
        self.placement = placement
    }

    var body: some ToolbarContent {
        ToolbarSpacer(sizing, placement: placement)
    }
}

// MARK: - 常用图标按钮

/// 工具栏里的标准图标按钮：44pt 命中区，和 Android 版一致。
struct AuroraToolbarIconButton: View {

    private let systemImage: String
    private let accessibilityLabel: String
    private let tint: Color
    private let action: () -> Void

    init(
        _ systemImage: String,
        accessibilityLabel: String,
        tint: Color = Aurora.ink,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: AuroraMetrics.iconButtonSize, height: AuroraMetrics.iconButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
