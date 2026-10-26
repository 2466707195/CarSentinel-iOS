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
 * 摄像头中枢：枚举 CameraManager.cameraIdList → 位置映射 → 打开 → 失败可重试。
 *
 * 位置映射（稳定，重启不变）：
 *  - LENS_FACING.FRONT    → "front"
 *  - LENS_FACING.BACK     → "rear"
 *  - LENS_FACING.EXTERNAL → 按 cameraId 字符串哈希取模 3，轮转 left / right / inner。
 *    用哈希而不是枚举下标：哪怕旁边那路掉线，剩下的外置摄像头位置也不会漂移。
 *  - 其他                  → "unknown"
 *
 * 关于重试：很多车机首次枚举时摄像头服务还没就绪，或者权限刚授予，
 * 第一次全失败很常见。所以这里保留 enumeratedIds，允许外部反复调 retry()。
 * 只有「枚举结果本身为空」才判定为真没摄像头。
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

    /** 只有「成功打开」的摄像头才进这里 —— announce / cameras 列表就是它 */
    private val infos = ConcurrentHashMap<Int, CameraInfo>()

    /** cameraId → (name, pos)，枚举阶段就记下，重试时复用 */
    private val pendingNames = ConcurrentHashMap<String, Pair<String, String>>()

    /** 枚举出来的全部 cameraId，重试的依据 */
    @Volatile
    private var enumeratedIds: List<String> = emptyList()

    /** cameraId → 最近一次失败原因，重试前清掉 */
    private val failedReasons = ConcurrentHashMap<String, String>()

    @Volatile
    var lastError: String? = null
        private set

    @Volatile
    var retryCount: Int = 0
        private set

    private var started = false

    /** cameraId → 协议 id，重启后同一台机器上保持稳定 */
    private fun stableId(cameraId: String, index: Int): Int = index

    // ---------------- 对外状态 ----------------

    /** 枚举到的摄像头总数（不是打开数） */
    fun enumeratedCount(): Int = enumeratedIds.size

    /** 成功打开的数量 */
    fun openedCount(): Int = infos.size

    /** 是否还在重试中（由 StreamService 驱动） */
    @Volatile
    var retrying: Boolean = false
        private set

    fun setRetrying(v: Boolean) { retrying = v }

    /** 一句话说明当前为什么没有画面，给状态页显示 */
    fun statusHint(): String {
        if (enumeratedIds.isEmpty()) {
            return lastError ?: "未枚举到摄像头"
        }
        if (infos.isNotEmpty()) return ""
        val reasons = failedReasons.values.distinct()
        if (reasons.isEmpty()) return "正在打开 ${enumeratedIds.size} 路摄像头…"
        return reasons.joinToString("；").take(200)
    }

    // ---------------- 生命周期 ----------------

    fun start() {
        if (started) return
        started = true
        retryCount = 0
        logs.info("枚举摄像头…")
        var ids: Array<String> = emptyArray()
        try {
            ids = manager.cameraIdList ?: emptyArray()
        } catch (t: Throwable) {
            lastError = "枚举摄像头失败：${t.message}"
            logs.error(lastError!!)
        }
        enumeratedIds = ids.toList()

        if (enumeratedIds.isEmpty()) {
            logs.warn("没有发现任何摄像头")
            delegate?.onCameraSetChanged(emptyList())
            return
        }
        logs.info("枚举到 ${enumeratedIds.size} 个摄像头：${enumeratedIds.joinToString()}")
        openAll()
    }

    /** 打开所有还没打开的摄像头。已打开的不动。 */
    fun retry() {
        if (enumeratedIds.isEmpty()) {
            // 上次枚举为空，可能摄像头服务还没起来，重新枚举一次
            start()
            return
        }
        retryCount += 1
        logs.info("重试打开摄像头（第 $retryCount 次）")
        openAll()
    }

    private fun openAll() {
        for ((index, camId) in enumeratedIds.withIndex()) {
            // 已经打开的就跳过
            if (feeders.values.any { it.cameraId == camId && it.isOpen() }) continue
            // 之前失败过、feeder 还残存的先清掉
            feeders.values.filter { it.cameraId == camId }.forEach { old ->
                try { old.stop() } catch (_: Throwable) {}
                feeders.values.remove(old)
            }
            failedReasons.remove(camId)

            var pos = Protocol.POS_UNKNOWN
            var name = "摄像头 $index"
            try {
                val ch = manager.getCameraCharacteristics(camId)
                pos = when (ch.get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_FRONT -> Protocol.POS_FRONT
                    CameraCharacteristics.LENS_FACING_BACK -> Protocol.POS_REAR
                    CameraCharacteristics.LENS_FACING_EXTERNAL -> {
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
            // 注意：这里不再预填 infos。只有 onOpened 才算「可服务」，
            // 否则打开失败前会有一瞬间的假数据，announce 也会广播不存在的摄像头。
            try {
                feeder.open()
            } catch (t: Throwable) {
                Log.w(TAG, "open $camId threw", t)
                feeder.listener?.onFailed(camId, "${t.javaClass.simpleName}: ${t.message}")
            }
        }
        logs.info("开始打开 ${enumeratedIds.size} 个摄像头（第 ${retryCount + 1} 次尝试）")
    }

    fun shutdown() {
        started = false
        retrying = false
        for (f in feeders.values) {
            try {
                f.stop()
            } catch (_: Throwable) {
            }
        }
        feeders.clear()
        infos.clear()
        pendingNames.clear()
        failedReasons.clear()
        enumeratedIds = emptyList()
        lastError = null
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
        failedReasons.remove(slot.cameraId)
        infos[id] = CameraInfo(
            id = id,
            name = name,
            pos = pos,
            w = slot.w,
            h = slot.h,
            fps = slot.fps
        )
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
        failedReasons[cameraId] = reason
        lastError = reason
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
        delegate?.onCameraSetChanged(currentCameras())
    }
}
