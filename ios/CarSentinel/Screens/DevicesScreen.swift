import SwiftUI
import UIKit

// === CarSentinel 360 · 附近设备 ===
// 协议 §2：被动收车机 1 秒一次的 UDP 广播，也可以主动发 DISCOVER。
// 另外保留手动输入 IP 的入口（广播被路由器挡掉时用）。

struct DevicesScreen: View {

    @EnvironmentObject var client: CarClient
    @EnvironmentObject var discovery: DiscoveryService
    @State private var manualHost = ""

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
                    emptyState
                } else {
                    deviceList
                }
            }
        }
        .onAppear { discovery.start(); discovery.probe() }
    }

    // MARK: - 空状态：把手动输 IP 提到最显眼处

    /// 自动发现失败时，手动输 IP 才是主路径 —— 尤其是车机挂在手机热点上时
    /// （热点通常不在客户端之间转发 UDP 广播，自动发现必然失效）。
    /// 所以这里不再把输入藏进 alert，直接内联一个输入框。
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: AuroraMetrics.cardSpacing) {
                EmptyStateView(
                    systemIcon: "dot.radiowaves.left.and.right",
                    title: "没有发现车机",
                    message: "如果是手机热点给车机上网，自动发现一般无效，请直接输入车机屏幕上显示的 IP。"
                ) {
                    TonalButton(text: "再扫一次", systemIcon: "arrow.clockwise") {
                        discovery.probe()
                    }
                }

                SectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("手动连接")
                            .font(AuroraFont.titleLarge)
                            .foregroundStyle(Aurora.ink)

                        Text("在车机端「状态」页看「服务地址」，把那串 IP 填在这里。")
                            .font(AuroraFont.bodySmall)
                            .foregroundStyle(Aurora.inkSoft)

                        HStack(spacing: 8) {
                            TextField("192.168.x.x", text: $manualHost)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .font(.system(size: 17, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .background(Aurora.surfaceVariant)
                                .clipShape(RoundedRectangle(cornerRadius: 12,
                                                            style: .continuous))
                                .frame(maxWidth: .infinity)

                            PrimaryButton(
                                text: "连接",
                                expands: false,
                                action: { connectManual() }
                            )
                            .disabled(manualHost.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty)
                            .opacity(manualHost.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                        }

                        if let err = client.lastConnectError {
                            Text(err)
                                .font(AuroraFont.labelSmall)
                                .foregroundStyle(Aurora.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(AuroraMetrics.cardPadding)
                }
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
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

                // 手动输入入口（有自动发现的设备时也保留，作为兜底）
                SectionCard {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("手动输入 IP")
                                .font(AuroraFont.titleMedium)
                                .foregroundStyle(Aurora.ink)
                            Text("手机热点下自动发现通常无效")
                                .font(AuroraFont.bodySmall)
                                .foregroundStyle(Aurora.inkSoft)
                        }
                        Spacer(minLength: 8)
                        SmallTonalButton(text: "输入", systemIcon: "keyboard") {
                            manualHost = ""
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
