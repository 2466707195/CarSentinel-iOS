package com.carsentinel.carunit.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import com.carsentinel.carunit.MainActivity
import com.carsentinel.carunit.R
import com.carsentinel.carunit.camera.CameraHub
import com.carsentinel.carunit.net.Announcer
import com.carsentinel.carunit.net.CameraInfo
import com.carsentinel.carunit.net.CameraSink
import com.carsentinel.carunit.net.CameraState
import com.carsentinel.carunit.net.LogBus
import com.carsentinel.carunit.net.LogLevel
import com.carsentinel.carunit.net.NetInfo
import com.carsentinel.carunit.net.Protocol
import com.carsentinel.carunit.net.ServerEnvironment
import com.carsentinel.carunit.net.ServerStats
import com.carsentinel.carunit.net.StreamServer
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 前台服务：持有 CameraHub + 编码器 + StreamServer + Announcer，常驻通知，START_STICKY。
 */
class StreamService : Service(), ServerEnvironment, CameraHub.Delegate, LogBus.Listener {

    companion object {
        const val ACTION_START = "com.carsentinel.carunit.START"
        const val ACTION_STOP = "com.carsentinel.carunit.STOP"
        const val ACTION_RETRY_CAMERAS = "com.carsentinel.carunit.RETRY_CAMERAS"
        private const val TAG = "StreamService"
        private const val CHANNEL_ID = "cs360-stream"
        private const val NOTIF_ID = 1001

        /** 0 路摄像头时自动重试的间隔与次数上限。
         *  很多车机首次枚举/打开会失败（摄像头服务没就绪、权限刚授予），
         *  但不该无限重试 —— 30 秒后停，等用户点「重试」或重启服务。 */
        private const val CAMERA_RETRY_INTERVAL_MS = 5_000L
        private const val CAMERA_RETRY_MAX = 6
    }

    private val logs = LogBus()
    private val running = AtomicBoolean(false)

    private var hub: CameraHub? = null
    private var server: StreamServer? = null
    private var announcer: Announcer? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var poller: Thread? = null
    private var startedAtMs: Long = 0

    private val deviceName: String by lazy { buildDeviceName() }

    /** 上一轮已知状态，用于只在变化时推送 camera_state */
    private val lastState = HashMap<Int, CameraState>()
    private val stateLock = Any()

    private val cpuSampler = CpuSampler()

    // ---------------- lifecycle ----------------

    override fun onCreate() {
        super.onCreate()
        createChannel()
        logs.addListener(this)
        ServiceController.publish(
            ServiceController.UiState(deviceName = deviceName)
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                teardown()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_RETRY_CAMERAS -> {
                val h = hub
                if (h == null || !running.get()) {
                    logs.warn("服务未在运行，先启动服务")
                    startStreaming()
                } else {
                    h.retry()
                    logs.info("手动重试打开摄像头")
                }
                publishUi()
            }

            else -> startStreaming()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        teardown()
        logs.removeListener(this)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onLowMemory() {
        logs.warn("系统内存不足")
        super.onLowMemory()
    }

    // ---------------- start / stop ----------------

    private fun startStreaming() {
        if (running.get()) return
        running.set(true)
        startedAtMs = SystemClock.elapsedRealtime()
        startForegroundCompat("正在启动…")
        acquireLocks()

        val h = CameraHub(this, logs).also { hub = it }
        h.delegate = this
        h.sinkProvider = { id -> server?.sink(id) ?: CameraSink(id) }

        val srv = StreamServer(this, logs).also { server = it }
        srv.start()

        val ann = Announcer(deviceName, { h.currentCameras() }, logs).also { announcer = it }
        ann.start()

        h.start()

        poller = Thread({ pollLoop() }, "cs360-poll").apply { start() }

        logs.info("服务已启动，端口 ${Protocol.TCP_PORT}")
        publishUi()
    }

    private fun teardown() {
        if (!running.getAndSet(false)) return
        try {
            announcer?.stop()
        } catch (_: Throwable) {
        }
        try {
            server?.stop()
        } catch (_: Throwable) {
        }
        try {
            hub?.shutdown()
        } catch (_: Throwable) {
        }
        poller?.interrupt()
        poller = null
        releaseLocks()
        synchronized(stateLock) { lastState.clear() }
        announcer = null
        server = null
        hub = null
        ServiceController.publish(
            ServiceController.UiState(
                running = false,
                starting = false,
                deviceName = deviceName,
                logs = logs.snapshot()
            )
        )
    }

    // ---------------- CameraHub.Delegate ----------------

    override fun onCameraSetChanged(infos: List<CameraInfo>) {
        announcer?.markDirty()
        server?.let { srv ->
            // 摄像头集合变化主动推
            val line = com.carsentinel.carunit.net.Json.Obj()
                .put("t", "cameras")
                .putCameras("cameras", infos)
                .toString()
            srv.registryBroadcast(line)
        }
        synchronized(stateLock) {
            val live = infos.map { it.id }.toSet()
            lastState.keys.retainAll(live)
        }
        logs.info("摄像头集合变化：${infos.size} 路可服务")
        publishUi()
    }

    override fun onCameraState(id: Int, active: Boolean, fps: Int, bitrateKbps: Int) {
        val st = CameraState(id, active, fps, bitrateKbps)
        var changed = false
        synchronized(stateLock) {
            val prev = lastState[id]
            if (prev == null || prev.active != active || prev.fps != fps ||
                Math.abs(prev.bitrateKbps - bitrateKbps) >= 100
            ) {
                lastState[id] = st
                changed = true
            }
        }
        if (changed) {
            server?.registryBroadcastState(st)
            publishUi()
        }
    }

    // ---------------- ServerEnvironment ----------------

    override fun deviceName(): String = deviceName

    override fun cameras(): List<CameraInfo> = hub?.currentCameras() ?: emptyList()

    override fun cameraState(id: Int): CameraState? = synchronized(stateLock) { lastState[id] }

    override fun requestKeyframe(id: Int): Boolean = hub?.requestKeyframe(id) ?: false

    override fun stats(): ServerStats {
        val uptime = if (startedAtMs == 0L) 0
        else ((SystemClock.elapsedRealtime() - startedAtMs) / 1000).toInt()
        return ServerStats(
            cpu = cpuSampler.sample(),
            netKbps = server?.statsKbps() ?: 0,
            uptimeSec = uptime
        )
    }

    override fun log(level: LogLevel, msg: String) {
        pushLog(level, msg)
    }

    private fun pushLog(level: LogLevel, msg: String) {
        when (level) {
            LogLevel.error -> Log.e(TAG, msg)
            LogLevel.warn -> Log.w(TAG, msg)
            LogLevel.debug -> Log.d(TAG, msg)
            else -> Log.i(TAG, msg)
        }
        publishUi()
    }

    // ---------------- LogBus.Listener ----------------

    override fun onLog(level: LogLevel, msg: String) {
        pushLog(level, msg)
    }

    // ---------------- loops ----------------

    private fun pollLoop() {
        var lastRetryAt = 0L
        while (running.get()) {
            try {
                val srv = server
                val h = hub
                if (h != null) {
                    for (info in h.currentCameras()) {
                        val f = h.feeder(info.id)
                        val kbps = f?.statsKbps() ?: 0
                        val fps = f?.statsFps() ?: 0
                        onCameraState(info.id, f != null && f.isOpen(), fps, kbps)
                    }

                    // 一路都没打开 → 自动重试。车机首次枚举常因摄像头服务没就绪而全失败，
                    // 但不无限重试：到 CAMERA_RETRY_MAX 次就停，等用户点「重试」。
                    val now = SystemClock.elapsedRealtime()
                    if (h.openedCount() == 0 && now - lastRetryAt >= CAMERA_RETRY_INTERVAL_MS) {
                        if (h.retryCount < CAMERA_RETRY_MAX) {
                            lastRetryAt = now
                            h.setRetrying(true)
                            h.retry()
                        } else {
                            h.setRetrying(false)
                        }
                    }
                    if (h.openedCount() > 0) {
                        h.setRetrying(false)
                        lastRetryAt = 0L
                    }
                }
                val total = srv?.statsKbps() ?: 0
                val ip = NetInfo.lanIp() ?: "—"
                val camUi = h?.currentCameras()?.map { c ->
                    val f = h.feeder(c.id)
                    ServiceController.UiCamera(
                        id = c.id,
                        name = c.name,
                        pos = c.pos,
                        w = c.w,
                        h = c.h,
                        fps = if (f?.isOpen() == true) f.statsFps() else 0,
                        active = f?.isOpen() == true,
                        kbps = f?.statsKbps() ?: 0,
                        available = f?.isOpen() == true
                    )
                } ?: emptyList()
                val snap = ServiceController.UiState(
                    running = true,
                    starting = false,
                    deviceName = deviceName,
                    ip = ip,
                    port = Protocol.TCP_PORT,
                    cameras = camUi,
                    totalKbps = total,
                    cpu = cpuSampler.sample(),
                    uptimeSec = if (startedAtMs == 0L) 0
                    else ((SystemClock.elapsedRealtime() - startedAtMs) / 1000).toInt(),
                    announceJson = announcer?.announceJson() ?: "",
                    logs = logs.snapshot(),
                    cameraEnumerated = h?.enumeratedCount() ?: 0,
                    cameraOpened = h?.openedCount() ?: 0,
                    cameraHint = h?.statusHint() ?: "",
                    cameraRetrying = h?.retrying == true,
                    cameraRetryCount = h?.retryCount ?: 0,
                    hasCameraPermission = hasCameraPermission()
                )
                ServiceController.publish(snap)
                val notifCameras = snap.cameras.size
                updateNotification("推流中 · $notifCameras 路摄像头 · ${total} kbps")
                Thread.sleep(1000)
            } catch (_: InterruptedException) {
                return
            } catch (t: Throwable) {
                Log.w(TAG, "poll error", t)
            }
        }
    }

    /** 摄像头权限是否已授予。没授予的话打开必失败，UI 要明确提示而不是显示「重试中」。 */
    private fun hasCameraPermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    // ---------------- helpers ----------------

    private fun publishUi() {
        val snap = ServiceController.state.value
        ServiceController.publish(
            snap.copy(
                running = true,
                deviceName = deviceName,
                cameras = hub?.currentCameras()?.map { c ->
                    val f = hub?.feeder(c.id)
                    ServiceController.UiCamera(
                        id = c.id,
                        name = c.name,
                        pos = c.pos,
                        w = c.w,
                        h = c.h,
                        fps = if (f?.isOpen() == true) f.statsFps() else 0,
                        active = f?.isOpen() == true,
                        kbps = f?.statsKbps() ?: 0,
                        available = f?.isOpen() == true
                    )
                } ?: emptyList(),
                announceJson = announcer?.announceJson() ?: "",
                logs = logs.snapshot()
            )
        )
    }

    private fun buildDeviceName(): String {
        val raw = try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: "cs360"
        } catch (_: Throwable) {
            "cs360"
        }
        val hex = Integer.toHexString(raw.hashCode()).uppercase()
        val suffix = if (hex.length >= 4) hex.takeLast(4) else hex.padStart(4, '0')
        return "CarSentinel-$suffix"
    }

    private fun acquireLocks() {
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL
            }
            wifiLock = try {
                wm.createWifiLock(mode, "cs360:stream").apply { acquire() }
            } catch (_: Throwable) {
                @Suppress("DEPRECATION")
                wm.createWifiLock(WifiManager.WIFI_MODE_FULL, "cs360:stream").apply { acquire() }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "wifi lock failed", t)
        }
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cs360:cpu").apply {
                acquire()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "wake lock failed", t)
        }
    }

    private fun releaseLocks() {
        try {
            wifiLock?.release()
        } catch (_: Throwable) {
        }
        wifiLock = null
        try {
            wakeLock?.release()
        } catch (_: Throwable) {
        }
        wakeLock = null
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(
                CHANNEL_ID,
                "哨兵推流",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "CarSentinel 360 视频推流常驻通知"
                setShowBadge(false)
            }
            nm.createNotificationChannel(ch)
        }
    }

    private fun startForegroundCompat(text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = Intent(this, StreamService::class.java).apply { action = ACTION_STOP }
        val stopPi = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID).apply {
            setContentTitle(getString(R.string.notif_title))
            setContentText(text)
            setSmallIcon(R.drawable.ic_stat_shield)
            setContentIntent(pi)
            setOngoing(true)
            setOnlyAlertOnce(true)
            addAction(
                Notification.Action.Builder(
                    null, getString(R.string.notif_stop), stopPi
                ).build()
            )
        }.build()
    }

    private fun updateNotification(text: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(text))
        } catch (t: Throwable) {
            Log.w(TAG, "notify failed", t)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    /** /proc/stat 一阶差分算 CPU 占用 */
    private class CpuSampler {
        private var lastTotal = 0L
        private var lastIdle = 0L
        private var value = 0.0

        fun sample(): Double {
            val line = try {
                File("/proc/stat").bufferedReader().use { it.readLine() }
            } catch (_: Throwable) {
                null
            } ?: return value
            val parts = line.trim().split(Regex("\\s+"))
            if (parts.size < 5 || parts[0] != "cpu") return value
            var total = 0L
            for (i in 1 until parts.size) {
                parts[i].toLongOrNull()?.let { total += it }
            }
            val idle = parts[4].toLongOrNull() ?: 0L
            if (lastTotal > 0) {
                val dt = total - lastTotal
                val di = idle - lastIdle
                if (dt > 0) {
                    val load = 1.0 - di.toDouble() / dt.toDouble()
                    value = Math.max(0.0, Math.min(1.0, load))
                }
            }
            lastTotal = total
            lastIdle = idle
            return value
        }
    }
}
