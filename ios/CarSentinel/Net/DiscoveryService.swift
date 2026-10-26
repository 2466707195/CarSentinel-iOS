import Foundation
import Combine

// === CarSentinel 360 · 设备发现（协议 §2）===
// 被动听 45677 的定时广播 + 主动往 45676 发 DISCOVER。
// 整套跑在一个后台队列上，UI 只读 @Published 的 devices。

final class DiscoveryService: ObservableObject {

    @Published private(set) var devices: [CarDevice] = []

    /// 一台车机多久没再广播就算掉线
    private let deviceTTL: TimeInterval = 3.0

    private let queue = DispatchQueue(label: "cs.discovery", qos: .userInitiated)
    private var stopFlag = false
    private var running = false

    deinit { stop() }

    func start() {
        guard !running else { return }
        running = true
        stopFlag = false
        queue.async { [weak self] in self?.run() }
        probe()
    }

    func stop() {
        stopFlag = true
        running = false
    }

    /// 主动探测一次：往广播地址发 DISCOVER，车机会立刻回一条 announce
    func probe() {
        queue.async { [weak self] in
            // 这里 self 只是用来发一个包，失败无所谓，所以不需要强引用
            guard self != nil else { return }
            do {
                let sock = try UdpSocket(bindPort: 0, reuseAddr: false, broadcast: true)
                defer { sock.close() }
                try sock.send(Data("DISCOVER\n".utf8), to: CS.broadcastAddress, port: CS.probePort)
            } catch {
                // 探测失败不影响被动接收，静默即可
            }
        }
    }

    // MARK: - 接收循环

    private func run() {
        var sock: UdpSocket?
        do {
            // 500ms 收包超时：既能及时响应 stop()，也能周期性清理过期设备
            sock = try UdpSocket(bindPort: CS.announcePort, reuseAddr: true, broadcast: true,
                                 receiveTimeoutMs: 500)
        } catch {
            return
        }
        defer { sock?.close() }

        while !stopFlag {
            let result: (data: Data, from: String)
            do {
                result = try sock!.receive(bufferSize: 4096)
            } catch SocketError.receiveTimeout {
                pruneExpired()
                continue
            } catch {
                pruneExpired()
                continue
            }

            guard let text = String(data: result.data, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let device = JsonLite.parseAnnounce(trimmed, from: result.from) else { continue }

            DispatchQueue.main.async { [weak self] in
                self?.merge(device)
            }
        }
    }

    private func merge(_ incoming: CarDevice) {
        var fresh = incoming
        fresh.lastSeen = Date()
        if let idx = devices.firstIndex(where: { $0.id == fresh.id }) {
            devices[idx] = fresh
        } else {
            devices.append(fresh)
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func pruneExpired() {
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let before = self.devices.count
            self.devices.removeAll { now.timeIntervalSince($0.lastSeen) > self.deviceTTL }
            if self.devices.count != before { /* 触发布局刷新 */ }
        }
    }
}
