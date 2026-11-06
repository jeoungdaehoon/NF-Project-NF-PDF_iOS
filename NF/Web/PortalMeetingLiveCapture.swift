import AVFoundation
import Foundation
import Synchronization

/// SPSC queue: tap only copies into preallocated buffers. No locks, allocation,
/// encoder, disk access, or Task creation on the input callback.
@available(macOS 15.0, *)
nonisolated final class PortalMeetingPcmQueue: @unchecked Sendable {
    private let slots: [AVAudioPCMBuffer]
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private(set) var capacity: Int
    let overflows = Atomic<Int>(0)
    init(format: AVAudioFormat, capacity: Int = 32, frameCapacity: AVAudioFrameCount = 16384) throws {
        self.capacity = capacity
        slots = try (0..<capacity).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { throw NSError(domain: "NFMeeting", code: 1) }
            return buffer
        }
    }
    var depth: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }
    func push(_ source: AVAudioPCMBuffer) -> Bool {
        let write = writeIndex.load(ordering: .relaxed)
        guard write - readIndex.load(ordering: .acquiring) < capacity else {
            overflows.store(overflows.load(ordering: .relaxed) + 1, ordering: .releasing); return false
        }
        let destination = slots[write % capacity]
        guard source.frameLength <= destination.frameCapacity, source.format == destination.format else { return false }
        destination.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        for channel in 0..<from.count {
            guard let input = from[channel].mData, let output = to[channel].mData else { return false }
            memcpy(output, input, Int(from[channel].mDataByteSize))
        }
        writeIndex.store(write + 1, ordering: .releasing)
        return true
    }
    func peek() -> AVAudioPCMBuffer? {
        let read = readIndex.load(ordering: .relaxed)
        return read < writeIndex.load(ordering: .acquiring) ? slots[read % capacity] : nil
    }
    func consume() { readIndex.store(readIndex.load(ordering: .relaxed) + 1, ordering: .releasing) }
}

/// The unmodified original and optional minute fragments are encoded only by
/// the writer. Queue saturation is an explicit interrupted recording, never
/// an apparently successful file with silently dropped buffers.
@available(macOS 15.0, *)
nonisolated final class PortalMeetingLiveCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writerQueue = DispatchQueue(label: "nf.meeting.writer", qos: .userInitiated)
    private let group = DispatchGroup()
    private let originalURL: URL
    private let folder: URL
    private let maxSeconds: Double
    private let recordSegments: Bool
    private let onPart: @Sendable () -> Void
    private let onLimit: @Sendable () -> Void
    private var original: AVAudioFile?
    private var part: AVAudioFile?
    private var format: AVAudioFormat?
    private var queue: PortalMeetingPcmQueue?
    private let accepting = Atomic<Bool>(false)
    private let receiving = Atomic<Bool>(false)
    private let isPaused = Atomic<Bool>(false)
    private let fault = Atomic<Int>(0)
    private let writtenFrames = Atomic<Int64>(0)
    private let inputFrames = Atomic<Int64>(0)
    private let peakQueue = Atomic<Int>(0)
    private let gaps = Atomic<Int64>(0)
    private let maxWriteMs = Atomic<Int>(0)
    private let rmsDbHundredths = Atomic<Int>(-12000)
    private let silentFrames = Atomic<Int64>(0)
    private var lastSampleTime: AVAudioFramePosition?
    private var previousLength: AVAudioFrameCount = 0
    private var partFrames: AVAudioFramePosition = 0
    private var index = 0
    private var captureError: Error?
    var seconds: Double { Double(writtenFrames.load(ordering: .acquiring)) / (format?.sampleRate ?? 44100) }
    var paused: Bool { isPaused.load(ordering: .acquiring) }
    var backpressured: Bool { (queue?.depth ?? 0) >= 8 }
    var diagnostics: [String: Any] {
        ["capturedFrames": inputFrames.load(ordering: .acquiring),
         "encodedFrames": writtenFrames.load(ordering: .acquiring),
         "queueDepth": queue?.depth ?? 0, "queuePeak": peakQueue.load(ordering: .acquiring),
         "queueOverflows": queue?.overflows.load(ordering: .acquiring) ?? 0,
         "inputGapFrames": gaps.load(ordering: .acquiring), "maxWriteMs": maxWriteMs.load(ordering: .acquiring),
         "bitRate": 128000, "silentFrames": silentFrames.load(ordering: .acquiring), "rmsDb": Double(rmsDbHundredths.load(ordering: .acquiring)) / 100,
         "warning": fault.load(ordering: .acquiring) == 0 ? (backpressured ? "저장 지연 · 녹음 우선" : "") : "입력·저장 중단 · 원본과 진단 확인 필요"]
    }
    init(original: URL, folder: URL, maxSeconds: Double, recordSegments: Bool = true, onPart: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void) {
        self.originalURL = original; self.folder = folder; self.maxSeconds = maxSeconds
        self.recordSegments = recordSegments; self.onPart = onPart; self.onLimit = onLimit
    }
    func start() throws {
        if recordSegments { try FileManager.default.createDirectory(at: folder.appendingPathComponent("pending"), withIntermediateDirectories: true) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw failure("마이크 입력을 준비하지 못했습니다.") }
        self.format = format; queue = try PortalMeetingPcmQueue(format: format)
        original = try writer(originalURL, format)
        accepting.store(true, ordering: .releasing)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in self?.receive(buffer, time) }
        group.enter()
        writerQueue.async { [self] in writeLoop(); group.leave() }
        do { engine.prepare(); try engine.start() }
        catch { accepting.store(false, ordering: .releasing); input.removeTap(onBus: 0); _ = group.wait(timeout: .now() + 8); throw error }
    }
    func pause() { isPaused.store(true, ordering: .releasing) }
    func resume() throws {
        guard fault.load(ordering: .acquiring) == 0 else { throw failure("입력이 중단됐습니다. 현재 원본을 저장하고 새 녹음을 시작해 주세요.") }
        if !engine.isRunning { engine.prepare(); try engine.start() }
        isPaused.store(false, ordering: .releasing)
    }
    func finish() throws {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        accepting.store(false, ordering: .releasing)
        guard group.wait(timeout: .now() + 8) == .success else { throw failure("녹음 저장 마무리가 지연됩니다. 원본을 보존합니다.") }
        if let captureError { throw captureError }
        guard fault.load(ordering: .acquiring) == 0,
              min(inputFrames.load(ordering: .acquiring), Int64(maxSeconds * (format?.sampleRate ?? 44100))) == writtenFrames.load(ordering: .acquiring) else { throw failure("입력·저장 프레임 불일치 또는 대기열 포화 · 원본을 확인해 주세요.") }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func writer(_ url: URL, _ format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 128000], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    private func receive(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        receiving.store(true, ordering: .releasing)
        defer { receiving.store(false, ordering: .releasing) }
        guard accepting.load(ordering: .acquiring), fault.load(ordering: .acquiring) == 0 else { return }
        let paused = isPaused.load(ordering: .acquiring)
        if time.isSampleTimeValid, let previous = lastSampleTime, !paused, time.sampleTime > previous + Int64(previousLength) {
            gaps.store(gaps.load(ordering: .relaxed) + time.sampleTime - previous - Int64(previousLength), ordering: .releasing)
        }
        lastSampleTime = time.isSampleTimeValid ? time.sampleTime : nil; previousLength = buffer.frameLength
        guard !paused else { return }
        if let values = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += values[index] * values[index] }
            if energy == 0 { silentFrames.store(silentFrames.load(ordering: .relaxed) + Int64(buffer.frameLength), ordering: .releasing) }
            rmsDbHundredths.store(energy > 0 ? Int(1000 * log10(Double(energy) / Double(buffer.frameLength))) : -12000, ordering: .releasing)
        }
        guard queue?.push(buffer) == true else { fault.store(1, ordering: .releasing); return }
        inputFrames.store(inputFrames.load(ordering: .relaxed) + Int64(buffer.frameLength), ordering: .releasing)
        peakQueue.store(max(peakQueue.load(ordering: .relaxed), queue?.depth ?? 0), ordering: .releasing)
    }
    private func writeLoop() {
        var notified = false
        defer {
            original = nil
            do { try closePart() } catch { captureError = error; fault.store(2, ordering: .releasing); if !notified { onLimit() } }
        }
        while accepting.load(ordering: .acquiring) || receiving.load(ordering: .acquiring) || (queue?.depth ?? 0) > 0 {
            if fault.load(ordering: .acquiring) != 0 && !notified { notified = true; onLimit() }
            guard let buffer = queue?.peek(), let format else { Thread.sleep(forTimeInterval: 0.002); continue }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                // Cap at the exact active recording limit; a final callback may
                // legitimately contain more frames than remain in the limit.
                let limit = Int64(maxSeconds * format.sampleRate)
                var offset: AVAudioFrameCount = 0
                while offset < buffer.frameLength && writtenFrames.load(ordering: .relaxed) < limit {
                    if recordSegments && part == nil { part = try writer(folder.appendingPathComponent("pending").appendingPathComponent(String(format: "%04d.m4a", index)), format) }
                    let minute = Int64(60 * format.sampleRate)
                    let count = AVAudioFrameCount(min(Int64(buffer.frameLength - offset), recordSegments ? minute - partFrames : Int64(buffer.frameLength), limit - writtenFrames.load(ordering: .relaxed)))
                    guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw failure("저장 버퍼를 준비하지 못했습니다.") }
                    slice.frameLength = count
                    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), target = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
                    let bytes = Int(format.streamDescription.pointee.mBytesPerFrame)
                    for channel in 0..<source.count {
                        guard let from = source[channel].mData, let to = target[channel].mData else { throw failure("음성 입력을 읽지 못했습니다.") }
                        memcpy(to, from.advanced(by: Int(offset) * bytes), Int(count) * bytes)
                    }
                    try original?.write(from: slice); try part?.write(from: slice)
                    writtenFrames.store(writtenFrames.load(ordering: .relaxed) + Int64(count), ordering: .releasing)
                    offset += count; partFrames += Int64(count)
                    if recordSegments && partFrames >= minute { try closePart() }
                }
                maxWriteMs.store(max(maxWriteMs.load(ordering: .relaxed), Int((ProcessInfo.processInfo.systemUptime - began) * 1000)), ordering: .releasing)
                queue?.consume()
                if writtenFrames.load(ordering: .relaxed) >= limit {
                    // Frames beyond the configured duration are intentional,
                    // not dropped input. Discard only this post-limit tail.
                    accepting.store(false, ordering: .releasing)
                    while queue?.peek() != nil { queue?.consume() }
                    if !notified { notified = true; onLimit() }; return
                }
            } catch {
                captureError = error; fault.store(2, ordering: .releasing)
                accepting.store(false, ordering: .releasing)
                if !notified { notified = true; onLimit() }; return
            }
        }
    }
    private func closePart() throws {
        guard part != nil else { return }; part = nil
        let name = String(format: "%04d.m4a", index)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("pending").appendingPathComponent(name), to: folder.appendingPathComponent(name))
        index += 1; partFrames = 0; onPart()
    }
}
