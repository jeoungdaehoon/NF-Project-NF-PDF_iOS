import Foundation
import Testing
@testable import NF

struct PortalMeetingRecordingSettingsTests {
    @Test func incrementalDefaultsAndAllAllowedChoices() throws {
        let defaults = try PortalMeetingRecordingSettings.parse(nil)
        #expect(defaults.maxSeconds == 7200)
        #expect(defaults.during)
        #expect(try !PortalMeetingRecordingSettings.parse(["maxMinutes": 120, "transcriptionMode": "after", "segmentMinutes": 1]).during)
        for maximum in stride(from: 10, through: 120, by: 10) {
            for segment in 1...10 {
                let value = try PortalMeetingRecordingSettings.parse(["maxMinutes": maximum, "transcriptionMode": "during", "segmentMinutes": segment])
                #expect(value.maxSeconds == Double(maximum * 60))
                #expect(value.during && value.segmentMinutes == segment)
            }
        }
    }
    @Test func rejectsOutOfRangeAndFractionalValues() {
        for value: [String: Any] in [
            ["maxMinutes": 9, "transcriptionMode": "after", "segmentMinutes": 1],
            ["maxMinutes": 130, "transcriptionMode": "after", "segmentMinutes": 1],
            ["maxMinutes": 10.5, "transcriptionMode": "after", "segmentMinutes": 1],
            ["maxMinutes": 10, "transcriptionMode": "during", "segmentMinutes": 0],
            ["maxMinutes": 10, "transcriptionMode": "during", "segmentMinutes": 11],
            ["maxMinutes": 10, "transcriptionMode": "cloud", "segmentMinutes": 1]
        ] {
            #expect(throws: (any Error).self) { try PortalMeetingRecordingSettings.parse(value) }
        }
    }
}
