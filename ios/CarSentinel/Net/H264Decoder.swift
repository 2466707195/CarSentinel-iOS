import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import AVFoundation

// === CarSentinel 360 · H.264 硬解（VideoToolbox）===
//
// 输入：协议 §5.3 的一个完整 Annex-B access unit（一帧，可能含 SPS/PPS/IDR/SEI 多个 NAL）。
// 输出：CMSampleBuffer，可直接喂给 AVSampleBufferDisplayLayer。
//
// 两个关键点：
//   1. SPS/PPS 每个关键帧都会重带（协议硬要求），所以每次拿到新的 SPS 就重建 format description
//     和解码 session —— 分辨率变了也不会花屏。
//   2. 送给 VideoToolbox 的 sample data 用 **AVCC 格式**（每个 NAL 前加 4 字节大端长度），
//      这是文档规定的格式；Annex-B 起始码在这里先剥掉再换成长度前缀。

private func csDecompressionOutputCallback(    _ refCon: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTDecodeInfoFlags,
    _ imageBuffer: CVImageBuffer?,
    _ pts: CMTime,
    _ duration: CMTime,
    _ dts: CMTime
) {
    guard status == noErr, let imageBuffer, let refCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.emitDecodedFrame(imageBuffer, presentationTime: pts)
}

/// `prepareLocked` 的产物：锁内拿到的三样东西 + 帧序号。
/// 拆出来是为了让「锁内」和「锁外」的边界在类型上就写死。
private struct PreparedFrame {
    let session: VTDecompressionSession
    let formatDescription: CMVideoFormatDescription
    let pts: CMTime
    let timescale: Int32
}

final class H264Decoder {

    /// 解码出一帧后回调。在 VideoToolbox 的内部队列上，**不是主线程**。
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0
    private var timescale: Int32 = 30
    private var lastSPS: [UInt8]?
    private var lastPPS: [UInt8]?
    /// 上一帧的 AVCC 输入。block buffer 不拷贝这份内存，所以必须由 self 持有
    private var retainedInput: [UInt8] = []

    deinit { teardown() }

    /// 协商好的帧率，用于生成显示时间戳。协议 §5.1 的 `OK <w> <h> <fps> h264`。
    func configure(fps: Int) {
        lock.lock(); defer { lock.unlock() }
        timescale = Int32(max(fps, 1))
    }

    /// 换摄像头时调用：丢掉旧 session，下一个关键帧会重建。
    func reset() {
        lock.lock(); defer { lock.unlock() }
        teardownLocked()
    }

    /// 喂一帧。`accessUnit` 是 Annex-B（起始码分隔）。
    ///
    /// 分两段，中间必须干净地交锁：
    ///   · 锁内：建/换 session、取帧序号。用 `defer` 保证任何路径都解锁。
    ///   · 锁外：Annex-B→AVCC、建 block buffer / sample buffer、投给 VideoToolbox。
    /// 拆开的意义：`VTDecompressionSessionInvalidate` 会等在途帧，其输出回调会
    /// 再进本对象；抱着锁做这些事就是死锁。而且主线程调 configure()/reset()
    /// 也不会被堵整整一帧。
    func decode(accessUnit: Data) {
        let nals = H264Decoder.splitNalUnits(accessUnit)
        guard !nals.isEmpty else { return }
        guard let prep = prepareLocked(nals: nals) else { return }
        submit(prep: prep, nals: nals)
    }

    /// 锁内段：返回 nil 表示「还没有可用的 session，等下一个带 SPS/PPS 的关键帧」。
    private func prepareLocked(nals: [[UInt8]]) -> PreparedFrame? {
        lock.lock()
        defer { lock.unlock() }

        // 1) 收集 SPS / PPS
        var sps: [UInt8]?
        var pps: [UInt8]?
        for nal in nals where nal.count >= 1 {
            switch nal[0] & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }

        // 2) SPS 变了（或首次）→ 重建 format description + session
        let spsChanged = sps != nil && sps != lastSPS
        if let sps, let pps, (spsChanged || session == nil) {
            if let fmt = H264Decoder.makeFormatDescription(sps: sps, pps: pps) {
                teardownLocked()
                formatDescription = fmt
                lastSPS = sps
                lastPPS = pps
                if !makeSessionLocked(formatDescription: fmt) {
                    formatDescription = nil
                    return nil
                }
            } else if session == nil {
                return nil
            }
        }

        guard let session, let fmt = formatDescription else { return nil }

        // 时间戳：本地单调计数器，避免车机时钟跳变导致画面卡顿
        let ts = timescale
        let pts = CMTime(value: frameIndex, timescale: ts)
        frameIndex += 1
        return PreparedFrame(session: session, formatDescription: fmt, pts: pts, timescale: ts)
    }

    /// 锁外段：构建并投递一帧。
    private func submit(prep: PreparedFrame, nals: [[UInt8]]) {
        // 3) Annex-B → AVCC
        var avcc = Data()
        avcc.reserveCapacity(4 * nals.count + 64)
        for nal in nals {
            var lenBE = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &lenBE, count: 4))
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }

        // 4) 建 block buffer。这里让 block buffer 直接引用 avcc 的内存
        //    （kCFAllocatorNull = 不拷贝、不持有），同时把数组留在 self 上，
        //    保证整个 submit() 期间内存有效；函数返回前会
        //    VTDecompressionSessionWaitForAsynchronousFrames，那时已用完。
        let bytes = [UInt8](avcc)
        var blockBuffer: CMBlockBuffer?
        let cbStatus: OSStatus = bytes.withUnsafeBufferPointer { bp -> OSStatus in
            guard let base = bp.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: base),
                blockLength: bytes.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                length: bytes.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard cbStatus == noErr, let bb = blockBuffer else { return }
        retainedInput = bytes

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: prep.timescale),
            presentationTimeStamp: prep.pts,
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: prep.formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingEntryArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeEntryArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        var flags = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(
            prep.session, sampleBuffer: sb,
            decodeFlags: [._EnableAsynchronousDecompression],
            frameRefcon: nil, infoFlagsOut: &flags)
        if st != noErr {
            // 单帧失败不致命，等下一个关键帧
            return
        }
        // 等这一帧真的解完 —— 之后 retainedInput 才可以被下一帧覆盖
        VTDecompressionSessionWaitForAsynchronousFrames(prep.session)
    }

    // MARK: - 解码回调

    func emitDecodedFrame(_ imageBuffer: CVImageBuffer, presentationTime: CMTime) {
        // 绝不在这里取锁：teardownLocked() 是抱着锁调 VTDecompressionSessionInvalidate 的，
        // 而 Invalidate 会等在途帧、回调再进这里 —— 取锁就是锁倒置死锁。
        // timescale 直接从送进来的 CMTime 上取，它本来就带着正确的 timescale。
        let ts = presentationTime.timescale
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: ts),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )
        var out: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleTiming: &timing,
            sampleCount: 1,
            sampleSize: 0,
            sampleBufferOut: &out
        )
        guard st == noErr, let out else { return }
        onSampleBuffer?(out)
    }

    // MARK: - 内部

    private func makeSessionLocked(formatDescription: CMVideoFormatDescription) -> Bool {
        let attrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA)
        ] as CFDictionary

        // 注意：VTDecompressionOutputCallback 是 C 函数指针类型别名，不是结构体。
        // 真正要构造的是 VTDecompressionOutputCallbackRecord。
        var callback = VTDecompressionOutputCallbackRecord()
        callback.decompressionOutputCallback = csDecompressionOutputCallback
        callback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs,
            outputCallback: &callback,
            outputCallbackRefCon: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { return false }
        session = newSession
        return true
    }

    private func teardownLocked() {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        frameIndex = 0
    }

    private func teardown() {
        lock.lock(); defer { lock.unlock() }
        teardownLocked()
    }

    // MARK: - NAL 切分

    /// 按 Annex-B 起始码切出所有 NAL（不含起始码）。
    static func splitNalUnits(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        guard bytes.count > 3 else { return [] }

        struct StartCode { let pos: Int; let len: Int }
        var codes: [StartCode] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                let isFourByte = (i > 0 && bytes[i - 1] == 0)
                codes.append(StartCode(pos: isFourByte ? i - 1 : i, len: isFourByte ? 4 : 3))
                i += 3
            } else {
                i += 1
            }
        }
        guard !codes.isEmpty else { return [] }

        var out: [[UInt8]] = []
        for (idx, c) in codes.enumerated() {
            let start = c.pos + c.len
            let end = (idx + 1 < codes.count) ? codes[idx + 1].pos : bytes.count
            if end > start {
                out.append(Array(bytes[start..<end]))
            }
        }
        return out
    }

    private static func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?

        // ⚠️ 本机没有 Xcode，下面这个调用的指针数组可选性没法验证。
        //    C 原型是 `const uint8_t * const parameterSetPointers[]`，
        //    Swift 通常导入成 UnsafePointer<UnsafePointer<UInt8>?>，所以这里写成可选元素。
        //    如果 CI 报：
        //        cannot convert value of type '[UnsafePointer<UInt8>?]' to expected
        //        argument type 'UnsafePointer<UnsafePointer<UInt8>>'
        //    就把下一行的 `?` 去掉，改成：
        //        let pointers: [UnsafePointer<UInt8>] = [sp, pp]
        //    两种写法互斥，只可能对一种。
        let status: OSStatus = sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                guard let sp = spsBuf.baseAddress, let pp = ppsBuf.baseAddress else {
                    return kCMFormatDescriptionBridgeError_InvalidParameter
                }
                let pointers: [UnsafePointer<UInt8>?] = [sp, pp]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt
                )
            }
        }
        guard status == noErr, let fmt else { return nil }
        return fmt
    }
}
