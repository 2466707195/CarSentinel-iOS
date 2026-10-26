package com.carsentinel.carunit.camera

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Camera
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import com.carsentinel.carunit.net.LogLevel
import com.carsentinel.carunit.net.LogBus
import org.json.JSONObject

/**
 * 设备诊断：一次把「这台机器到底有什么摄像头、能不能用」全查清楚。
 *
 * 为什么需要它：车机上摄像头打不开的原因千奇百怪 —— 没权限、系统没报告摄像头、
 * 外接 USB/UVC 没被 Camera2 枚举、模拟 AV-IN 根本没进 Android。
 * 把这些一次性列出来，用户就不用反复试。
 *
 * 输出：
 *  · 日志（LogScreen 可见）
 *  · JSON（可复制，排查时贴给别人）
 */
object DeviceProbe {

    private const val TAG = "DeviceProbe"

    /** 一次完整诊断，结果同时进日志和返回 JSON */
    fun run(context: Context, logs: LogBus): String {
        val root = JSONObject()
        try {
            root.put("build", buildInfo())
            root.put("permissions", permissionInfo(context))
            root.put("camera2", camera2Info(context))
            root.put("camera1", camera1Info(context))
            root.put("usb", usbInfo(context))
            root.put("memory", memoryInfo(context))
        } catch (t: Throwable) {
            Log.w(TAG, "probe failed", t)
            logs.error("诊断过程出错：${t.javaClass.simpleName}: ${t.message}")
        }
        return root.toString(2)
    }

    /** 诊断结果写成人类可读的日志行 */
    fun logSummary(context: Context, logs: LogBus) {
        logs.info("===== 设备诊断开始 =====")

        // 权限
        val camGranted = context.checkSelfPermission(android.Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        logs.info("相机权限：${if (camGranted) "已授予" else "未授予（打开摄像头必失败）"}")

        // Camera2
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cm == null) {
            logs.error("拿不到 CameraManager，这台设备可能没有相机硬件")
        } else {
            var ids: Array<String>? = null
            var err: String? = null
            try {
                ids = cm.cameraIdList
            } catch (t: Throwable) {
                err = "${t.javaClass.simpleName}: ${t.message}"
            }
            when {
                err != null -> logs.error("Camera2 枚举失败：$err")
                ids == null -> logs.warn("Camera2 返回 null（异常）")
                ids.isEmpty() -> logs.warn(
                    "Camera2 未报告任何摄像头。" +
                        "如果是外接 USB/模拟摄像头，标准 Camera2 通常拿不到，需要厂商接口或硬件采集。"
                )
                else -> {
                    logs.info("Camera2 报告 ${ids.size} 个摄像头")
                    for (id in ids) {
                        describe(cm, id, logs)
                    }
                }
            }
        }

        // Camera1（老 API，有些车机只在老 API 里暴露）
        val n1 = Camera.getNumberOfCameras()
        logs.info("旧 Camera API 报告摄像头数：$n1")
        if (n1 > 0 && (ids2(context) == 0)) {
            logs.warn("旧 API 有摄像头但 Camera2 没有 —— 这台设备的摄像头只走老 API，需要换采集实现")
        }

        // USB
        val usbVideo = usbVideoDevices(context)
        if (usbVideo.isEmpty()) {
            logs.info("USB：没有视频类设备")
        } else {
            logs.info("USB 视频类设备 ${usbVideo.size} 个：")
            for (d in usbVideo) {
                logs.info(
                    "  USB ${d.deviceName}  vid=0x${Integer.toHexString(d.vendorId)} " +
                        "pid=0x${Integer.toHexString(d.productId)}  ${d.productName ?: "未命名"}"
                )
            }
            if (ids2(context) == 0) {
                logs.warn(
                    "有 USB 视频设备但 Camera2 枚举不到 —— 说明系统的 UVC 驱动没把它注册成摄像头。" +
                        "纯 Java 层无法直采 UVC（Android 的 UsbRequest 不支持 isochronous 传输），" +
                        "需要 native UVC 库或让系统加载 UVC 驱动。"
                )
            }
        }

        logs.info("===== 设备诊断结束 =====")
    }

    // ---------------- 各部分 ----------------

    private fun ids2(context: Context): Int {
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return -1
        return try {
            cm.cameraIdList?.size ?: -1
        } catch (_: Throwable) {
            -1
        }
    }

    private fun buildInfo(): JSONObject {
        val o = JSONObject()
        o.put("manufacturer", Build.MANUFACTURER)
        o.put("model", Build.MODEL)
        o.put("device", Build.DEVICE)
        o.put("android", Build.VERSION.RELEASE)
        o.put("api", Build.VERSION.SDK_INT)
        o.put("hardware", Build.HARDWARE)
        o.put("board", Build.BOARD)
        return o
    }

    private fun permissionInfo(context: Context): JSONObject {
        val o = JSONObject()
        o.put(
            "camera",
            context.checkSelfPermission(android.Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
        o.put(
            "usbHost",
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
        )
        return o
    }

    private fun camera2Info(context: Context): JSONObject {
        val o = JSONObject()
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cm == null) {
            o.put("error", "no CameraManager")
            return o
        }
        val arr = org.json.JSONArray()
        try {
            val ids = cm.cameraIdList
            o.put("count", ids?.size ?: 0)
            for (id in ids ?: emptyArray()) {
                arr.put(describeJson(cm, id))
            }
        } catch (t: Throwable) {
            o.put("error", "${t.javaClass.simpleName}: ${t.message}")
        }
        o.put("cameras", arr)
        return o
    }

    private fun describe(cm: CameraManager, id: String, logs: LogBus) {
        try {
            val ch = cm.getCameraCharacteristics(id)
            val facing = ch.get(CameraCharacteristics.LENS_FACING)
            val facingName = when (facing) {
                CameraCharacteristics.LENS_FACING_FRONT -> "前置"
                CameraCharacteristics.LENS_FACING_BACK -> "后置"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "外接"
                else -> "未知($facing)"
            }
            val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes = try {
                map?.getOutputSizes(android.graphics.ImageFormat.PRIVATE)?.take(6)
                    ?: emptyList()
            } catch (_: Throwable) {
                emptyList()
            }
            val level = ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
            val levelName = when (level) {
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
                else -> "?($level)"
            }
            logs.info(
                "  摄像头 $id：$facingName · 硬件级别 $levelName · " +
                    "支持尺寸 ${sizes.joinToString { "${it.width}x${it.height}" }}"
            )
        } catch (t: Throwable) {
            logs.warn("  摄像头 $id 特性读取失败：${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun describeJson(cm: CameraManager, id: String): JSONObject {
        val o = JSONObject()
        o.put("id", id)
        try {
            val ch = cm.getCameraCharacteristics(id)
            o.put("facing", ch.get(CameraCharacteristics.LENS_FACING))
            o.put("hardwareLevel", ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL))
            val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes = map?.getOutputSizes(android.graphics.ImageFormat.PRIVATE)
                ?: emptyArray()
            o.put(
                "sizes",
                sizes.take(8).joinToString(", ") { "${it.width}x${it.height}" }
            )
        } catch (t: Throwable) {
            o.put("error", "${t.javaClass.simpleName}: ${t.message}")
        }
        return o
    }

    private fun camera1Info(context: Context): JSONObject {
        val o = JSONObject()
        try {
            o.put("count", Camera.getNumberOfCameras())
        } catch (t: Throwable) {
            o.put("error", t.message)
        }
        return o
    }

    private fun usbVideoDevices(context: Context): List<UsbDevice> {
        val um = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return emptyList()
        return try {
            um.deviceList.values.filter { isVideoClass(it) }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /** UVC：接口 class 0x0E，或者设备 class 0x0E，或者接口 subclass 0x02 (video streaming) */
    private fun isVideoClass(d: UsbDevice): Boolean {
        if (d.deviceClass == UsbConstants.USB_CLASS_VIDEO) return true
        for (i in 0 until d.interfaceCount) {
            val itf = d.getInterface(i)
            if (itf.interfaceClass == UsbConstants.USB_CLASS_VIDEO) return true
            // UVC 的 VideoStreaming 接口：class=0x0E subclass=0x02
            if (itf.interfaceClass == UsbConstants.USB_CLASS_VIDEO &&
                itf.interfaceSubclass == 2
            ) {
                return true
            }
        }
        return false
    }

    private fun usbInfo(context: Context): JSONObject {
        val o = JSONObject()
        val um = context.getSystemService(Context.USB_SERVICE) as? UsbManager
        if (um == null) {
            o.put("error", "no UsbManager")
            return o
        }
        o.put("hostSupported", context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST))
        val all = org.json.JSONArray()
        val video = org.json.JSONArray()
        try {
            for ((name, d) in um.deviceList) {
                val jo = JSONObject()
                jo.put("name", name)
                jo.put("deviceClass", d.deviceClass)
                jo.put("vendorId", "0x" + Integer.toHexString(d.vendorId))
                jo.put("productId", "0x" + Integer.toHexString(d.productId))
                jo.put("productName", d.productName ?: "")
                jo.put("interfaces", d.interfaceCount)
                all.put(jo)
                if (isVideoClass(d)) video.put(jo)
            }
        } catch (t: Throwable) {
            o.put("error", t.message)
        }
        o.put("total", all.length())
        o.put("videoDevices", video)
        return o
    }

    @Suppress("DEPRECATION")
    private fun memoryInfo(context: Context): JSONObject {
        val o = JSONObject()
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            o.put("totalMem", mi.totalMem)
            o.put("availMem", mi.availMem)
            o.put("lowMemory", mi.lowMemory)
        } catch (_: Throwable) {
        }
        return o
    }
}
