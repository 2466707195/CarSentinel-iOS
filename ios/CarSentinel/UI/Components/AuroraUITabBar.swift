import SwiftUI
import UIKit

// === Aurora UI · UITabBarController 适配层（UIKit）===
//
// SwiftUI 的 TabView 在 iOS 18 以下不给力，UIKit 的 UITabBarController 反而是最稳的底栏。
// 如果你的工程本来就是 UIKit，用这个文件把底栏统一到 Aurora 风格。
//
// 详见 references/ios-components.md

enum AuroraUITabBarStyle {

    /// Aurora 实白底栏：不透明白 + 1pt 描边 + 品牌色选中态。
    /// 这是 Aurora UI 的默认（符合「内容必须实」原则）。
    case auroraOpaque

    /// 跟随 iOS 26 系统默认（Liquid Glass）。需要 `configureWithDefaultBackground()`，
    /// 并且**不要再设任何背景**，否则会把玻璃盖掉。
    case liquidGlass

    /// 系统默认，不干预
    case system
}

extension UITabBar {

    /// 应用 Aurora 底栏外观。
    ///
    /// ⚠️ 最容易漏的一步：`scrollEdgeAppearance` 也要设。
    ///    不设的话，内容滚到边缘时 UIKit 会把底栏切回默认（半透明），
    ///    看起来「有时白有时灰」。这是最常见的坑。
    func applyAuroraAppearance(_ style: AuroraUITabBarStyle = .auroraOpaque) {
        let appearance = UITabBarAppearance()

        switch style {
        case .auroraOpaque:
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Aurora.surface)
            appearance.backgroundEffect = nil          // 去掉模糊，否则透出底层
            appearance.shadowColor = UIColor(Aurora.line.opacity(0.55))
            appearance.shadowImage = UIImage()

            appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Aurora.inkSoft)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                .foregroundColor: UIColor(Aurora.inkSoft),
                .font: UIFont.systemFont(ofSize: 11, weight: .medium)
            ]
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Aurora.brand)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor(Aurora.brand),
                .font: UIFont.systemFont(ofSize: 11, weight: .medium)
            ]

        case .liquidGlass, .system:
            appearance.configureWithDefaultBackground()
            appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Aurora.inkSoft)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                .foregroundColor: UIColor(Aurora.inkSoft),
                .font: UIFont.systemFont(ofSize: 11, weight: .medium)
            ]
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Aurora.brand)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor(Aurora.brand),
                .font: UIFont.systemFont(ofSize: 11, weight: .medium)
            ]
        }

        standardAppearance = appearance
        scrollEdgeAppearance = appearance     // ← 别漏，见上方注释
        isTranslucent = (style != .auroraOpaque)
    }
}

// MARK: - UITabBarController

extension UITabBarController {

    /// 一键把 Aurora 风格套到底栏上。
    func configureAuroraTabBar(style: AuroraUITabBarStyle = .auroraOpaque) {
        tabBar.applyAuroraAppearance(style)
    }

    /// 设置底部附件（iOS 26+）：类似 Apple Music 的「正在播放」条。
    ///
    /// - Parameter accessoryView: 附件内容视图
    @available(iOS 26.0, *)
    func setAuroraBottomAccessory(_ accessoryView: UIView) {
        let accessory = UITabAccessory(contentView: accessoryView)
        bottomAccessory = accessory
    }

    /// 滚动时收起底栏（iOS 26+）。
    @available(iOS 26.0, *)
    func setAuroraTabBarMinimizeBehavior(_ behavior: UITabBarController.MinimizeBehavior = .onScrollDown) {
        tabBarMinimizeBehavior = behavior
    }
}

// MARK: - 全局关掉 Liquid Glass

enum AuroraLiquidGlassMode {

    /// Info.plist 的 key。设为 YES 可让 iOS 26 回退到旧外观。
    static let compatibilityKey = "UIDesignRequiresCompatibility"

    /// 在 Info.plist 里加 `UIDesignRequiresCompatibility = YES`。
    ///
    /// ⚠️ **只在 iOS 26 有效，iOS 27 起被忽略**（Apple 已把它当过渡开关）。
    ///    不要把它当长期方案 —— 该适配的还是得适配。
    static func disableLiquidGlassInInfoPlist() {
        print("""
        [Aurora UI] 在 Info.plist 里加：
            <key>UIDesignRequiresCompatibility</key>
            <true/>
        注意：仅 iOS 26 有效，iOS 27 起忽略。
        """)
    }
}
