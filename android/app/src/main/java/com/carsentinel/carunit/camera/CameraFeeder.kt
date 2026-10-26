package com.carsentinel.carunit.camera

import android.graphics.ImageFormat
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaCodec
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import com.carsentinel.carunit.codec.H264Encoder
import com.carsentinel.carunit.net.CameraSink
import com.carsentinel.carunit.net.Protocol
import com.carsentinel.carunit.net.buildFrame
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 一个 Camera2 设备 → 一个 MediaCodec 输入 Surface。
 * `createCaptureSession` 用 TEMPLATE_RECORD，目标 1280x720 @ 30，
 * 不支持时退到 StreamConfigurationMap 里最接近的支持尺寸。
 */
class CameraFeeder(
    private val cameraId: String,
    private val manager: CameraManager,
    private val targetW: Int = 1280,
    private val targetH: Int = 720,
    private val targetFps: Int = 30,
    private val bitrate: Int = 2_500_000
) {
    companion object {
        private const val TAG = "CameraFeeder"
    }

    interface Listener {
        fun onOpened(info: CameraSlot)
        fun onFailed(cameraId: String, reason: String)
        fun onFrame(cameraId: String, bytes: Int)
        fun onClosed(cameraId: String)
    }

    private val stateCallbackLock = Any()
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var encoder: H264Encoder? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null

    private val opened = AtomicBoolean(false)
    private val running = AtomicBoolean(false)

    var width = targetW
        private set
    var height = targetH
        private set
    var fps = targetFps
        private set

    /** 本路真正在用的输出尺寸（可能与 target 不同） */
    var actualWidth = targetW
        private set
    var actualHeight = targetH
        private set

    /** 打开后由 Hub 注入：帧往这里扇出 */
    var sink: CameraSink? = null

    var listener: Listener? = null

    fun open() {
        synchronized(stateCallbackLock) {
            if (running.get()) return
            running.set(true)
        }
        val thread = HandlerThread("cs360-cam-$cameraId").apply { start() }
        handlerThread = thread
        handler = Handler(thread.looper)
        val h = handler!!

        try {
            val chars = manager.getCameraCharacteristics(cameraId)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val chosen = pickSize(map)
            actualWidth = chosen.width
            actualHeight = chosen.height
            val ranges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            val range = pickFpsRange(ranges)
            fps = range.upper

            val enc = H264Encoder(actualWidth, actualHeight, fps, bitrate) { payload, key, pts ->
                val s = sink ?: return@H264Encoder
                val frame = buildFrame(protocolId(), pts, key, payload)
                s.broadcast(frame)
                listener?.onFrame(cameraId, frame.size)
            }
            encoder = enc
            enc.start()

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    device = d
                    opened.set(true)
                    startSession(d, enc.inputSurface, range)
                    listener?.onOpened(
                        CameraSlot(
                            cameraId = cameraId,
                            name = Protocol.posName(Protocol.POS_UNKNOWN),
                            pos = Protocol.POS_UNKNOWN,
                            w = actualWidth,
                            h = actualHeight,
                            fps = fps
                        )
                    )
                }

                override fun onDisconnected(d: CameraDevice) {
                    Log.w(TAG, "camera $cameraId disconnected")
                    closeQuietly(d)
                    listener?.onClosed(cameraId)
                }

                override fun onError(d: CameraDevice, error: Int) {
                    Log.w(TAG, "camera $cameraId error=$error")
                    closeQuietly(d)
                    listener?.onFailed(cameraId, "CameraDevice error $error")
                }
            }, h)
        } catch (e: CameraAccessException) {
            fail("CameraAccessException ${e.reason}")
        } catch (e: SecurityException) {
            fail("SecurityException ${e.message}")
        } catch (e: IllegalArgumentException) {
            fail("IllegalArgumentException ${e.message}")
        } catch (t: Throwable) {
            fail("${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /** 协议里的摄像头编号，由 Hub 在建 feeder 时回填 */
    @Volatile
    var protocolId: Int = -1

    private fun protocolId(): Int = protocolId

    private fun fail(reason: String) {
        running.set(false)
        encoder?.stop()
        encoder = null
        handlerThread?.quitSafely()
        handlerThread = null
        handler = null
        listener?.onFailed(cameraId, reason)
    }

    private fun closeQuietly(d: CameraDevice) {
        try {
            session?.close()
        } catch (_: Throwable) {
        }
        try {
            d.close()
        } catch (_: Throwable) {
        }
        encoder?.stop()
        encoder = null
        opened.set(false)
        running.set(false)
    }

    private fun startSession(d: CameraDevice, surface: Surface, fpsRange: android.util.Range<Int>) {
        try {
            val cb = object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    try {
                        val builder = d.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                        builder.addTarget(surface)
                        builder.set(
                            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                            fpsRange
                        )
                        builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                        s.setRepeatingRequest(builder.build(), null, handler)
                    } catch (t: Throwable) {
                        Log.w(TAG, "setRepeatingRequest failed", t)
                        fail("capture failed: ${t.message}")
                    }
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    fail("session configure failed")
                }
            }

            // minSdk 28 >= P，SessionConfiguration 一定可用；不需要留旧 API 分支
            val out = OutputConfiguration(surface)
            val cfg = SessionConfiguration(
                SessionConfiguration.SESSION_TYPE_REGULAR,
                listOf(out),
                Executor { r -> handler?.post(r) ?: Thread(r).start() },
                cb
            )
            d.createCaptureSession(cfg)
        } catch (e: CameraAccessException) {
            fail("createCaptureSession ${e.reason}")
        } catch (t: Throwable) {
            fail("createCaptureSession ${t.message}")
        }
    }

    private fun pickSize(map: android.hardware.camera2.params.StreamConfigurationMap?): Size {
        if (map == null) return Size(targetW, targetH)
        val sizes = try {
            map.getOutputSizes(ImageFormat.PRIVATE)
                ?: map.getOutputSizes(android.media.MediaCodec::class.java)
                ?: emptyArray()
        } catch (_: Throwable) {
            emptyArray()
        }
        if (sizes.isEmpty()) return Size(targetW, targetH)
        var best: Size? = null
        var bestScore = Long.MAX_VALUE
        for (s in sizes) {
            if (s.width <= 0 || s.height <= 0) continue
            // 面积差 + 长宽比差，越接近 16:9 越优先
            val areaDiff = Math.abs(s.width.toLong() * s.height - targetW.toLong() * targetH)
            val arDiff = Math.abs(s.width.toDouble() / s.height - 16.0 / 9.0)
            val score = areaDiff + (arDiff * 4_000_000).toLong()
            if (score < bestScore) {
                bestScore = score
                best = s
            }
        }
        return best ?: Size(targetW, targetH)
    }

    private fun pickFpsRange(ranges: Array<android.util.Range<Int>>?): android.util.Range<Int> {
        if (ranges.isNullOrEmpty()) return android.util.Range(targetFps, targetFps)
        var best: android.util.Range<Int>? = null
        for (r in ranges) {
            if (r.upper >= targetFps && r.lower <= targetFps) {
                if (best == null || r.upper < best.upper) best = r
            }
        }
        best?.let { return it }
        return ranges.maxByOrNull { it.upper } ?: android.util.Range(targetFps, targetFps)
    }

    fun stop() {
        running.set(false)
        opened.set(false)
        try {
            session?.close()
        } catch (_: Throwable) {
        }
        try {
            device?.close()
        } catch (_: Throwable) {
        }
        encoder?.stop()
        encoder = null
        handlerThread?.quitSafely()
        handlerThread = null
        handler = null
    }

    fun isOpen(): Boolean = opened.get()

    fun statsKbps(): Int = encoder?.statsKbps() ?: 0
    fun statsFps(): Int = encoder?.statsFps() ?: 0

    /** 请求一个同步帧（IDR）。返回 false 表示这路编码器没起来，请求发不出去。 */
    fun requestKeyframe(): Boolean {
        val enc = encoder ?: return false
        enc.requestKeyframe()
        return true
    }
}

/** Hub 内部用的槽位描述 */
data class CameraSlot(
    val cameraId: String,
    val name: String,
    val pos: String,
    val w: Int,
    val h: Int,
    val fps: Int
)
