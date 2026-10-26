import SwiftUI

// === CarSentinel 360 · 应用入口 ===
// 三个 Tab：实时观看 / 附近设备 / 诊断。
// 设计系统全部来自 Aurora UI（Theme/ + UI/Common/ + UI/Components/）。

@main
struct CarSentinelApp: App {

    @StateObject private var client = CarClient()
    @StateObject private var discovery = DiscoveryService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(discovery)
                .tint(Aurora.brand)
        }
    }
}

private enum AppTab: Hashable {
    case live, devices, diag
}

private struct RootView: View {

    @State private var selected: AppTab = .live

    var body: some View {
        AuroraTabHost(
            selection: $selected,
            items: [
                AuroraTabSpec(id: AppTab.live, title: "实时观看", icon: "video"),
                AuroraTabSpec(id: AppTab.devices, title: "附近设备", icon: "dot.radiowaves.left.and.right"),
                AuroraTabSpec(id: AppTab.diag, title: "诊断", icon: "stethoscope"),
            ]
        ) { tab in
            switch tab {
            case .live: LiveGridScreen()
            case .devices: DevicesScreen()
            case .diag: DiagnosticsScreen()
            }
        }
    }
}
