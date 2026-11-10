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
    /// Original-signal energy only, not a speech detector or confidence score.
    /// Retains no audio and never amplifies the measured signal.
    static func audibleSeconds(_ source: URL, minute: Int? = nil) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate
        if let minute { input.framePosition = min(input.length, Int64(Double(minute) * 60 * rate)) }
        let end = minute == nil ? input.length : min(input.length, input.framePosition + Int64(60 * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else { throw NSError(domain: "NFMeeting", code: 1) }
        let window = max(1, Int(rate * 0.02)), channels = Int(input.processingFormat.channelCount)
        var energy = 0.0, frames = 0, audible = 0
        while input.framePosition < end {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), end - input.framePosition)))
            guard buffer.frameLength > 0, let values = buffer.floatChannelData else { throw NSError(domain: "NFMeeting", code: 1) }
            for index in 0..<Int(buffer.frameLength) {
                for channel in 0..<channels { let sample = Double(values[channel][index]); energy += sample * sample / Double(channels) }
                frames += 1
                if frames == window {
                    if energy / Double(frames) >= 0.0000316227766 { audible += frames }
                    energy = 0; frames = 0
                }
            }
        }
        if frames > 0, energy / Double(frames) >= 0.0000316227766 { audible += frames }
        return Double(audible) / rate
    }
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
    static func transcriptionCopy(_ source: URL, minute: Int? = nil, enhance: Bool = true) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate
        if let minute { input.framePosition = min(input.length, Int64(Double(minute) * 60 * rate)) }
        let end = minute == nil ? input.length : min(input.length, input.framePosition + Int64(60 * rate))
        let estimated = Int64(Double(end - input.framePosition) / rate * 32000) + 16 * 1024 * 1024
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
                        guard input.framePosition < end else { status.pointee = .endOfStream; return nil }
                        try input.read(into: sourceBuffer, frameCount: min(requested, sourceBuffer.frameCapacity, AVAudioFrameCount(min(Int64(UInt32.max), end - input.framePosition))))
                        if sourceBuffer.frameLength == 0 { status.pointee = .endOfStream; return nil }
                        status.pointee = .haveData; return sourceBuffer
                    } catch { readError = error; status.pointee = .endOfStream; return nil }
                }
                if let readError { throw NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "전사용 원본 읽기 실패: \(readError)"]) }; if let convertError { throw convertError }
                if output.frameLength > 0, let values = output.floatChannelData?[0] {
                    noProgress = 0
                    if enhance { level.process(values, count: Int(output.frameLength), rate: 16000) }
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

/// Conservative quality checks, not semantic correction. Never invent a name,
/// number, decision or missing sentence to make a transcript look complete.
nonisolated enum PortalMeetingTextQuality {
    static let summaryVersion = "conversation-sentences-v2"
    static func tooSparse(_ text: String, audibleSeconds: Double) -> Bool {
        let plain = text.replacingOccurrences(of: #"\[\d+(?::\d+|초)?\]"#, with: "", options: .regularExpression)
        return audibleSeconds >= 30 && plain.filter { $0.isLetter || $0.isNumber }.count < 16
    }
    static func suspicious(_ text: String) -> Bool {
        let plain = text.replacingOccurrences(of: #"\[\d+(?::\d+|초)?\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard plain.count >= 24 else { return false }
        let visible = plain.filter { !$0.isWhitespace }
        if visible.filter({ $0.isLetter || $0.isNumber }).count * 2 < visible.count { return true }
        return plain.range(of: #"(.{6,80}?)\1{3,}"#, options: .regularExpression) != nil
    }
    static func summaryParts(_ text: String, limit: Int = 1800) -> [String] {
        precondition(limit >= 32)
        var remaining = text[...], result: [String] = []
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: min(limit, remaining.count))
            var cut = end
            if end < remaining.endIndex {
                let middle = remaining.index(remaining.startIndex, offsetBy: min(limit / 2, remaining.count))
                let candidates = remaining[middle..<end]
                if let boundary = candidates.indices.last(where: { index in
                    if remaining[index] == "\n" { return true }
                    let next = remaining.index(after: index)
                    return ".!?。！？".contains(remaining[index]) && (next == remaining.endIndex || remaining[next].isWhitespace)
                }) {
                    cut = remaining.index(after: boundary)
                } else if let space = candidates.lastIndex(where: { $0.isWhitespace }) {
                    cut = remaining.index(after: space)
                }
            }
            result.append(String(remaining[..<cut])); remaining = remaining[cut...]
        }
        return result
    }
    static func sourceFacts(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: "\n").compactMap { line in
            let value = line.replacingOccurrences(of: #"^\[\d+초\]\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.hasPrefix("["), value.contains(where: { $0.isNumber }) || ["담당", "기한", "결정", "하기로", "까지"].contains(where: { value.contains($0) }), seen.insert(value).inserted else { return nil }
            return value
        }
    }
    static func contextTerms(_ text: String) -> [String] {
        let suffix = String(text.suffix(500))
        let expression = try! NSRegularExpression(pattern: #"[가-힣A-Za-z][가-힣A-Za-z0-9_-]{2,}"#)
        let matches = expression.matches(in: suffix, range: NSRange(suffix.startIndex..., in: suffix))
        var seen = Set<String>()
        let terms = matches.reversed().compactMap { match -> String? in
            guard let range = Range(match.range, in: suffix) else { return nil }
            let term = String(suffix[range])
            return seen.insert(term).inserted ? term : nil
        }
        return Array(terms.prefix(12).reversed())
    }
}
