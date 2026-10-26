package com.carsentinel.carunit.net

import java.util.concurrent.CopyOnWriteArrayList

/**
 * CarSentinel 360 流媒体协议 v1 —— 常量与共享类型。
 * 契约见 docs/PROTOCOL.md，字段名 / 魔数 / 端口全部冻结。
 */
object Protocol {
    const val VERSION = 1

    /** UDP：手机端广播探测请求，车机端单播回复 announce */
    const val UDP_DISCOVER_PORT = 45676

    /** UDP：车机端定时广播 announce */
    const val UDP_ANNOUNCE_PORT = 45677

    /** TCP：控制通道 + 视频通道共用一个端口，靠首字节分流 */
    const val TCP_PORT = 45678

    /** announce 周期（毫秒） */
    const val ANNOUNCE_INTERVAL_MS = 1000L

    /** 控制通道 15s 静默即断开 */
    const val CONTROL_IDLE_TIMEOUT_MS = 15_000

    /** 单行 JSON 上限 64 KB */
    const val MAX_LINE_BYTES = 64 * 1024

    /** 帧魔数 ASCII "CS60" */
    val MAGIC = byteArrayOf(0x43, 0x53, 0x36, 0x30)

    const val HEADER_SIZE = 24

    /** flags bit0 = 关键帧 */
    const val FLAG_KEYFRAME = 0x01

    const val CODEC_H264 = "h264"

    /** 视频会话每路最多积压 2 帧，满了丢最旧的，永不阻塞编码线程 */
    const val MAX_PENDING_FRAMES = 2

    // ---- 摄像头位置 ----
    const val POS_FRONT = "front"
    const val POS_REAR = "rear"
    const val POS_LEFT = "left"
    const val POS_RIGHT = "right"
    const val POS_INNER = "inner"
    const val POS_UNKNOWN = "unknown"

    fun posName(pos: String): String = when (pos) {
        POS_FRONT -> "前视"
        POS_REAR -> "后视"
        POS_LEFT -> "左视"
        POS_RIGHT -> "右视"
        POS_INNER -> "内视"
        else -> "摄像头"
    }
}

/** 一路已打开（可服务）的摄像头。announce / cameras 列表就是它。 */
data class CameraInfo(
    val id: Int,
    val name: String,
    val pos: String,
    val w: Int,
    val h: Int,
    val fps: Int = 30,
    val caps: List<String> = listOf(Protocol.CODEC_H264)
)

/** 一路摄像头的实时状态，变化时通过控制通道推送 */
data class CameraState(
    val id: Int,
    val active: Boolean,
    val fps: Int = 0,
    val bitrateKbps: Int = 0
)

enum class LogLevel { debug, info, warn, error }

data class LogEntry(val level: LogLevel, val msg: String, val atMs: Long = System.currentTimeMillis())

/**
 * 一个视频会话的收帧口。offer 永不阻塞：满了丢最旧的。
 */
interface FrameSink {
    fun offer(frame: ByteArray)
    fun onClosed()
}

/**
 * 一路摄像头的扇出点：编码线程往里 broadcast，每个订阅会话各自排队。
 */
class CameraSink(val cameraId: Int) {
    private val sinks = CopyOnWriteArrayList<FrameSink>()

    fun add(sink: FrameSink) {
        sinks.addIfAbsent(sink)
    }

    fun remove(sink: FrameSink) {
        sinks.remove(sink)
    }

    fun subscriberCount(): Int = sinks.size

    /** 返回被丢弃的帧数，用于统计 */
    fun broadcast(frame: ByteArray): Int {
        var dropped = 0
        for (s in sinks) {
            try {
                s.offer(frame)
            } catch (_: Throwable) {
                dropped++
            }
        }
        return dropped
    }

    fun closeAll() {
        for (s in sinks) {
            try {
                s.onClosed()
            } catch (_: Throwable) {
            }
        }
        sinks.clear()
    }
}

/**
 * 拼一帧：24 字节大端帧头 + Annex-B 负载。
 */
fun buildFrame(cameraId: Int, ptsUs: Long, keyframe: Boolean, payload: ByteArray): ByteArray {
    val out = ByteArray(Protocol.HEADER_SIZE + payload.size)
    System.arraycopy(Protocol.MAGIC, 0, out, 0, 4)
    out[4] = Protocol.VERSION.toByte()
    out[5] = if (keyframe) Protocol.FLAG_KEYFRAME.toByte() else 0
    out[6] = 0
    out[7] = 0
    putU32(out, 8, cameraId.toLong())
    putU64(out, 12, ptsUs)
    putU32(out, 20, payload.size.toLong())
    System.arraycopy(payload, 0, out, Protocol.HEADER_SIZE, payload.size)
    return out
}

fun putU32(buf: ByteArray, off: Int, v: Long) {
    buf[off] = ((v ushr 24) and 0xFF).toByte()
    buf[off + 1] = ((v ushr 16) and 0xFF).toByte()
    buf[off + 2] = ((v ushr 8) and 0xFF).toByte()
    buf[off + 3] = (v and 0xFF).toByte()
}

fun putU64(buf: ByteArray, off: Int, v: Long) {
    for (i in 0 until 8) {
        buf[off + i] = ((v ushr (56 - 8 * i)) and 0xFF).toByte()
    }
}

/** Annex-B 起始码 */
val START_CODE = byteArrayOf(0x00, 0x00, 0x00, 0x01)

/**
 * 按 Annex-B 起始码切出所有 NAL（不含起始码）。
 * 与 iOS 端 `H264Decoder.splitNalUnits` 同一套逻辑，两边行为必须一致。
 */
fun splitAnnexB(data: ByteArray): List<ByteArray> {
    val out = ArrayList<ByteArray>()
    var i = 0
    var nalStart = -1
    while (i + 2 < data.size) {
        if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) {
            val four = i > 0 && data[i - 1] == 0.toByte()
            val scPos = if (four) i - 1 else i
            if (nalStart >= 0) out.add(data.copyOfRange(nalStart, scPos))
            nalStart = scPos + if (four) 4 else 3
            i += 3
        } else {
            i++
        }
    }
    if (nalStart in 0 until data.size) out.add(data.copyOfRange(nalStart, data.size))
    return out
}

/**
 * 把编码器吐出来的 SPS/PPS 规范成「每个 NAL 各自带 00 00 00 01 前缀」。
 *
 * 绝大多数设备的 config buffer 本身就是 Annex-B，这里只做校验 + 兜底：
 * 少数设备不给起始码，直接拼会把 SPS 和 PPS 粘成一个坏 NAL，手机上必然花屏。
 */
fun normalizeParameterSets(raw: ByteArray): ByteArray {
    val nals = splitAnnexB(raw)
    if (nals.isEmpty()) return concat(START_CODE, raw)
    val parts = ArrayList<ByteArray>(nals.size * 2)
    for (n in nals) {
        parts.add(START_CODE)
        parts.add(n)
    }
    return concat(*parts.toTypedArray())
}

fun concat(vararg parts: ByteArray): ByteArray {
    var n = 0
    for (p in parts) n += p.size
    val out = ByteArray(n)
    var o = 0
    for (p in parts) {
        System.arraycopy(p, 0, out, o, p.size)
        o += p.size
    }
    return out
}

/**
 * 日志总线：service 写一条，控制通道推给所有已连接手机，UI 列表也读它。
 */
class LogBus(private val capacity: Int = 300) {
    interface Listener {
        fun onLog(level: LogLevel, msg: String)
    }

    private val listeners = CopyOnWriteArrayList<Listener>()
    private val lock = Any()
    private val ring = ArrayDeque<LogEntry>()

    fun addListener(l: Listener) {
        listeners.addIfAbsent(l)
    }

    fun removeListener(l: Listener) {
        listeners.remove(l)
    }

    fun log(level: LogLevel, msg: String) {
        val e = LogEntry(level, msg)
        synchronized(lock) {
            ring.addLast(e)
            while (ring.size > capacity) ring.removeFirst()
        }
        for (l in listeners) {
            try {
                l.onLog(level, msg)
            } catch (_: Throwable) {
            }
        }
    }

    fun info(msg: String) = log(LogLevel.info, msg)
    fun warn(msg: String) = log(LogLevel.warn, msg)
    fun error(msg: String) = log(LogLevel.error, msg)
    fun debug(msg: String) = log(LogLevel.debug, msg)

    fun snapshot(): List<LogEntry> = synchronized(lock) { ring.toList() }

    fun clear() = synchronized(lock) { ring.clear() }
}
