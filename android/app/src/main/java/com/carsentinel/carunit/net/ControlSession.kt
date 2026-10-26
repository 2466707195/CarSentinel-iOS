package com.carsentinel.carunit.net

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 控制会话：JSON Lines 双向，15s 静默即断开（PROTOCOL §4.3）。
 */
class ControlSession(
    private val socket: Socket,
    private val env: ServerEnvironment,
    private val registry: ControlRegistry
) {
    companion object {
        private const val TAG = "ControlSession"
    }

    private val closed = AtomicBoolean(false)
    private val writeLock = Any()
    private val out: OutputStream = socket.getOutputStream()
    private val remote: String = describe(socket)

    fun run() {
        registry.add(this)
        socket.soTimeout = Protocol.CONTROL_IDLE_TIMEOUT_MS
        try {
            val reader = BufferedReader(
                InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8),
                8 * 1024
            )
            send(
                Json.Obj()
                    .put("t", "welcome")
                    .put("v", Protocol.VERSION)
                    .put("name", env.deviceName())
                    .putCameras("cameras", env.cameras())
            )
            logs("info", "控制连接 $remote")
            var line: String?
            while (!closed.get()) {
                line = try {
                    reader.readLine()
                } catch (e: java.net.SocketTimeoutException) {
                    logs("info", "控制连接 $remote 15s 静默，断开")
                    break
                } ?: break
                if (line.isEmpty()) continue
                // 协议限的是字节数，不是字符数（UTF-8 下一个中文占 3 字节）
                if (line.toByteArray(StandardCharsets.UTF_8).size > Protocol.MAX_LINE_BYTES) {
                    sendError(400, "line too long")
                    break
                }
                handle(line)
            }
        } catch (t: Throwable) {
            if (!closed.get()) Log.w(TAG, "control session error", t)
        } finally {
            registry.remove(this)
            close()
        }
    }

    private fun handle(line: String) {
        val msg: Json.Obj = try {
            Json.parse(line)
        } catch (t: Throwable) {
            sendError(400, "bad json")
            return
        }
        when (msg.getString("t")) {
            "hello" -> send(
                Json.Obj()
                    .put("t", "welcome")
                    .put("v", Protocol.VERSION)
                    .put("name", env.deviceName())
                    .putCameras("cameras", env.cameras())
            )

            "list" -> send(
                Json.Obj().put("t", "cameras").putCameras("cameras", env.cameras())
            )

            "subscribe" -> {
                val id = msg.getInt("camera")
                if (id == null) {
                    sendError(400, "missing camera")
                } else if (env.cameras().none { it.id == id }) {
                    sendError(404, "no such camera")
                } else {
                    env.requestKeyframe(id)
                    send(Json.Obj().put("t", "subscribed").put("camera", id))
                }
            }

            "unsubscribe" -> {
                val id = msg.getInt("camera") ?: run {
                    sendError(400, "missing camera")
                    return
                }
                send(Json.Obj().put("t", "unsubscribed").put("camera", id))
            }

            "keyframe" -> {
                val id = msg.getInt("camera")
                val ok = id != null && env.requestKeyframe(id)
                if (ok) {
                    send(Json.Obj().put("t", "ok"))
                } else {
                    sendError(404, "no such camera")
                }
            }

            "stats" -> {
                val s = env.stats()
                send(
                    Json.Obj()
                        .put("t", "stats")
                        .put("cpu", s.cpu)
                        .put("netKbps", s.netKbps)
                        .put("uptimeSec", s.uptimeSec)
                )
            }

            "ping" -> {
                val id = msg.getLong("id") ?: msg.getInt("id")?.toLong()
                val o = Json.Obj().put("t", "pong")
                if (id != null) o.put("id", id)
                send(o)
            }

            "bye" -> close()

            else -> sendError(400, "unknown message ${msg.getString("t")}")
        }
    }

    private fun send(o: Json.Obj) {
        val text = o.toString() + "\n"
        synchronized(writeLock) {
            try {
                out.write(text.toByteArray(StandardCharsets.UTF_8))
                out.flush()
            } catch (t: Throwable) {
                close()
            }
        }
    }

    private fun sendError(code: Int, msg: String) {
        send(Json.Obj().put("t", "error").put("code", code).put("msg", msg))
    }

    fun pushRaw(line: String) {
        synchronized(writeLock) {
            try {
                out.write((line + "\n").toByteArray(StandardCharsets.UTF_8))
                out.flush()
            } catch (t: Throwable) {
                close()
            }
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        try {
            socket.close()
        } catch (_: Throwable) {
        }
    }

    private fun logs(level: String, msg: String) {
        env.log(LogLevel.valueOf(level), msg)
    }

    private fun describe(s: Socket): String = try {
        "${s.inetAddress?.hostAddress ?: "?"}:${s.port}"
    } catch (_: Throwable) {
        "?"
    }
}

/** 所有控制会话的登记处，负责主动推送 */
class ControlRegistry(private val logs: LogBus) : LogBus.Listener {
    private val sessions = CopyOnWriteArrayList<ControlSession>()

    init {
        logs.addListener(this)
    }

    fun add(s: ControlSession) {
        sessions.addIfAbsent(s)
    }

    fun remove(s: ControlSession) {
        sessions.remove(s)
        // 监听者的摘除集中在 closeAll()：ControlRegistry 与 StreamServer 同生命周期，
        // 每路断开都去动 LogBus 反而会引入竞态。
    }

    fun closeAll() {
        for (s in sessions) s.close()
        sessions.clear()
        logs.removeListener(this)
    }

    override fun onLog(level: LogLevel, msg: String) {
        broadcast(
            Json.Obj()
                .put("t", "log")
                .put("level", level.name)
                .put("msg", msg)
                .toString()
        )
    }

    fun broadcastCameras(cameras: List<CameraInfo>) {
        broadcast(Json.Obj().put("t", "cameras").putCameras("cameras", cameras).toString())
    }

    fun broadcastState(state: CameraState) {
        broadcast(
            Json.Obj()
                .put("t", "camera_state")
                .put("camera", state.id)
                .put("active", state.active)
                .put("fps", state.fps)
                .put("bitrateKbps", state.bitrateKbps)
                .toString()
        )
    }

    // internal：StreamServer 的 ControlSession 要调它广播摄像头列表变化
    internal fun broadcast(line: String) {
        for (s in sessions) {
            try {
                s.pushRaw(line)
            } catch (_: Throwable) {
            }
        }
    }
}

/** 车机整体状态 */
class ServerStats(
    val cpu: Double,
    val netKbps: Int,
    val uptimeSec: Int
)

/** StreamServer 需要的环境能力，由 StreamService 提供 */
interface ServerEnvironment {
    fun deviceName(): String
    fun cameras(): List<CameraInfo>
    fun cameraState(id: Int): CameraState?
    fun requestKeyframe(id: Int): Boolean
    fun stats(): ServerStats
    fun log(level: LogLevel, msg: String)
}
