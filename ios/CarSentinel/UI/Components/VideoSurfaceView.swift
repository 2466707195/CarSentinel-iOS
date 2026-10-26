import SwiftUI
import UIKit
import AVFoundation
import CoreMedia

// === CarSentinel 360 · 视频画面出口 ===
// 解码器在后台线程产出 CMSampleBuffer，最终要送到 AVSampleBufferDisplayLayer。
// 这一层只做两件事：主线程投递 + 背压丢帧。

/// 一路画面的出口。由 SwiftUI 视图在 onAppear 时 attach。
final class VideoFrameSink {

    private var layer: AVSampleBufferDisplayLayer?
    private let lock = NSLock()
    private var dropped = 0

    /// 显示层挂上来。重复 attach 会先 flush 旧的。
    func attach(_ newLayer: AVSampleBufferDisplayLayer) {
        lock.lock()
        let old = layer
        layer = newLayer
        dropped = 0
        lock.unlock()
        if old !== newLayer {
            DispatchQueue.main.async { old?.flush() }
        }
        DispatchQueue.main.async { newLayer.flush() }
    }

    func detach() {
        lock.lock()
        let old = layer
        layer = nil
        lock.unlock()
        DispatchQueue.main.async { old?.flush() }
    }

    /// 投递一帧。显示层忙就直接丢 —— 视频流丢帧永远好过堆积。
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let target = layer
        lock.unlock()
        guard let target else { return }

        DispatchQueue.main.async { [weak self] in
            if target.requiresFlushToResumeDecoding {
                target.flush()
                return
            }
            if target.isReadyForMoreMediaData {
                target.enqueue(sampleBuffer)
            } else {
                self?.noteDrop()
            }
        }
    }

    private func noteDrop() {
        lock.lock(); dropped += 1; lock.unlock()
    }

    var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }
}

/// 承载 AVSampleBufferDisplayLayer 的 UIView。
final class VideoSurfaceUIView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var videoLayer: AVSampleBufferDisplayLayer {
        guard let l = layer as? AVSampleBufferDisplayLayer else {
            fatalError("VideoSurfaceUIView layer is not AVSampleBufferDisplayLayer")
        }
        return l
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect
        // 关掉内置的占位底色，让「信号中断」浮层自己画
        videoLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// SwiftUI 包装。
struct VideoSurfaceView: UIViewRepresentable {

    let sink: VideoFrameSink

    func makeUIView(context: Context) -> VideoSurfaceUIView {
        let v = VideoSurfaceUIView()
        sink.attach(v.videoLayer)
        return v
    }

    func updateUIView(_ uiView: VideoSurfaceUIView, context: Context) {}
}
