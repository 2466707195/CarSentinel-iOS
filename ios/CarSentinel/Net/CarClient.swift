import Foundation
import Combine
import CoreMedia

// === CarSentinel 360 · 手机端客户端 ===
// 一条控制通道（TCP/JSON Lines）+ 每路摄像头一条视频通道（TCP/二进制帧）。
// 协议见 docs/PROTOCOL.md。

/// 一路视频会话：独立 TCP 连接 + 独立解码器。
final class VideoSession {

    let cameraId: Int
    private let queue = DispatchQueue(label: "cs.video.\(UUID().uuidString)")
    private var conn: TcpConnection?
    private var running = false
    private let decoder = H264Decoder()

    /// 帧出口。UI 通过 VideoSurfaceView 挂上来。
    weak var sink: VideoFrameSink?

    /// 状态回调（后台线程调用，内部会切主线程）
    var onState: ((CameraStreamState) -> Void)?

    private var state = CameraStreamState() {
        didSet { onState?(state) }
    }

    /// 已重连次数。协议 §6：断了自动重连，但要有上限，否则车机不在线时会永远转。
    private var attempts = 0
    private let maxAttempts = 5
    private let retryDelay: TimeInterval = 1.5

    init(cameraId: Int) {
        self.cameraId = cameraId
        decoder.onSampleBuffer = { [weak self] sb in
            guard let self else { return }
            DispatchQueue.main.async { self.sink?.enqueue(sb) }
        }
    }

    var currentState: CameraStreamState { state }

    func attach(sink: VideoFrameSink, fps: Int) {
        self.sink = sink
        decoder.configure(fps: fps)
    }

    func start(host: String, port: Int) {
        guard !running else { return }
        running = true
        attempts = 0
        state = CameraStreamState(subscribed: true, startedAt: Date())
        queue.async { [weak self] in self?.runLoop(host: host, port: port) }
    }

    func stop() {
        running = false
        conn?.close()
        conn = nil
    }

    /// 带重试的跑法。协议 §6：任一路断开 → 该格显示「信号中断」，控制连接保留，自动重连该路。
    /// 握手被明确拒绝（ERR）不重试 —— 那是车机端说「没这路摄像头」，重试没意义。
    private func runLoop(host: String, port: Int) {
        while running {
            do {
                try runOnce(host: host, port: port)
                return                      // 正常结束（stop() 或被拒绝）
            } catch {
                guard running else { return }
                attempts += 1
                if attempts > maxAttempts {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        var s = self.state
                        s.error = "重连 \(self.maxAttempts) 次仍失败"
                        self.state = s
                    }
                    return
                }
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
    }

    /// 跑一次完整生命周期：连接 → 握手 → 帧循环。抛异常即视为这一路断了。
    private func runOnce(host: String, port: Int) throws {
        defer {
            conn?.close()
            conn = nil
        }
        let c = try TcpConnection(host: host, port: port)
        conn = c
        try c.writeLine("\(CS.subscribePrefix)\(cameraId)")

        // 握手回一行：OK <w> <h> <fps> h264 或 ERR <code> <msg>
        let reply = try c.readLine(maxBytes: 512)
        let parts = reply.split(separator: " ")
        if parts.first == "OK" {
            let w = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let h = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            let fps = parts.count > 3 ? Int(parts[3]) ?? 30 : 30
            decoder.reset()
            decoder.configure(fps: fps)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var s = self.state
                s.width = w; s.height = h; s.fps = fps; s.error = nil
                self.state = s
            }
        } else {
            // 车机端明确拒绝：不重试
            let msg = String(parts.dropFirst().joined(separator: " "))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var s = self.state
                s.error = msg.isEmpty ? "订阅被拒绝" : msg
                self.state = s
            }
            running = false
            return
        }

        // 帧循环
        while running {
            let headerData = try c.readExact(CS.frameHeaderSize)
            // 帧头不对 / 长度离谱，说明这条 TCP 流已经错位了。
            // 绝不能只跳过 24 字节了事 —— 不把 payloadLen 个字节吃掉，
            // 后面每一帧都会跟着错，整条流永久变成垃圾。直接抛，让上层重连。
            guard let fh = FrameHeader.parse(headerData) else {
                throw SocketError.desynchronized
            }
            guard fh.payloadLen > 0, fh.payloadLen < 8 * 1024 * 1024 else {
                throw SocketError.desynchronized
            }
            let payload = try c.readExact(Int(fh.payloadLen))

            // 订阅的是哪一路，就只认哪一路的帧
            guard fh.cameraId == UInt32(cameraId) else { continue }
            decoder.decode(accessUnit: payload)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var s = self.state
                s.frames += 1
                s.bytes += Int64(payload.count)
                s.lastFrameAt = Date()
                s.error = nil
                self.state = s
            }
        }
    }
}

/// 手机端总控。
final class CarClient: ObservableObject {

    @Published private(set) var device: CarDevice?
    @Published private(set) var phase: LinkPhase = .idle
    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var streamStates: [Int: CameraStreamState] = [:]
    @Published private(set) var carStats: CarStats?
    /// 最近一次连接失败的原因，给「附近设备」页显示。
    /// 手动输 IP 时最有用：超时 / 拒绝连接 / 地址不可达，三种原因的修法完全不同。
    @Published private(set) var lastConnectError: String?
    @Published private(set) var logLines: [String] = []

    private var control: TcpConnection?
    private let controlQueue = DispatchQueue(label: "cs.control")
    private var videoSessions: [Int: VideoSession] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var pingCounter = 0
    private var controlRunning = false

    deinit { disconnect() }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    // MARK: - 连接生命周期

    func connect(to device: CarDevice) {
        disconnect()
        lastConnectError = nil
        DispatchQueue.main.async {
            self.device = device
            self.phase = .connecting
            self.cameras = device.cameras
            self.appendLog("正在连接 \(device.host):\(device.port)…")
        }

        controlQueue.async { [weak self] in
            guard let self else { return }
            do {
                let c = try TcpConnection(host: device.host, port: device.port)
                self.control = c
                self.controlRunning = true
                try c.writeLine(JsonLite.hello())

                let welcome = try c.readLine()
                if let cams = JsonLite.camerasFrom(welcome), !cams.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.cameras = cams
                        self?.appendLog("车机报告 \(cams.count) 路摄像头")
                    }
                }

                DispatchQueue.main.async {
                    self.phase = .connected
                    self.appendLog("已连接 \(device.name)")
                }
                self.startTimers()
                self.controlLoop(c)
            } catch {
                // 把原始错误透出，别只让用户看到「连接失败」四个字
                let detail = (error as? SocketError)?.description
                    ?? error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastConnectError = detail
                    self.phase = .failed(detail)
                    self.appendLog("连接失败：\(detail)")
                }
            }
        }
    }

    func disconnect() {
        controlRunning = false
        pingTimer?.cancel(); pingTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        // 协议 §4.1：正常断开要先跟车机说一声 bye
        try? control?.writeLine(JsonLite.bye)
        control?.close(); control = nil
        for s in videoSessions.values { s.stop() }
        videoSessions.removeAll()

        DispatchQueue.main.async {
            self.streamStates.removeAll()
            self.carStats = nil
            if self.phase != .idle {
                self.phase = .idle
                self.device = nil
                self.cameras = []
                self.appendLog("已断开")
            }
        }
    }

    // MARK: - 控制通道读循环

    private func controlLoop(_ c: TcpConnection) {
        while controlRunning {
            do {
                let line = try c.readLine()
                handleControlLine(line)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isConnected {
                        self.phase = .failed("控制通道断开：\(error.localizedDescription)")
                        self.appendLog("控制通道断开")
                    }
                }
                return
            }
        }
    }

    private func handleControlLine(_ line: String) {
        guard let t = JsonLite.typeOf(line) else { return }
        switch t {
        case "welcome", "cameras":
            if let cams = JsonLite.camerasFrom(line), !cams.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.cameras = cams
                    self?.appendLog("摄像头列表：\(cams.map { $0.name }.joined(separator: "、"))")
                }
            }
        case "camera_state":
            if let st = JsonLite.cameraStateFrom(line) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var s = self.streamStates[st.camera] ?? CameraStreamState()
                    s.fps = st.fps
                    self.streamStates[st.camera] = s
                }
            }
        case "stats":
            let cpu = JsonLite.decodeObject(line)?["cpu"] as? Double ?? 0
            let net = JsonLite.intField(line, "netKbps") ?? 0
            let up = JsonLite.intField(line, "uptimeSec") ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.carStats = CarStats(cpu: cpu, netKbps: net, uptimeSec: up)
            }
        case "log":
            if let msg = JsonLite.stringField(line, "msg") {
                DispatchQueue.main.async { [weak self] in self?.appendLog("车机：\(msg)") }
            }
        case "pong":
            break
        case "error":
            let code = JsonLite.intField(line, "code") ?? 0
            let msg = JsonLite.stringField(line, "msg") ?? "未知错误"
            DispatchQueue.main.async { [weak self] in self?.appendLog("车机报错 \(code)：\(msg)") }
        default:
            break
        }
    }

    // MARK: - 定时任务

    private func startTimers() {
        pingTimer?.cancel()
        let pt = DispatchSource.makeTimerSource(queue: controlQueue)
        pt.schedule(deadline: .now() + CS.pingInterval, repeating: CS.pingInterval)
        pt.setEventHandler { [weak self] in
            guard let self, self.controlRunning else { return }
            self.pingCounter += 1
            let n = self.pingCounter
            if let line = try? JsonLite.ping(id: n) {
                try? self.control?.writeLine(line)
            }
        }
        pt.resume()
        pingTimer = pt

        statsTimer?.cancel()
        let st = DispatchSource.makeTimerSource(queue: controlQueue)
        st.schedule(deadline: .now() + 2, repeating: 2)
        st.setEventHandler { [weak self] in
            guard let self, self.controlRunning else { return }
            if let line = try? JsonLite.encode(["t": "stats"]) {
                try? self.control?.writeLine(line)
            }
        }
        st.resume()
        statsTimer = st
    }

    // MARK: - 视频订阅

    func subscribe(camera id: Int, sink: VideoFrameSink) {
        guard let device else { return }
        if let existing = videoSessions[id] {
            existing.attach(sink: sink, fps: existing.currentState.fps > 0 ? existing.currentState.fps : 30)
            return
        }
        if let line = try? JsonLite.subscribe(camera: id) {
            try? control?.writeLine(line)
        }
        let session = VideoSession(cameraId: id)
        session.onState = { [weak self] s in
            DispatchQueue.main.async { self?.streamStates[id] = s }
        }
        videoSessions[id] = session
        session.attach(sink: sink, fps: 30)
        session.start(host: device.host, port: device.port)
    }

    func unsubscribe(camera id: Int) {
        videoSessions[id]?.stop()
        videoSessions.removeValue(forKey: id)
        if let line = try? JsonLite.unsubscribe(camera: id) {
            try? control?.writeLine(line)
        }
        DispatchQueue.main.async { [weak self] in
            self?.streamStates.removeValue(forKey: id)
        }
    }

    func requestKeyframe(camera id: Int) {
        if let line = try? JsonLite.keyframe(camera: id) {
            try? control?.writeLine(line)
        }
    }

    // MARK: - 日志

    func appendLog(_ s: String) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        logLines.insert("\(stamp)  \(s)", at: 0)
        if logLines.count > 200 { logLines.removeLast(logLines.count - 200) }
    }
}

private extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
