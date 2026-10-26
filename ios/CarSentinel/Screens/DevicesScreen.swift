import SwiftUI
import UIKit

// === CarSentinel 360 · 附近设备 ===
// 协议 §2：被动收车机 1 秒一次的 UDP 广播，也可以主动发 DISCOVER。
// 另外保留手动输入 IP 的入口（广播被路由器挡掉时用）。

struct DevicesScreen: View {

    @EnvironmentObject var client: CarClient
    @EnvironmentObject var discovery: DiscoveryService
    @State private var manualHost = ""
    @State private var showManual = false

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                AppTopBar(title: "附近设备", subtitle: "同一 WiFi 下自动发现") {
                    Button {
                        discovery.probe()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Aurora.brand)
                            .frame(width: AuroraMetrics.iconButtonSize,
                                   height: AuroraMetrics.iconButtonSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if discovery.devices.isEmpty {
                    EmptyStateView(
                        systemIcon: "dot.radiowaves.left.and.right",
                        title: "没有发现车机",
                        message: "确认手机和车机连的是同一个 WiFi，并且车机端的「车载哨兵」服务已经打开。"
                    ) {
                        TonalButton(text: "再扫一次", systemIcon: "arrow.clockwise") {
                            discovery.probe()
                        }
                    }
                } else {
                    deviceList
                }
            }
        }
        .onAppear { discovery.start(); discovery.probe() }
        .alert("手动连接", isPresented: $showManual) {
            TextField("车机 IP，例如 192.168.1.23", text: $manualHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button("取消", role: .cancel) { manualHost = "" }
            Button("连接") { connectManual() }
        } message: {
            Text("路由器挡掉了 UDP 广播时用这个。端口固定 \(CS.servicePort)。")
        }
    }

    // MARK: - 设备列表

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: AuroraMetrics.cardSpacing) {
                ForEach(discovery.devices) { device in
                    SectionCard {
                        HStack(spacing: 0) {
                            Monogram(name: device.name, tone: Aurora.brand)

                            Spacer().frame(width: 12)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(AuroraFont.titleMedium)
                                    .foregroundStyle(Aurora.ink)
                                    .lineLimit(1)
                                Text("\(device.host):\(device.port)")
                                    .font(AuroraFont.bodySmall)
                                    .foregroundStyle(Aurora.inkSoft)
                                    .lineLimit(1)
                                Spacer().frame(height: 7)
                                StatusPill(
                                    text: "\(device.cameras.count) 路摄像头",
                                    color: device.cameras.isEmpty ? Aurora.warning : Aurora.success
                                )
                            }

                            Spacer(minLength: 8)

                            SmallTonalButton(text: "连接", systemIcon: "video") {
                                client.connect(to: device)
                            }
                        }
                        .padding(.vertical, 13)
                        .padding(.horizontal, 14)
                    }
                }

                // 手动输入入口
                SectionCard {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("手动输入 IP")
                                .font(AuroraFont.titleMedium)
                                .foregroundStyle(Aurora.ink)
                            Text("广播被路由器挡掉时用")
                                .font(AuroraFont.bodySmall)
                                .foregroundStyle(Aurora.inkSoft)
                        }
                        Spacer(minLength: 8)
                        SmallTonalButton(text: "输入", systemIcon: "keyboard") {
                            showManual = true
                        }
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 14)
                }
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
    }

    private func connectManual() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        manualHost = ""
        guard !host.isEmpty else { return }
        let device = CarDevice(
            host: host, port: CS.servicePort, name: "手动设备",
            cameras: [], lastSeen: Date()
        )
        client.connect(to: device)
    }
}
