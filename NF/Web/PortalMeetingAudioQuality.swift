import AVFoundation
import Foundation

/// Bounded, frame-preserving gain for a derived transcription file. Silence
/// is not removed; sub -55dBFS noise is not deliberately amplified.
nonisolated struct PortalMeetingAudioLevel {
    private var gain: Float = 1
    mutating func process(_ values: UnsafeMutablePointer<Float>, count: Int, rate: Double) {
        guard count > 0 else { return }
        var energy: Float = 0, peak: Float = 0
        for i in 0..<count { energy += values[i] * values[i]; peak = max(peak, abs(values[i])) }
        let rms = sqrt(energy / Float(count))
        let target: Float = rms < 0.00178 || peak == 0 ? 1 : max(1, min(4, min(0.0631 / rms, 0.891 / peak)))
        let step = Float(1 - exp(-1 / (rate * (target < gain ? 0.02 : 0.4))))
        let ceiling: Float = peak > 0 ? max(1, 0.891 / peak) : 1
        for i in 0..<count { gain = min(ceiling, gain + (target - gain) * step); values[i] = max(-1, min(1, values[i] * gain)) }
    }
}

nonisolated enum PortalMeetingAudioQuality {
    static func availableBytes(at url: URL) -> Int64 {
        if let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return value }
        if let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity { return Int64(value) }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
    static func requiredBytes(_ settings: PortalMeetingRecordingSettings) -> Int64 {
        // Original + minute AAC copies, or original + one temporary PCM16
        // transcription file. Never pretend the original is the whole budget.
        Int64(settings.maxSeconds) * (settings.during ? 32000 : 48000) + 64 * 1024 * 1024
    }
    static func transcriptionCopy(_ source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let estimated = Int64(Double(input.length) / input.processingFormat.sampleRate * 32000) + 16 * 1024 * 1024
        let space = availableBytes(at: source)
        guard space >= estimated else { throw NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "전사용 임시 음성 공간이 부족합니다. 원본은 유지됩니다."]) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("nf-meeting-level-\(UUID().uuidString).caf")
        do {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: input.processingFormat, to: mono),
                  let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
                  let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4096) else { throw NSError(domain: "NFMeeting", code: 1) }
            let file = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            var level = PortalMeetingAudioLevel(), ended = false, frames: Int64 = 0, noProgress = 0
            while !ended {
                try Task.checkCancellation()
                var readError: Error?, convertError: NSError?
                let state = converter.convert(to: output, error: &convertError) { requested, status in
                    do {
                        guard input.framePosition < input.length else { status.pointee = .endOfStream; return nil }
                        try input.read(into: sourceBuffer, frameCount: min(requested, sourceBuffer.frameCapacity, AVAudioFrameCount(input.length - input.framePosition)))
                        if sourceBuffer.frameLength == 0 { status.pointee = .endOfStream; return nil }
                        status.pointee = .haveData; return sourceBuffer
                    } catch { readError = error; status.pointee = .endOfStream; return nil }
                }
                if let readError { throw NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "전사용 원본 읽기 실패: \(readError)"]) }; if let convertError { throw convertError }
                if output.frameLength > 0, let values = output.floatChannelData?[0] {
                    noProgress = 0
                    level.process(values, count: Int(output.frameLength), rate: 16000)
                    do { try file.write(from: output) } catch { throw NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "전사용 PCM 저장 실패: \(error)"]) }; frames += Int64(output.frameLength)
                }
                else { noProgress += 1 }
                guard noProgress < 16 else { throw NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "전사용 음성 변환이 진행되지 않습니다. 원본은 유지됩니다."]) }
                guard frames <= 16000 * 7201 else { throw NSError(domain: "NFMeeting", code: 1) }
                if state == .error { throw NSError(domain: "NFMeeting", code: 1) }
                ended = state == .endOfStream
            }
            guard frames > 0 else { throw NSError(domain: "NFMeeting", code: 1) }
            return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
