import Foundation

// === CarSentinel 360 · 协议常量 ===
// 与 docs/PROTOCOL.md 一一对应。改这里必须同步协议文档和 Android 端。

enum CS {

    // MARK: - 端口（协议 §1）

    /// TCP：控制通道 + 视频通道共用，靠首字节区分
    static let servicePort: Int = 45678
    /// UDP：车机定时广播 announce
    static let announcePort: Int = 45677
    /// UDP：手机主动探测 DISCOVER
    static let probePort: Int = 45676

    static let broadcastAddress = "255.255.255.255"

    // MARK: - 视频帧头（协议 §5.2）

    static let frameMagic: [UInt8] = [0x43, 0x53, 0x36, 0x30]   // "CS60"
    static let frameHeaderSize = 24
    static let frameVersion: UInt8 = 1

    /// flags bit0 = 关键帧
    static let flagKeyFrame: UInt8 = 0x01

    // MARK: - 控制通道（协议 §4）

    /// 单行 JSON 上限
    static let maxControlLineBytes = 64 * 1024
    /// 手机端 ping 周期（秒）
    static let pingInterval: TimeInterval = 5
    /// 车机端控制连接空闲超时（秒）
    static let controlIdleTimeout: TimeInterval = 15

    // MARK: - 视频会话握手（协议 §5.1）

    static let subscribePrefix = "SUBSCRIBE "
}

/// 帧头字段偏移
enum FrameOffset {
    static let magic = 0
    static let version = 4
    static let flags = 5
    static let reserved = 6
    static let cameraId = 8
    static let ptsUs = 12
    static let payloadLen = 20
}

/// 帧头解析结果
struct FrameHeader {
    let cameraId: UInt32
    let flags: UInt8
    let ptsUs: UInt64
    let payloadLen: UInt32

    var isKeyFrame: Bool { (flags & CS.flagKeyFrame) != 0 }

    /// 从 24 字节里按大端解出各字段。调用方需保证 data.count == 24。
    static func parse(_ data: Data) -> FrameHeader? {
        guard data.count == CS.frameHeaderSize else { return nil }
        let b = [UInt8](data)
        guard Array(b[FrameOffset.magic..<FrameOffset.magic + 4]) == CS.frameMagic else { return nil }
        guard b[FrameOffset.version] == CS.frameVersion else { return nil }

        func u32(_ at: Int) -> UInt32 {
            UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
        }
        func u64(_ at: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(b[at + i]) }
            return v
        }

        return FrameHeader(
            cameraId: u32(FrameOffset.cameraId),
            flags: b[FrameOffset.flags],
            ptsUs: u64(FrameOffset.ptsUs),
            payloadLen: u32(FrameOffset.payloadLen)
        )
    }
}
