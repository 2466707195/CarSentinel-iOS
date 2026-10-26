import Foundation

// === CarSentinel 360 · 共享数据模型 ===
// 字段名与 docs/PROTOCOL.md 严格一致。改这里必须同时改协议文档和 Android 端。

/// 摄像头安装位置。协议 §2.1 `cameras[].pos`
enum CameraPosition: String {
    case front, rear, left, right, inner, unknown

    var displayName: String {
        switch self {
        case .front:   return "前视"
        case .rear:    return "后视"
        case .left:    return "左侧"
        case .right:   return "右侧"
        case .inner:   return "车内"
        case .unknown: return "未知"
        }
    }

    /// 四宫格里的默认排位：前 后 左 右。未知的排最后。
    var gridOrder: Int {
        switch self {
        case .front:  return 0
        case .rear:   return 1
        case .left:   return 2
        case .right:  return 3
        case .inner:  return 4
        case .unknown: return 5
        }
    }
}

/// 一路摄像头。协议 §2.1 `cameras[]`
struct CameraInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var pos: CameraPosition
    var width: Int
    var height: Int

    init(id: Int, name: String, pos: CameraPosition, width: Int = 0, height: Int = 0) {
        self.id = id
        self.name = name
        self.pos = pos
        self.width = width
        self.height = height
    }

    var resolutionText: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : "分辨率未知"
    }
}

/// 一台被发现的车机。协议 §2.1 announce 的解析结果。
struct CarDevice: Identifiable, Equatable {
    let host: String
    let port: Int
    var name: String
    var cameras: [CameraInfo]
    var lastSeen: Date

    var id: String { "\(host):\(port)" }

    init(host: String, port: Int, name: String, cameras: [CameraInfo], lastSeen: Date = Date()) {
        self.host = host
        self.port = port
        self.name = name
        self.cameras = cameras
        self.lastSeen = lastSeen
    }
}

/// 一路视频连接的实时状态，给 UI 显示用。
struct CameraStreamState: Equatable {
    var subscribed = false
    var width = 0
    var height = 0
    var fps = 0
    var frames = 0
    var bytes = Int64(0)
    var lastFrameAt: Date?
    var error: String?

    var kbps: Int {
        guard let first = startedAt, bytes > 0 else { return 0 }
        let secs = max(Date().timeIntervalSince(first), 0.5)
        return Int(Double(bytes) * 8.0 / 1000.0 / secs)
    }

    var startedAt: Date?

    var isAlive: Bool {
        guard let t = lastFrameAt else { return false }
        return Date().timeIntervalSince(t) < 3.0
    }
}

/// 车机整体状态。协议 §4.2 `stats`
struct CarStats: Equatable {
    var cpu: Double = 0
    var netKbps: Int = 0
    var uptimeSec: Int = 0
}

/// 控制连接的阶段。
enum LinkPhase: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}
