package com.carsentinel.carunit.service

import android.content.Context
import android.content.Intent
import com.carsentinel.carunit.net.CameraInfo
import com.carsentinel.carunit.net.LogEntry
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * UI 与 Service 之间的薄壳：UI 只跟这个 object 打交道，不直接碰 Service。
 */
object ServiceController {

    data class UiCamera(
        val id: Int,
        val name: String,
        val pos: String,
        val w: Int,
        val h: Int,
        val fps: Int,
        val active: Boolean,
        val kbps: Int,
        val available: Boolean
    )

    data class UiState(
        val running: Boolean = false,
        val starting: Boolean = false,
        val deviceName: String = "CarSentinel",
        val ip: String = "—",
        val port: Int = 45678,
        val cameras: List<UiCamera> = emptyList(),
        val totalKbps: Int = 0,
        val cpu: Double = 0.0,
        val uptimeSec: Int = 0,
        val announceJson: String = "",
        val logs: List<LogEntry> = emptyList(),
        // 摄像头健康状况 —— 0 路时必须让用户知道为什么，而不是一句「正在重试」
        val cameraEnumerated: Int = 0,
        val cameraOpened: Int = 0,
        val cameraHint: String = "",
        val cameraRetrying: Boolean = false,
        val cameraRetryCount: Int = 0,
        val hasCameraPermission: Boolean = true
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    @Volatile
    var lastError: String? = null
        private set

    fun start(context: Context) {
        lastError = null
        _state.value = _state.value.copy(starting = true)
        val intent = Intent(context, StreamService::class.java).apply {
            action = StreamService.ACTION_START
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stop(context: Context) {
        val intent = Intent(context, StreamService::class.java).apply {
            action = StreamService.ACTION_STOP
        }
        try {
            context.startService(intent)
        } catch (_: Throwable) {
        }
    }

    /** 手动重试打开摄像头（状态页「重试」按钮用） */
    fun retryCameras(context: Context) {
        val intent = Intent(context, StreamService::class.java).apply {
            action = StreamService.ACTION_RETRY_CAMERAS
        }
        try {
            context.startService(intent)
        } catch (_: Throwable) {
        }
    }

    internal fun publish(next: UiState) {
        _state.value = next
    }

    internal fun setError(msg: String?) {
        lastError = msg
    }
}
