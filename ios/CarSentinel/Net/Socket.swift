import Foundation

// === CarSentinel 360 · 原生 socket 封装 ===
// 不用 Network.framework：读「精确 N 字节」这种需求用 recv 循环最直白，
// 而且不需要 run loop，随便丢在哪个 DispatchQueue 上都能跑。
//
// ⚠️ 本类自己有个 `close()` 方法，所以调 C 的 `Darwin.close(fd)` 必须写 `Darwin.close(fd)`，
//    否则编译器认为你在调实例方法。

enum SocketError: Error, CustomStringConvertible {
    case socketFailed
    case resolveFailed(String)
    case connectFailed(String)
    case bindFailed(String)
    case setsockoptFailed(String)
    case closed
    case readFailed(Int32)
    case writeFailed(Int32)
    /// 收包超时（SO_RCVTIMEO 到期）。对发现循环来说是正常心跳，不是错误。
    case receiveTimeout
    /// 帧流错位：帧头魔数不对或长度离谱。只能丢掉整条连接重连。
    case desynchronized

    var description: String {
        switch self {
        case .socketFailed:              return "socket() 创建失败"
        case .resolveFailed(let m):      return "域名解析失败：\(m)"
        case .connectFailed(let m):      return "连接失败：\(m)"
        case .bindFailed(let m):         return "绑定失败：\(m)"
        case .setsockoptFailed(let m):   return "setsockopt 失败：\(m)"
        case .closed:                    return "对端关闭了连接"
        case .readFailed(let e):         return "读取失败 (errno \(e))"
        case .writeFailed(let e):        return "写入失败 (errno \(e))"
        case .receiveTimeout:            return "接收超时"
        case .desynchronized:            return "视频流错位，需要重连"
        }
    }
}

/// TCP 连接。阻塞式读写，**只能在后台队列上用**。
final class TcpConnection {

    private var fd: Int32
    let host: String
    let port: Int

    init(host: String, port: Int) throws {
        self.host = host
        self.port = port
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError.socketFailed }

        let addr = try Self.resolveIPv4(host, port: port)
        let code = withUnsafePointer(to: addr) { p -> Int32 in
            connect(fd, UnsafeRawPointer(p).assumingMemoryBound(to: sockaddr.self),
                    socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard code == 0 else {
            let e = errno
            Darwin.close(fd)
            fd = -1
            throw SocketError.connectFailed("connect \(host):\(port) 失败 (errno \(e))")
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    /// 把 host:port 解析成 IPv4 的 sockaddr_in
    static func resolveIPv4(_ host: String, port: Int) throws -> sockaddr_in {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, String(port), &hints, &result)
        guard code == 0, let first = result else {
            let msg = code == 0 ? "no address" : String(cString: gai_strerror(code))
            throw SocketError.resolveFailed(msg)
        }
        defer { freeaddrinfo(result) }
        guard let addrPtr = first.pointee.ai_addr else {
            throw SocketError.resolveFailed("empty address")
        }
        return addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    /// 精确读 count 字节。对端关闭或出错才抛异常。
    func readExact(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                guard let base = bp.baseAddress else { return -1 }
                return recv(fd, base, want, 0)
            }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                throw SocketError.closed
            } else {
                if errno == EINTR { continue }
                throw SocketError.readFailed(errno)
            }
        }
        return out
    }

    /// 读到 \n 为止（不含换行符）。用于控制通道的 JSON Lines。
    func readLine(maxBytes: Int = CS.maxControlLineBytes) throws -> String {
        var bytes: [UInt8] = []
        while bytes.count < maxBytes {
            var one = [UInt8](repeating: 0, count: 1)
            let n = one.withUnsafeMutableBufferPointer { bp -> Int in
                guard let base = bp.baseAddress else { return -1 }
                return recv(fd, base, 1, 0)
            }
            if n == 1 {
                if one[0] == 0x0A { break }
                bytes.append(one[0])
            } else if n == 0 {
                throw SocketError.closed
            } else {
                if errno == EINTR { continue }
                throw SocketError.readFailed(errno)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw -> Void in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw SocketError.writeFailed(errno)
                }
            }
        }
    }

    func writeLine(_ s: String) throws {
        try writeAll(Data((s + "\n").utf8))
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

/// UDP socket：既能往广播地址发，也能绑端口收。
final class UdpSocket {

    private var fd: Int32

    /// 绑定本地端口。端口传 0 表示让系统分配（只发送时用）。
    /// `receiveTimeoutMs` > 0 时给 socket 设 SO_RCVTIMEO，`receive` 会抛 `.receiveTimeout`。
    init(bindPort: Int, reuseAddr: Bool = true, broadcast: Bool = false, receiveTimeoutMs: Int32 = 0) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError.socketFailed }

        if reuseAddr {
            var one: Int32 = 1
            if setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                throw SocketError.setsockoptFailed("SO_REUSEADDR")
            }
        }
        if broadcast {
            var one: Int32 = 1
            if setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                throw SocketError.setsockoptFailed("SO_BROADCAST")
            }
        }

        if bindPort > 0 {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(bindPort).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
            let code = withUnsafePointer(to: &addr) { p -> Int32 in
                bind(fd, UnsafeRawPointer(p).assumingMemoryBound(to: sockaddr.self),
                     socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            guard code == 0 else {
                let e = errno
                Darwin.close(fd); fd = -1
                throw SocketError.bindFailed("bind :\(bindPort) 失败 (errno \(e))")
            }
        }

        if receiveTimeoutMs > 0 {
            var tv = timeval()
            tv.tv_sec = Int(receiveTimeoutMs) / 1000          // time_t 是 Int
            tv.tv_usec = Int32((receiveTimeoutMs % 1000) * 1000)  // suseconds_t 是 Int32
            if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
                throw SocketError.setsockoptFailed("SO_RCVTIMEO")
            }
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    func send(_ data: Data, to host: String, port: Int) throws {
        let addr = try TcpConnection.resolveIPv4(host, port: port)
        // sendto 返回 Int（ssize_t），不是 Int32
        let code = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: addr) { p -> Int in
                sendto(fd, base, data.count, 0,
                       UnsafeRawPointer(p).assumingMemoryBound(to: sockaddr.self),
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard code == data.count else { throw SocketError.writeFailed(errno) }
    }

    /// 阻塞收一个包。返回数据和来源 IP。缓冲区自己分配，避免 inout 捕获。
    func receive(bufferSize: Int = 4096) throws -> (data: Data, from: String) {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n: Int = buf.withUnsafeMutableBufferPointer { bp -> Int in
            guard let base = bp.baseAddress else { return -1 }
            return withUnsafeMutablePointer(to: &from) { fp -> Int in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                    recvfrom(fd, base, bufferSize, 0, sp, &fromLen)
                }
            }
        }

        if n < 0 {
            if errno == EINTR { return try receive(bufferSize: bufferSize) }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.receiveTimeout }
            throw SocketError.readFailed(errno)
        }

        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = from
        inet_ntop(AF_INET, &addrCopy.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        return (Data(buf[0..<n]), String(cString: ip))
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}
