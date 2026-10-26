package com.carsentinel.carunit.net

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 视频会话：`SUBSCRIBE <id>\n` → `OK <w> <h> <fps> h264\n` / `ERR <code> <msg>\n`，
 * 之后持续写二进制帧。
 *
 * 每会话一个「最多 2 帧、满了丢最旧」的有界队列：慢手机永远拖不慢编码线程。
 */
class VideoSession(
    private val socket: Socket,
    private val env: ServerEnvironment,
    private val sinks: (Int) -> CameraSink?,
    private val onBytes: (Int) -> Unit
) : FrameSink {

    companion object {
        private const val TAG = "VideoSession"
    }

    private class Queue(private val max: Int) {
        private val lock = Object()
        private val q = ArrayDeque<ByteArray>(max + 1)
        private var done = false

        fun offer(f: ByteArray) {
            synchronized(lock) {
                if (done) return
                while (q.size >= max) q.removeFirst()
                q.addLast(f)
                lock.notifyAll()
            }
        }

        /** 队列空且已关闭时返回 null，让写线程退出 */
        fun take(): ByteArray? {
            synchronized(lock) {
                while (q.isEmpty() && !done) {
                    try {
                        lock.wait()
                    } catch (_: InterruptedException) {
                        return null
                    }
                }
                return q.removeFirstOrNull()
            }
        }

        fun close() = synchronized(lock) {
            done = true
            q.clear()
            lock.notifyAll()
        }
    }

    private val queue = Queue(Protocol.MAX_PENDING_FRAMES)
    private val closed = AtomicBoolean(false)
    private val out: OutputStream = socket.getOutputStream()
    private val input: InputStream = socket.getInputStream()
    private val remote: String = describe(socket)
    private var cameraId = -1

    fun run() {
        try {
            socket.soTimeout = 0
            socket.tcpNoDelay = true
            val first = readLine(512) ?: run {
                close()
                return
            }
            val parts = first.trim().split(Regex("\\s+"))
            if (parts.isEmpty() || parts[0] != "SUBSCRIBE") {
                writeLine("ERR 400 expected SUBSCRIBE <id>")
                close()
                return
            }
            val id = parts.getOrNull(1)?.trim()?.toIntOrNull()
            val cam = id?.let { cid -> env.cameras().firstOrNull { it.id == cid } }
            if (cam == null) {
                writeLine("ERR 404 no such camera")
                close()
                return
            }
            cameraId = cam.id
            val sink = sinks(cam.id)
            if (sink == null) {
                writeLine("ERR 500 camera not streaming")
                close()
                return
            }
            sink.add(this)
            writeLine("OK ${cam.w} ${cam.h} ${cam.fps} ${Protocol.CODEC_H264}")
            // 立刻要一个 IDR：手机端刚连上，必须能马上建解码器
            env.requestKeyframe(cam.id)
            env.log(LogLevel.info, "视频订阅 摄像头 ${cam.id}（$remote）")

            // 写线程
            val writer = Thread({ writeLoop() }, "cs360-vs-out-$cameraId").apply { start() }
            // 读线程：只为感知对端关闭
            Thread({ readLoop() }, "cs360-vs-in-$cameraId").apply { start() }
            writer.join()
        } catch (t: Throwable) {
            if (!closed.get()) Log.w(TAG, "video session error", t)
        } finally {
            if (cameraId >= 0) sinks(cameraId)?.remove(this)
            queue.close()
            close()
        }
    }

    private fun writeLoop() {
        while (!closed.get()) {
            val frame = queue.take() ?: break
            try {
                out.write(frame)
                out.flush()
                onBytes(frame.size)
            } catch (t: Throwable) {
                close()
                break
            }
        }
    }

    private fun readLoop() {
        try {
            val buf = ByteArray(64)
            while (!closed.get()) {
                if (input.read(buf) < 0) break
            }
        } catch (_: Throwable) {
        } finally {
            close()
        }
    }

    private fun writeLine(s: String) {
        out.write((s + "\n").toByteArray(StandardCharsets.US_ASCII))
        out.flush()
    }

    private fun readLine(max: Int): String? {
        val sb = StringBuilder()
        while (sb.length < max) {
            val c = input.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            val ch = c.toChar()
            if (ch == '\n') return sb.toString()
            if (ch != '\r') sb.append(ch)
        }
        return sb.toString()
    }

    override fun offer(frame: ByteArray) {
        if (closed.get()) return
        queue.offer(frame)
    }

    override fun onClosed() {
        close()
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        queue.close()
        try {
            socket.close()
        } catch (_: Throwable) {
        }
    }

    private fun describe(s: Socket): String = try {
        "${s.inetAddress?.hostAddress ?: "?"}:${s.port}"
    } catch (_: Throwable) {
        "?"
    }
}
