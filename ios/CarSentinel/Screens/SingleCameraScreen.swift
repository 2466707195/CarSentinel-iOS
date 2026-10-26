import SwiftUI

// === CarSentinel 360 · 单路全屏 ===
// 从四宫格点某格进来。进入时只保留这一路视频连接，退出时交还给四宫格。

struct SingleCameraScreen: View {

    let cameraId: Int
    let onBack: () -> Void

    @EnvironmentObject var client: CarClient
    // VideoFrameSink 不需要被观察，用 @State 就够（@StateObject 要求 conform ObservableObject）
    @State private var sink = VideoFrameSink()
    @State private var showInfo = true

    private var camera: CameraInfo? {
        client.cameras.first { $0.id == cameraId }
    }

    private var state: CameraStreamState {
        client.streamStates[cameraId] ?? CameraStreamState()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurfaceView(sink: sink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if showInfo { infoBar }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            if let cam = camera {
                client.subscribe(camera: cam.id, sink: sink)
            }
        }
        .onDisappear {
            sink.detach()
            client.unsubscribe(camera: cameraId)
        }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { showInfo.toggle() } }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: AuroraMetrics.iconButtonSize, height: AuroraMetrics.iconButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera?.name ?? "摄像头 \(cameraId)")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(camera?.pos.displayName ?? "")
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 请求关键帧：画面花屏/卡住时点这里
            Button {
                client.requestKeyframe(camera: cameraId)
                client.appendLog("已请求 \(camera?.name ?? "摄像头") 关键帧")
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: AuroraMetrics.iconButtonSize, height: AuroraMetrics.iconButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 底部信息条

    private var infoBar: some View {
        HStack(spacing: 8) {
            pill(text: "\(state.width)×\(state.height)", tone: Aurora.info)
            pill(text: "\(state.fps) fps", tone: Aurora.info)
            pill(text: "\(state.kbps) kbps", tone: Aurora.info)
            pill(text: "\(state.frames) 帧", tone: Aurora.muted)
            Spacer(minLength: 0)
            pill(text: state.isAlive ? "正常" : "中断",
                 tone: state.isAlive ? Aurora.success : Aurora.danger)
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 14)
    }

    private func pill(text: String, tone: Color) -> some View {
        Text(text)
            .font(AuroraFont.labelSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tone.opacity(0.85))
            .clipShape(Capsule())
    }
}
