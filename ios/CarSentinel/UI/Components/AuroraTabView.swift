import SwiftUI

// === Aurora UI · Tab 页容器（iOS / SwiftUI）===
//
// 提供两套实现，按系统版本自动选：
//   · iOS 18+   → 原生 `TabView` + `Tab`（iOS 26 上自动获得 Liquid Glass）
//   · iOS 16/17 → 自绘悬浮底栏（和 Android 版视觉一致）
//
// 为什么不只用原生 TabView：
//   原生 TabView 从 iOS 18 才有 `Tab` 这个可用 API；16.4 的部署目标下必须留一条自绘退路。
//   而且 Aurora UI 的底栏是「实白胶囊 + 选中项浅品牌底」，原生样式在低版本上对不上。
//
// 详见 references/ios-components.md

// MARK: - 共享 spec

/// Tab 项描述。`Value` 通常是业务枚举。
struct AuroraTabSpec<Value: Hashable>: Identifiable {

    let id: Value
    let title: String

    /// 未选中图标。**必须用 outline 变体** ——
    /// 原生 TabView 会自动把选中态换成 filled 变体，这里再给 filled 会导致常亮。
    let icon: String

    /// 选中图标（仅 iOS 16/17 的自绘底栏用，原生 TabView 忽略）
    let selectedIcon: String

    /// 角标文案。`nil` 或空串都不显示。
    let badge: String?

    init(
        id: Value,
        title: String,
        icon: String,
        selectedIcon: String? = nil,
        badge: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.selectedIcon = selectedIcon
            ?? (icon.hasSuffix(".fill") ? icon : icon + ".fill")
        self.badge = badge
    }
}

// MARK: - 原生实现（iOS 18+）

@available(iOS 18.0, *)
struct AuroraTabView<Value: Hashable, Content: View>: View {

    @Binding private var selection: Value
    private let items: [AuroraTabSpec<Value>]
    private let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                Tab(value: item.id, role: nil) {
                    content(item.id)
                } label: {
                    // 用 Label 而不是 Tab("标题", systemImage:) ——
                    // 后者首参是字面量友好的签名，传 String 变量不稳
                    Label(item.title, systemImage: item.icon)
                }
            }
        }
        // 选中态染成品牌色；图标、文字都会跟着变
        .tint(Aurora.brand)
    }
}

// MARK: - 关于角标（badge）
//
// 原生 Tab 路径**不支持条件性角标**，两个原因：
//   1. `Tab` 不是 `View`（没有 `.modifier`），所以不能用 ViewModifier 包一层条件。
//   2. `TabContent.badge(_:)` 的返回类型是 `some TabContent<Self.TabValue>` —— 不透明类型。
//      写 `if hasBadge { tab.badge(x) } else { tab }` 时两个分支底层类型不同，
//      无法收敛到同一个 opaque type，编译器直接报错。
//
// 变通办法：
//   · 要角标就在 TabView 那里直接 `.badge("3")` 写死（无条件的）
//   · 或者走 iOS 16/17 的自绘底栏 `AuroraLegacyTabBar` —— 它是普通 HStack，
//     角标想怎么画怎么画（`AuroraTabSpec.badge` 就是给它用的）
//   · 或者自己维护一个 UITabBarController 包在 UIViewControllerRepresentable 里，
//     用 `tabBarItem.badgeValue` 完全控制

// MARK: - 自绘底栏（iOS 16/17 退路）

/// iOS 16/17 用的自绘底栏：实白胶囊 + 选中项浅品牌底，和 Android 版视觉一致。
struct AuroraLegacyTabBar<Value: Hashable, Content: View>: View {

    @Binding var selection: Value
    let items: [AuroraTabSpec<Value>]
    let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                content(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selection = item.id }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: item.id == selection ? item.selectedIcon : item.icon)
                                .font(.system(size: 18))
                                .frame(width: 32, height: 26)
                                .background(
                                    Circle().fill(item.id == selection ? Aurora.brand.tint(0.13) : Color.clear)
                                )
                            Text(item.title)
                                .font(AuroraFont.labelSmall)
                                .lineLimit(1)
                            if let badge = item.badge, !badge.isEmpty {
                                Text(badge)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Aurora.rose))
                                    .offset(y: -4)
                            }
                        }
                        .foregroundStyle(item.id == selection ? Aurora.brand : Aurora.inkSoft)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                AuroraShape.bar
                    .fill(Color.white)
                    .shadow(color: Aurora.barShadow, radius: 10, x: 0, y: 4)
            )
            .overlay(AuroraShape.bar.stroke(Aurora.line.opacity(0.55), lineWidth: 1))
            .contentShape(AuroraShape.bar)
            .onTapGesture { }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - 统一入口

/// Tab 页宿主：按系统版本自动选原生 TabView 或自绘底栏。
///
/// ```swift
/// AuroraTabHost(selection: $tab, items: [
///     AuroraTabSpec(id: AppTab.home, title: "首页", icon: "house"),
///     AuroraTabSpec(id: AppTab.drive, title: "网盘", icon: "cloud"),
/// ]) { tab in
///     switch tab { ... }
/// }
/// ```
struct AuroraTabHost<Value: Hashable, Content: View>: View {

    @Binding private var selection: Value
    private let items: [AuroraTabSpec<Value>]
    private let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            AuroraTabView(selection: $selection, items: items, content: content)
        } else {
            AuroraLegacyTabBar(selection: $selection, items: items, content: content)
        }
    }
}
