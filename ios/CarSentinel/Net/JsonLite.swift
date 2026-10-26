import Foundation

// === CarSentinel 360 · 极简 JSON 编解码 ===
// 协议只有一种嵌套：announce 里 cameras 是「扁平对象的数组」。
// 用系统的 JSONSerialization 就够，不引第三方库。

enum JsonLite {

    /// 把任意 JSON 对象序列化成一行（供控制通道发送）。
    static func encode(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        guard let s = String(data: data, encoding: .utf8) else { throw SocketError.writeFailed(-1) }
        return s
    }

    /// 解析一行 JSON。失败返回 nil（调用方按「坏行」跳过）。
    static func decodeObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
    }

    // MARK: - announce 解析（协议 §2.1）

    /// 解析车机的 announce 广播。
    static func parseAnnounce(_ line: String, from host: String, port: Int = CS.servicePort) -> CarDevice? {
        guard let root = decodeObject(line) else { return nil }
        guard (root["t"] as? String) == "announce" else { return nil }
        // 协议版本必须对得上。对不上还按 v1 解析，后面全是错位的垃圾。
        // 允许字段缺失（宽容），但不允许版本号更大。
        if let v = root["v"] as? Int, v > CS.frameVersion { return nil }
        guard let name = root["name"] as? String, !name.isEmpty else { return nil }
        guard let svcPort = root["port"] as? Int else { return nil }

        var cameras: [CameraInfo] = []
        if let raw = root["cameras"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? Int else { continue }
                let cname = (c["name"] as? String) ?? "摄像头 \(id)"
                let posRaw = c["pos"] as? String ?? "unknown"
                let pos = CameraPosition(rawValue: posRaw) ?? .unknown
                cameras.append(CameraInfo(
                    id: id,
                    name: cname,
                    pos: pos,
                    width: c["w"] as? Int ?? 0,
                    height: c["h"] as? Int ?? 0
                ))
            }
        }
        // 四宫格按前/后/左/右排序，未知位置排最后（协议 §6）
        cameras.sort { $0.pos.gridOrder != $1.pos.gridOrder
            ? $0.pos.gridOrder < $1.pos.gridOrder
            : $0.id < $1.id }
        return CarDevice(host: host, port: svcPort, name: name, cameras: cameras)
    }

    // MARK: - 控制消息构造（协议 §4.1）

    static func hello() throws -> String {
        try encode(["t": "hello", "role": "phone", "v": 1])
    }

    static func list() throws -> String { try encode(["t": "list"]) }

    static func subscribe(camera id: Int) throws -> String {
        try encode(["t": "subscribe", "camera": id])
    }

    static func unsubscribe(camera id: Int) throws -> String {
        try encode(["t": "unsubscribe", "camera": id])
    }

    static func keyframe(camera id: Int) throws -> String {
        try encode(["t": "keyframe", "camera": id])
    }

    static func ping(id: Int) throws -> String { try encode(["t": "ping", "id": id]) }

    static let bye = "{\"t\":\"bye\"}"

    // MARK: - 控制消息字段读取

    static func typeOf(_ line: String) -> String? {
        decodeObject(line)?["t"] as? String
    }

    static func intField(_ line: String, _ key: String) -> Int? {
        decodeObject(line)?[key] as? Int
    }

    static func stringField(_ line: String, _ key: String) -> String? {
        decodeObject(line)?[key] as? String
    }

    /// 从 cameras / welcome 消息里取摄像头列表
    static func camerasFrom(_ line: String) -> [CameraInfo]? {
        guard let root = decodeObject(line) else { return nil }
        guard let raw = root["cameras"] as? [[String: Any]] else { return nil }
        var out: [CameraInfo] = []
        for c in raw {
            guard let id = c["id"] as? Int else { continue }
            let cname = (c["name"] as? String) ?? "摄像头 \(id)"
            let pos = CameraPosition(rawValue: c["pos"] as? String ?? "unknown") ?? .unknown
            out.append(CameraInfo(id: id, name: cname, pos: pos,
                                  width: c["w"] as? Int ?? 0, height: c["h"] as? Int ?? 0))
        }
        out.sort { $0.pos.gridOrder != $1.pos.gridOrder
            ? $0.pos.gridOrder < $1.pos.gridOrder
            : $0.id < $1.id }
        return out
    }

    /// 从 camera_state 消息里取某路的状态
    static func cameraStateFrom(_ line: String) -> (camera: Int, active: Bool, fps: Int, bitrateKbps: Int)? {
        guard let root = decodeObject(line) else { return nil }
        guard let id = root["camera"] as? Int else { return nil }
        return (id,
                root["active"] as? Bool ?? false,
                root["fps"] as? Int ?? 0,
                root["bitrateKbps"] as? Int ?? 0)
    }
}
