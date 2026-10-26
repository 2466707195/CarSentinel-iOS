import SwiftUI

// === CarSentinel 360 · 实时观看（四宫格）===
// 协议 §6：四宫格最多 4 格；cameras 少于 4 路时只显示实际路数；
// 点某格 → 单路全屏；任一路断开 → 该格显示「信号中断」浮层，控制连接保留。

struct LiveGridScreen: View {

    @EnvironmentObject var client: CarClient
    @State private var fullScreenCamera: Int?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ZStack {
            AuroraBackdrop()

            if client.isConnected {
                VStack(spacing: 0) {
                    AppTopBar(
                        title: "实时观看",
                        subtitle: client.device?.name ?? "已连接"
                    ) {
                        Button {
                            client.disconnect()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Aurora.inkSoft)
                                .frame(width: AuroraMetrics.iconButtonSize,
                                       height: AuroraMetrics.iconButtonSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    grid
                }
            } else {
                notConnected
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenCamera != nil },
            set: { if !$0 { fullScreenCamera = nil } }
        )) {
            if let id = fullScreenCamera {
                SingleCameraScreen(cameraId: id) { fullScreenCamera = nil }
                    .environmentObject(client)
            }
        }
    }

    // MARK: - 四宫格

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(client.cameras) { cam in
                    CameraTile(camera: cam, client: client) {
                        fullScreenCamera = cam.id
                    }
                }
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, AuroraMetrics.listBottomInset)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - 未连接

    private var notConnected: some View {
        VStack(spacing: 0) {
            AppTopBar(title: "实时观看", subtitle: "CarSentinel 360 · 手机端")
            Spacer()
            EmptyStateView(
                systemIcon: "video.slash",
                title: "还没有连接车机",
                message: "到「附近设备」里选一台车机，或者手动输入它的 IP 地址。"
            ) {
                TonalButton(text: "去找设备", systemIcon: "list.bullet") {
                    client.appendLog("请切换到「附近设备」标签页")
                }
            }
            Spacer()
        }
    }
}

// MARK: - 单格

private struct CameraTile: View {

    let camera: CameraInfo
    @ObservedObject var client: CarClient
    let onTap: () -> Void

    // VideoFrameSink 不需要被观察，用 @State 就够（@StateObject 要求 conform ObservableObject）
    @State private var sink = VideoFrameSink()

    private var state: CameraStreamState {
        client.streamStates[camera.id] ?? CameraStreamState()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoSurfaceView(sink: sink)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            // 顶部信息条
            HStack(spacing: 6) {
                Text(camera.name)
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())

                Spacer(minLength: 4)

                Text(state.isAlive ? "\(state.kbps) kbps" : "中断")
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((state.isAlive ? Aurora.success : Aurora.danger).opacity(0.85))
                    .clipShape(Capsule())
            }
            .padding(8)

            if !state.isAlive {
                // 信号中断浮层：整块吞点击
                VStack(spacing: 6) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 22))
                    Text("信号中断")
                        .font(AuroraFont.labelMedium)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onTap() }
        .onAppear {
            client.subscribe(camera: camera.id, sink: sink)
        }
        .onDisappear {
            sink.detach()
            client.unsubscribe(camera: camera.id)
        }
    }
}
