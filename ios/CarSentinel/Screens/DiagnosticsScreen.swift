import SwiftUI

// === CarSentinel 360 · 诊断 ===
// 链路状态 + 车机负载 + 每路视频的实时计数 + 日志。
// 出问题先看这一页，比猜快得多。

struct DiagnosticsScreen: View {

    @EnvironmentObject var client: CarClient
    @EnvironmentObject var discovery: DiscoveryService

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                AppTopBar(title: "诊断", subtitle: "链路 · 负载 · 日志") {
                    Button {
                        client.appendLog("手动刷新")
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

                AuroraScrollView {
                    linkCard
                    if let stats = client.carStats { statsCard(stats) }
                    if !client.cameras.isEmpty { camerasCard }
                    logCard
                }
            }
        }
    }

    // MARK: - 链路

    private var linkCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("连接")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)

                row(label: "状态", value: phaseText,
                    tone: client.isConnected ? Aurora.success : (failed ? Aurora.danger : Aurora.muted))
                if let device = client.device {
                    row(label: "车机", value: device.name, tone: Aurora.ink)
                    row(label: "地址", value: "\(device.host):\(device.port)", tone: Aurora.ink)
                }
                row(label: "控制端口", value: "\(CS.servicePort)", tone: Aurora.ink)
                row(label: "广播端口", value: "\(CS.announcePort) / 探测 \(CS.probePort)", tone: Aurora.ink)
                row(label: "协议版本", value: "v\(CS.frameVersion) · 帧头 \(CS.frameHeaderSize) 字节", tone: Aurora.ink)
            }
            .padding(AuroraMetrics.cardPadding)
        }
    }

    // MARK: - 车机负载

    private func statsCard(_ s: CarStats) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("车机负载")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)
                row(label: "CPU", value: String(format: "%.0f %%", s.cpu * 100), tone: Aurora.info)
                row(label: "上行", value: "\(s.netKbps) kbps", tone: Aurora.info)
                row(label: "运行", value: durationText(s.uptimeSec), tone: Aurora.muted)
            }
            .padding(AuroraMetrics.cardPadding)
        }
    }

    // MARK: - 每路视频

    private var camerasCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("视频通道")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)

                ForEach(client.cameras) { cam in
                    let st = client.streamStates[cam.id] ?? CameraStreamState()
                    row(
                        label: "\(cam.name)（\(cam.pos.displayName)）",
                        value: st.frames == 0
                            ? (st.error ?? "等待中")
                            : "\(st.width)×\(st.height) · \(st.fps)fps · \(st.kbps) kbps · \(st.frames) 帧",
                        tone: st.isAlive ? Aurora.success : Aurora.danger
                    )
                }
            }
            .padding(AuroraMetrics.cardPadding)
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text("日志")
                        .font(AuroraFont.titleLarge)
                        .foregroundStyle(Aurora.ink)
                    Spacer()
                    Text("\(client.logLines.count) 条")
                        .font(AuroraFont.labelSmall)
                        .foregroundStyle(Aurora.muted)
                }

                if client.logLines.isEmpty {
                    Text("暂无日志")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.muted)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(client.logLines.prefix(60), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Aurora.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(AuroraMetrics.cardPadding)
        }
    }

    // MARK: - 小件

    private var failed: Bool {
        if case .failed = client.phase { return true }
        return false
    }

    private var phaseText: String {
        switch client.phase {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .failed(let m): return "失败：\(m)"
        }
    }

    private func row(label: String, value: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(Aurora.inkSoft)
                .frame(width: 116, alignment: .leading)
            Text(value)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(tone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func durationText(_ sec: Int) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 { return String(format: "%d 小时 %d 分", h, m) }
        if m > 0 { return String(format: "%d 分 %d 秒", m, s) }
        return "\(s) 秒"
    }
}
