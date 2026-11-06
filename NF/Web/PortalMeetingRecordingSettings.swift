import Foundation

nonisolated struct PortalMeetingRecordingSettings: Codable, Equatable {
    var maxMinutes = 120
    var transcriptionMode = "during"
    var segmentMinutes = 1
    var maxSeconds: Double { Double(maxMinutes * 60) }
    var during: Bool { transcriptionMode == "during" }
    func validate() throws {
        guard (10...120).contains(maxMinutes), maxMinutes % 10 == 0, (1...10).contains(segmentMinutes), ["after", "during"].contains(transcriptionMode) else {
            throw NSError(domain: "NFMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "음성녹음 설정을 다시 확인해 주세요."])
        }
    }
    static func parse(_ value: Any?) throws -> Self {
        guard let value else { return Self() }
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        try result.validate(); return result
    }
}
