package com.carsentinel.carunit.net

import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * TCP 45678：控制通道 + 视频通道共用一个端口，靠首字节分流（PROTOCOL §3）。
 * 每 socket 一个线程，accept 循环跑在后台线程上。
 */
class StreamServer(
    private val env: ServerEnvironment,
    private val logs: LogBus
) {
    companion object {
        private const val TAG = "StreamServer"
    }

    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private var statsThread: Thread? = null

    /** 协议 id → 帧扇出点 */
    private val sinks = ConcurrentHashMap<Int, CameraSink>()

    private val registry = ControlRegistry(logs)

    private val bytesOut = AtomicLong(0)
    private var lastBytes = 0L
    private var lastAt = System.currentTimeMillis()

    @Volatile
    var netKbps: Int = 0
        private set

    fun sink(id: Int): CameraSink = sinks.getOrPut(id) { CameraSink(id) }

    fun sinkIfExists(id: Int): CameraSink? = sinks[id]

    fun start() {
        if (!running.compareAndSet(false, true)) return
        try {
            val ss = ServerSocket(Protocol.TCP_PORT, 64, InetAddress.getByName("0.0.0.0"))
            ss.reuseAddress = true
            serverSocket = ss
        } catch (e: IOException) {
            running.set(false)
            logs.error("无法监听 ${Protocol.TCP_PORT}：${e.message}")
            return
        }
        logs.info("TCP 服务已监听 ${Protocol.TCP_PORT}")

        acceptThread = Thread({
            while (running.get()) {
                var sock: Socket? = null
                try {
                    sock = serverSocket?.accept()
                    if (sock == null) break
                    sock.tcpNoDelay = true
                    handle(sock)
                } catch (t: Throwable) {
                    if (running.get()) Log.w(TAG, "accept failed", t)
                    try {
                        sock?.close()
                    } catch (_: Throwable) {
                    }
                }
            }
        }, "cs360-accept").apply { start() }

        statsThread = Thread({
            while (running.get()) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                val now = System.currentTimeMillis()
                val bytes = bytesOut.get()
                val dt = now - lastAt
                if (dt > 0) {
                    netKbps = (((bytes - lastBytes) * 8) / dt).toInt()
                    lastBytes = bytes
                    lastAt = now
                }
            }
        }, "cs360-stats").apply { start() }
    }

    private fun handle(sock: Socket) {
        Thread({
            try {
                sock.soTimeout = 10_000
                val input = sock.getInputStream()
                val first = input.read()
                if (first < 0) {
                    sock.close()
                    return@Thread
                }
                when (first.toChar()) {
                    '{' -> {
                        // 控制会话：把已读的 '{' 拼回第一行
                        val rest = readLineFrom(input, Protocol.MAX_LINE_BYTES)
                        val line = "{" + (rest ?: "")
                        sock.soTimeout = Protocol.CONTROL_IDLE_TIMEOUT_MS
                        ControlSession(PrefixedSocket(sock, line), env, registry).run()
                    }

                    'S' -> {
                        val rest = readLineFrom(input, 512)
                        val line = "S" + (rest ?: "")
                        sock.soTimeout = 0
                        VideoSession(
                            PrefixedSocket(sock, line),
                            env,
                            { id -> sinkIfExists(id) ?: sink(id) },
                            { n -> bytesOut.addAndGet(n.toLong()) }
                        ).run()
                    }

                    else -> {
                        try {
                            sock.getOutputStream().write("ERR 400 expected { or S\n".toByteArray())
                            sock.getOutputStream().flush()
                        } catch (_: Throwable) {
                        }
                        sock.close()
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "session error", t)
                try {
                    sock.close()
                } catch (_: Throwable) {
                }
            }
        }, "cs360-conn").start()
    }

    private fun readLineFrom(input: InputStream, max: Int): String? {
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

    fun stop() {
        running.set(false)
        registry.closeAll()
        for (s in sinks.values) s.closeAll()
        sinks.clear()
        try {
            serverSocket?.close()
        } catch (_: Throwable) {
        }
        acceptThread?.interrupt()
        statsThread?.interrupt()
        acceptThread = null
        statsThread = null
        serverSocket = null
    }

    fun statsKbps(): Int = netKbps

    /** 供 StreamService 主动推送用：一行原始 JSON */
    fun registryBroadcast(line: String) = registry.broadcast(line)

    fun registryBroadcastState(state: CameraState) = registry.broadcastState(state)
}

/**
 * 把「已经读过一个字节 / 一行」的 socket 包成普通 Socket 的样子，
 * 让 ControlSession / VideoSession 不用改就能从第二字节开始读。
 */
private class PrefixedSocket(
    private val delegate: Socket,
    private val firstLine: String
) : Socket() {

    private val pending: ByteArray = (firstLine + "\n").toByteArray(Charsets.UTF_8)
    private var pendingOff = 0

    override fun getInputStream(): InputStream {
        val raw = delegate.getInputStream()
        return object : InputStream() {
            override fun read(): Int {
                if (pendingOff < pending.size) return pending[pendingOff++].toInt() and 0xFF
                return raw.read()
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (pendingOff < pending.size) {
                    val n = minOf(len, pending.size - pendingOff)
                    System.arraycopy(pending, pendingOff, b, off, n)
                    pendingOff += n
                    return n
                }
                return raw.read(b, off, len)
            }

            override fun available(): Int =
                (pending.size - pendingOff) + raw.available()

            override fun close() {
                // 不关底层流，socket 关闭时会一并处理
            }
        }
    }

    override fun getOutputStream() = delegate.getOutputStream()

    override fun getInetAddress(): InetAddress? = delegate.inetAddress

    override fun getPort(): Int = delegate.port

    override fun getLocalAddress(): InetAddress? = delegate.localAddress

    override fun getLocalPort(): Int = delegate.localPort

    override fun getSoTimeout(): Int = delegate.soTimeout

    override fun setSoTimeout(timeout: Int) {
        delegate.soTimeout = timeout
    }

    override fun getTcpNoDelay(): Boolean = delegate.tcpNoDelay

    override fun setTcpNoDelay(on: Boolean) {
        delegate.tcpNoDelay = on
    }

    override fun isClosed(): Boolean = delegate.isClosed

    override fun close() {
        delegate.close()
    }
}
