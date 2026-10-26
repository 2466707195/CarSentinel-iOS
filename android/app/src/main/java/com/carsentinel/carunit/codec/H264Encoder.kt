package com.carsentinel.carunit.codec

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import com.carsentinel.carunit.net.Protocol
import com.carsentinel.carunit.net.START_CODE
import com.carsentinel.carunit.net.concat
import com.carsentinel.carunit.net.normalizeParameterSets
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * 一路 H.264 硬编码器：Surface 输入，drain 循环跑在自己的线程上。
 *
 * - `BUFFER_FLAG_CODEC_CONFIG`（SPS/PPS）只缓存，不当帧发。
 * - `BUFFER_FLAG_KEY_FRAME` 时，把缓存的 SPS + PPS + IDR 拼成**一帧**发出
 *   （Annex-B，`00 00 00 01` 前缀），满足 PROTOCOL §5.3 的硬要求。
 */
class H264Encoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int = 30,
    private val bitrate: Int = 2_500_000,
    private val onFrame: (payload: ByteArray, keyframe: Boolean, ptsUs: Long) -> Unit
) {
    companion object {
        private const val TAG = "H264Encoder"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val IFRAME_INTERVAL_SEC = 1
        private const val DRAIN_TIMEOUT_US = 100_000L
    }

    private val codec: MediaCodec = MediaCodec.createEncoderByType(MIME)
    private val running = AtomicBoolean(false)
    private var drainThread: Thread? = null

    @Volatile
    private var csd: ByteArray? = null

    /** 送进 Camera2 capture session 的输入面 */
    lateinit var inputSurface: Surface
        private set

    private val frameCount = AtomicLong(0)
    private val encodedBytes = AtomicLong(0)
    private var lastStatAt = System.currentTimeMillis()
    private var lastStatBytes = 0L
    private var lastStatFrames = 0L

    @Volatile
    var lastKbps: Int = 0
        private set

    @Volatile
    var lastFps: Int = 0
        private set

    fun start() {
        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_INTERVAL_SEC)
            setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
            )
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()
        running.set(true)
        drainThread = Thread({ drainLoop() }, "cs360-enc-$width x$height").apply {
            start()
        }
    }

    /** 由控制通道 keyframe 消息触发：强制下一个同步帧是 IDR */
    fun requestKeyframe() {
        if (!running.get()) return
        try {
            val params = android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            codec.setParameters(params)
        } catch (t: Throwable) {
            Log.w(TAG, "requestKeyframe failed", t)
        }
    }

    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()
        while (running.get()) {
            try {
                val index = codec.dequeueOutputBuffer(info, DRAIN_TIMEOUT_US)
                when {
                    index >= 0 -> {
                        val buf: ByteBuffer? = codec.getOutputBuffer(index)
                        if (buf != null && info.size > 0) {
                            val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                            val bytes = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            buf.get(bytes)

                            if (isConfig) {
                                // SPS/PPS：只缓存，绝不作为帧下发。
                                // 顺手规范成「每个 NAL 自带起始码」，防个别设备不给起始码
                                val prev = csd
                                csd = if (prev == null) {
                                    normalizeParameterSets(bytes)
                                } else {
                                    concat(prev, normalizeParameterSets(bytes))
                                }
                            } else {
                                val payload: ByteArray
                                val key: Boolean
                                if (isKey) {
                                    val csdNow = csd
                                    payload = if (csdNow != null) {
                                        concat(csdNow, START_CODE, bytes)
                                    } else {
                                        bytes
                                    }
                                    key = true
                                } else {
                                    payload = bytes
                                    key = false
                                }
                                frameCount.incrementAndGet()
                                encodedBytes.addAndGet(payload.size.toLong())
                                onFrame(payload, key, info.presentationTimeUs)
                            }
                        }
                        codec.releaseOutputBuffer(index, false)
                    }

                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                    index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                }
            } catch (t: Throwable) {
                if (running.get()) Log.w(TAG, "drain error", t)
                break
            }
            sampleStats()
        }
    }

    private fun sampleStats() {
        val now = System.currentTimeMillis()
        val dt = now - lastStatAt
        if (dt < 1000) return
        val bytes = encodedBytes.get()
        val frames = frameCount.get()
        lastKbps = (((bytes - lastStatBytes) * 8) / dt).toInt()
        lastFps = (((frames - lastStatFrames) * 1000) / dt).toInt()
        lastStatAt = now
        lastStatBytes = bytes
        lastStatFrames = frames
    }

    fun statsKbps(): Int = lastKbps
    fun statsFps(): Int = lastFps

    fun stop() {
        if (!running.getAndSet(false)) return
        try {
            codec.signalEndOfInputStream()
        } catch (_: Throwable) {
        }
        try {
            codec.stop()
        } catch (_: Throwable) {
        }
        try {
            codec.release()
        } catch (_: Throwable) {
        }
        try {
            inputSurface.release()
        } catch (_: Throwable) {
        }
        drainThread?.interrupt()
        drainThread = null
        csd = null
    }
}
