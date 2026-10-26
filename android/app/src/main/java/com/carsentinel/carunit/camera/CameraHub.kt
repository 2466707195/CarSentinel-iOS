package com.carsentinel.carunit.camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Log
import com.carsentinel.carunit.net.CameraInfo
import com.carsentinel.carunit.net.CameraSink
import com.carsentinel.carunit.net.LogBus
import com.carsentinel.carunit.net.Protocol
import java.util.concurrent.ConcurrentHashMap

/**
 * 摄像头中枢：枚举 CameraManager.cameraIdList → 位置映射 → 并发打开。
 *
 * 位置映射（稳定，重启不变）：
 *  - LENS_FACING.FRONT    → "front"
 *  - LENS_FACING.BACK     → "rear"
 *  - LENS_FACING.EXTERNAL → 按 cameraId 字符串哈希取模 3，轮转 left / right / inner。
 *    用哈希而不是枚举下标：哪怕旁边那路掉线，剩下的外置摄像头位置也不会漂移。
 *  - 其他                  → "unknown"
 *
 * 打开失败的摄像头会被标成 unavailable 并从服务列表里移除，绝不影响启动、绝不让进程崩。
 */
class CameraHub(
    context: Context,
    private val logs: LogBus
) : CameraFeeder.Listener {

    interface Delegate {
        /** 实际打开的集合变了（可能变大也可能变小） */
        fun onCameraSetChanged(infos: List<CameraInfo>)

        /** 某路实时状态 */
        fun onCameraState(id: Int, active: Boolean, fps: Int, bitrateKbps: Int)
    }

    companion object {
        private const val TAG = "CameraHub"
        private const val EXTERNAL_CYCLE = 3
    }

    var delegate: Delegate? = null

    /** 协议 id → 帧扇出点，由 StreamService 注入 */
    var sinkProvider: (Int) -> CameraSink? = { null }

    private val manager: CameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private val feeders = ConcurrentHashMap<Int, CameraFeeder>()
    private val infos = ConcurrentHashMap<Int, CameraInfo>()
    private val pendingNames = ConcurrentHashMap<String, Pair<String, String>>() // camId -> (name, pos)
    private var started = false

    /** cameraId → 协议 id，重启后同一台机器上保持稳定 */
    private fun stableId(cameraId: String, index: Int): Int = index

    fun start() {
        if (started) return
        started = true
        logs.info("枚举摄像头…")
        var ids: Array<String> = emptyArray()
        try {
            ids = manager.cameraIdList ?: emptyArray()
        } catch (t: Throwable) {
            logs.error("枚举摄像头失败：${t.message}")
        }
        if (ids.isEmpty()) {
            logs.warn("没有发现任何摄像头")
            delegate?.onCameraSetChanged(emptyList())
            return
        }

        for ((index, camId) in ids.withIndex()) {
            var pos = Protocol.POS_UNKNOWN
            var name = "摄像头 $index"
            try {
                val ch = manager.getCameraCharacteristics(camId)
                pos = when (ch.get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_FRONT -> Protocol.POS_FRONT
                    CameraCharacteristics.LENS_FACING_BACK -> Protocol.POS_REAR
                    CameraCharacteristics.LENS_FACING_EXTERNAL -> {
                        // 稳定轮转：同一 cameraId 永远拿到同一个位置
                        val slot = Math.abs(camId.hashCode()) % EXTERNAL_CYCLE
                        when (slot) {
                            0 -> Protocol.POS_LEFT
                            1 -> Protocol.POS_RIGHT
                            else -> Protocol.POS_INNER
                        }
                    }
                    else -> Protocol.POS_UNKNOWN
                }
                name = Protocol.posName(pos)
            } catch (t: Throwable) {
                logs.warn("读取摄像头 $camId 特性失败：${t.message}")
            }
            pendingNames[camId] = name to pos
            val id = stableId(camId, index)

            val feeder = CameraFeeder(
                cameraId = camId,
                manager = manager,
                targetW = 1280,
                targetH = 720,
                targetFps = 30,
                bitrate = 2_500_000
            )
            feeder.protocolId = id
            feeder.listener = this
            feeder.sink = sinkProvider(id)
            feeders[id] = feeder
            infos[id] = CameraInfo(
                id = id,
                name = name,
                pos = pos,
                w = 1280,
                h = 720,
                fps = 30
            )
            // 并发打开：openCamera 本身是异步的，这里连续调用即并发
            try {
                feeder.open()
            } catch (t: Throwable) {
                Log.w(TAG, "open $camId threw", t)
                feeder.listener?.onFailed(camId, "${t.javaClass.simpleName}")
            }
        }
        logs.info("开始打开 ${ids.size} 个摄像头")
    }

    fun shutdown() {
        started = false
        for (f in feeders.values) {
            try {
                f.stop()
            } catch (_: Throwable) {
            }
        }
        feeders.clear()
        infos.clear()
        pendingNames.clear()
    }

    fun currentCameras(): List<CameraInfo> = infos.values.sortedBy { it.id }

    fun feeder(id: Int): CameraFeeder? = feeders[id]

    fun feederByCameraId(cameraId: String): CameraFeeder? =
        feeders.values.firstOrNull { it.cameraId == cameraId }

    fun requestKeyframe(id: Int): Boolean = feeder(id)?.requestKeyframe() ?: false

    // ---------- CameraFeeder.Listener ----------

    override fun onOpened(slot: CameraSlot) {
        val id = feederByCameraId(slot.cameraId)?.protocolId ?: return
        val (name, pos) = pendingNames[slot.cameraId] ?: (slot.name to slot.pos)
        val info = CameraInfo(
            id = id,
            name = name,
            pos = pos,
            w = slot.w,
            h = slot.h,
            fps = slot.fps
        )
        infos[id] = info
        logs.info("摄像头 $id（$name）已打开 ${slot.w}x${slot.h}@${slot.fps}")
        publish()
    }

    override fun onFailed(cameraId: String, reason: String) {
        val feeder = feederByCameraId(cameraId)
        val id = feeder?.protocolId
        if (id != null) {
            infos.remove(id)
            feeders.remove(id)
        }
        logs.warn("摄像头 $cameraId 不可用：$reason")
        publish()
    }

    override fun onFrame(cameraId: String, bytes: Int) = Unit

    override fun onClosed(cameraId: String) {
        val feeder = feederByCameraId(cameraId) ?: return
        val id = feeder.protocolId
        infos.remove(id)
        feeders.remove(id)
        logs.warn("摄像头 $cameraId 已断开")
        publish()
    }

    private fun publish() {
        val list = currentCameras()
        delegate?.onCameraSetChanged(list)
    }
}
