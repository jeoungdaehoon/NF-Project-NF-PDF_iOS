import AVFoundation
import Foundation

/// A single microphone feeds both the uninterrupted original and finalized
/// one-minute AAC files. Recognition never executes on the audio callback.
nonisolated final class PortalMeetingLiveCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let originalURL: URL
    private let folder: URL
    private let maxSeconds: Double
    private let onPart: @Sendable () -> Void
    private let onLimit: @Sendable () -> Void
    private var original: AVAudioFile?
    private var part: AVAudioFile?
    private var format: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0
    private var partFrames: AVAudioFramePosition = 0
    private var index = 0
    private var isPaused = false
    private var ended = false
    private var captureError: Error?
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(frames) / (format?.sampleRate ?? 44100) }
    var paused: Bool { lock.lock(); defer { lock.unlock() }; return isPaused }

    init(original: URL, folder: URL, maxSeconds: Double, onPart: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void) {
        self.originalURL = original; self.folder = folder; self.maxSeconds = maxSeconds; self.onPart = onPart; self.onLimit = onLimit
    }
    func start() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("pending"), withIntermediateDirectories: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw failure("마이크 입력을 준비하지 못했습니다.") }
        self.format = format
        original = try writer(originalURL, format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.consume(buffer) }
        do { engine.prepare(); try engine.start() } catch { input.removeTap(onBus: 0); original = nil; throw error }
    }
    func pause() { lock.lock(); isPaused = true; lock.unlock() }
    func resume() throws { if !engine.isRunning { engine.prepare(); try engine.start() }; lock.lock(); isPaused = false; lock.unlock() }
    func finish() throws {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        ended = true
        try closePart(); original = nil
        if let captureError { throw captureError }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func writer(_ url: URL, _ format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64000], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !isPaused, !ended, let format else { return }
        do {
            let maxFrames = AVAudioFramePosition(maxSeconds * format.sampleRate)
            let minuteFrames = AVAudioFramePosition(60 * format.sampleRate)
            var offset: AVAudioFrameCount = 0
            while offset < buffer.frameLength && frames < maxFrames {
                if part == nil { part = try writer(folder.appendingPathComponent("pending").appendingPathComponent(String(format: "%04d.m4a", index)), format) }
                let count = AVAudioFrameCount(min(Int64(buffer.frameLength - offset), minuteFrames - partFrames, maxFrames - frames))
                guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw failure("음성 버퍼를 준비하지 못했습니다.") }
                slice.frameLength = count
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                for channel in 0..<source.count {
                    guard let from = source[channel].mData, let to = target[channel].mData else { throw failure("음성 입력을 읽지 못했습니다.") }
                    memcpy(to, from.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
                }
                try original?.write(from: slice); try part?.write(from: slice)
                offset += count; frames += Int64(count); partFrames += Int64(count)
                if partFrames >= minuteFrames { try closePart() }
            }
            if frames >= maxFrames { ended = true; onLimit() }
        } catch { captureError = error; ended = true; onLimit() }
    }
    private func closePart() throws {
        guard part != nil else { return }
        part = nil // Finalizes the independent AAC container before publication.
        let name = String(format: "%04d.m4a", index)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("pending").appendingPathComponent(name), to: folder.appendingPathComponent(name))
        index += 1; partFrames = 0; onPart()
    }
}
