package com.carsentinel.carunit.net

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.NetworkInterface
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean

/**
 * UDP 发现：
 *  - 每 1000ms 向 255.255.255.255:45677 广播 announce
 *  - 在 45676 上监听 "DISCOVER\n"，收到后**立即**单播回一条 announce（不等周期）
 */
class Announcer(
    private val deviceName: String,
    private val camerasProvider: () -> List<CameraInfo>,
    private val logs: LogBus
) {
    companion object Factory {
        private const val TAG = "Announcer"
        private const val MAX_NAME = 32

        fun buildAnnounce(name: String, cameras: List<CameraInfo>): String {
            val o = Json.Obj()
            o.put("t", "announce")
            o.put("v", Protocol.VERSION)
            o.put("name", if (name.length > MAX_NAME) name.take(MAX_NAME) else name)
            o.put("port", Protocol.TCP_PORT)
            o.put("cameras", cameras.map { c ->
                Json.Obj()
                    .put("id", c.id)
                    .put("name", c.name)
                    .put("pos", c.pos)
                    .put("w", c.w)
                    .put("h", c.h)
            })
            o.put("caps", listOf("h264"))
            return o.toString()
        }
    }

    private val running = AtomicBoolean(false)
    private var broadcastThread: Thread? = null
    private var listenThread: Thread? = null
    private var bcastSocket: DatagramSocket? = null
    private var listenSocket: DatagramSocket? = null

    /** 摄像头集合变化时置位，下一轮广播用新 JSON */
    @Volatile
    private var dirty = true

    @Volatile
    private var cachedJson: String = ""

    fun markDirty() {
        dirty = true
    }

    fun announceJson(): String {
        if (dirty || cachedJson.isEmpty()) {
            cachedJson = buildAnnounce(deviceName, camerasProvider())
            dirty = false
        }
        return cachedJson
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        announceJson()
        logs.info("UDP 发现已启动：广播 $Protocol.UDP_ANNOUNCE_PORT，监听 $Protocol.UDP_DISCOVER_PORT")

        broadcastThread = Thread({
            while (running.get()) {
                try {
                    val json = announceJson()
                    val data = json.toByteArray(StandardCharsets.UTF_8)
                    val sock = DatagramSocket().apply {
                        broadcast = true
                    }
                    bcastSocket = sock
                    val addr = InetAddress.getByName("255.255.255.255")
                    val pkt = DatagramPacket(data, data.size, addr, Protocol.UDP_ANNOUNCE_PORT)
                    sock.send(pkt)
                    sock.close()
                    bcastSocket = null
                } catch (t: Throwable) {
                    if (running.get()) Log.w(TAG, "broadcast failed", t)
                }
                try {
                    Thread.sleep(Protocol.ANNOUNCE_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "cs360-announce").apply { start() }

        listenThread = Thread({
            while (running.get()) {
                var sock: DatagramSocket? = null
                try {
                    sock = DatagramSocket(Protocol.UDP_DISCOVER_PORT).apply {
                        broadcast = true
                    }
                    listenSocket = sock
                    val buf = ByteArray(64)
                    while (running.get()) {
                        val pkt = DatagramPacket(buf, buf.size)
                        sock.receive(pkt)
                        val txt = String(pkt.data, pkt.offset, pkt.length, StandardCharsets.UTF_8)
                        if (txt.startsWith("DISCOVER")) {
                            val json = announceJson().toByteArray(StandardCharsets.UTF_8)
                            val reply = DatagramPacket(
                                json, json.size, pkt.address, pkt.port
                            )
                            sock.send(reply)
                        }
                    }
                } catch (t: Throwable) {
                    if (running.get()) Log.w(TAG, "discover listen failed", t)
                    try {
                        sock?.close()
                    } catch (_: Throwable) {
                    }
                    listenSocket = null
                    try {
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                }
            }
        }, "cs360-discover").apply { start() }
    }

    fun stop() {
        running.set(false)
        try {
            bcastSocket?.close()
        } catch (_: Throwable) {
        }
        try {
            listenSocket?.close()
        } catch (_: Throwable) {
        }
        broadcastThread?.interrupt()
        listenThread?.interrupt()
        broadcastThread = null
        listenThread = null
    }
}

/** 局域网 IPv4，优先 192.168.x / 10.x */
object NetInfo {
    fun lanIp(): String? {
        try {
            val ifaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            var fallback: String? = null
            for (nif in ifaces) {
                if (!nif.isUp || nif.isLoopback) continue
                val addrs = Collections.list(nif.inetAddresses)
                for (a in addrs) {
                    if (a.isLoopbackAddress) continue
                    val host = a.hostAddress ?: continue
                    if (host.contains(':')) continue // IPv6
                    if (host.startsWith("192.168.") || host.startsWith("10.")) return host
                    if (fallback == null && host.matches(Regex("\\d+\\.\\d+\\.\\d+\\.\\d+"))) {
                        fallback = host
                    }
                }
            }
            return fallback
        } catch (t: Throwable) {
            return null
        }
    }
}
