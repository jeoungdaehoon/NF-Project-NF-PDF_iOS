import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NF

struct PortalMeetingAudioQualityTests {
    @Test func obviousOmissionsNeedReviewNotInventedText() {
        #expect(PortalMeetingTextQuality.tooSparse("[1:00] 밑에.", audibleSeconds: 45))
        #expect(!PortalMeetingTextQuality.tooSparse("", audibleSeconds: 0))
        #expect(!PortalMeetingTextQuality.tooSparse("네.", audibleSeconds: 2))
        #expect(!PortalMeetingTextQuality.tooSparse("충분한 길이의 인식된 문장은 이 검사만으로 실패시키지 않습니다.", audibleSeconds: 45))
    }
    @Test func sentencePartsPreserveEveryCharacter() {
        let text = String(repeating: "김담당자는 2026-11-10까지 SDK-123을 확인하기로 했습니다. 👩🏽‍💻\n", count: 80)
        let parts = PortalMeetingTextQuality.summaryParts(text)
        #expect(parts.joined() == text)
        #expect(parts.allSatisfy { $0.count <= 1800 })
        #expect(parts.dropLast().allSatisfy { $0.last?.isWhitespace == true })
        let emoji = String(repeating: "👩🏽‍💻", count: 2000)
        #expect(PortalMeetingTextQuality.summaryParts(emoji).joined() == emoji)
    }
    @Test func qualityChecksDoNotRewriteFacts() {
        #expect(PortalMeetingTextQuality.suspicious(String(repeating: "같은 문장이 반복됩니다. ", count: 8)))
        #expect(PortalMeetingTextQuality.suspicious(String(repeating: "!?_", count: 20)))
        #expect(!PortalMeetingTextQuality.suspicious("김담당자가 2026-11-10까지 SDK-123 버전 검토 결과를 확인합니다."))
        #expect(!PortalMeetingTextQuality.suspicious("네 네 네"))
        let source = "[1:00]\n[3초] 김담당자가 SDK-123을 11월 10일까지 확인.\n일반 논의\n담당: 이담당\n"
        #expect(PortalMeetingTextQuality.sourceFacts(source) == ["김담당자가 SDK-123을 11월 10일까지 확인.", "담당: 이담당"])
        let context = "SDK-123 담당자는 김담당입니다 다음 구간 SDK-123"
        let terms = PortalMeetingTextQuality.contextTerms(context)
        #expect(Set(terms).count == terms.count && terms.count <= 12)
        #expect(terms.allSatisfy { context.contains($0) })
    }
    @Test func silenceNoiseFloorAndQuietSpeech() {
        for amplitude: Float in [0, 0.0005, 0.015, 0.95] {
            var samples = (0..<16000).map { sin(Float($0) * 2 * .pi * 440 / 16000) * amplitude }
            let before = samples, oldPeak = samples.map { abs($0) }.max()!
            var level = PortalMeetingAudioLevel()
            samples.withUnsafeMutableBufferPointer { buffer in
                for offset in stride(from: 0, to: buffer.count, by: 320) { level.process(buffer.baseAddress!.advanced(by: offset), count: 320, rate: 16000) }
            }
            let peak = samples.map { abs($0) }.max()!
            #expect(samples.count == before.count)
            if amplitude < 0.001 { #expect(samples == before) }
            if amplitude == 0.015 { #expect(peak > oldPeak * 2 && peak <= oldPeak * 4) }
            #expect(peak <= 1)
        }
    }
    @Test func queuePreservesOrderAndReportsSaturation() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let queue = try PortalMeetingPcmQueue(format: format, capacity: 2, frameCapacity: 32)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        input.frameLength = 32
        input.floatChannelData![0].initialize(repeating: 1, count: 32)
        #expect(queue.push(input)); input.floatChannelData![0][0] = 2; #expect(queue.push(input))
        #expect(!queue.push(input)); #expect(queue.overflows.load(ordering: .acquiring) == 1)
        #expect(queue.peek()!.floatChannelData![0][0] == 1); queue.consume()
        #expect(queue.peek()!.floatChannelData![0][0] == 2); queue.consume()
        #expect(queue.peek() == nil && queue.depth == 0)
    }
    @Test func queueConcurrentProducerConsumer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let queue = try PortalMeetingPcmQueue(format: format, frameCapacity: 32)
        let failed = Atomic<Bool>(false), group = DispatchGroup()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
            input.frameLength = 32
            for value in 0..<10000 {
                input.floatChannelData![0][0] = Float(value)
                while !queue.push(input) {
                    if ProcessInfo.processInfo.systemUptime > deadline { failed.store(true, ordering: .releasing); return }
                    Thread.sleep(forTimeInterval: 0.00001)
                }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for value in 0..<10000 {
                while queue.peek() == nil {
                    if ProcessInfo.processInfo.systemUptime > deadline { failed.store(true, ordering: .releasing); return }
                    Thread.sleep(forTimeInterval: 0.00001)
                }
                if queue.peek()!.floatChannelData![0][0] != Float(value) { failed.store(true, ordering: .releasing) }
                queue.consume()
            }
        }
        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(!failed.load(ordering: .acquiring) && queue.depth == 0)
    }
    @Test func transcriptionCopyPreservesSourceAndDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-quality-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        buffer.frameLength = 88200
        for index in 0..<88200 { buffer.floatChannelData![0][index] = sin(Float(index) * 2 * .pi * 440 / 44100) * 0.015 }
        do { let writer = try AVAudioFile(forWriting: source, settings: format.settings); try writer.write(from: buffer) }
        let before = try Data(contentsOf: source)
        let derived = try PortalMeetingAudioQuality.transcriptionCopy(source)
        defer { try? FileManager.default.removeItem(at: derived) }
        let file = try AVAudioFile(forReading: derived)
        #expect(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        #expect(abs(Double(file.length) / 16000 - 2) < 0.01)
        #expect(try Data(contentsOf: source) == before)
    }
    @Test func storageIncludesTemporaryAudio() {
        let after = try! PortalMeetingRecordingSettings.parse(["maxMinutes": 120, "transcriptionMode": "after", "segmentMinutes": 1]), during = PortalMeetingRecordingSettings()
        #expect(PortalMeetingAudioQuality.requiredBytes(after) == 7200 * 48000 + 64 * 1024 * 1024)
        #expect(PortalMeetingAudioQuality.requiredBytes(during) == 7200 * 32000 + 64 * 1024 * 1024)
    }
}
