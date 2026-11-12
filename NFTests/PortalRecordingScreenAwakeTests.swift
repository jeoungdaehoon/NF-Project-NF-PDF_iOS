import Testing
@testable import NF

@MainActor
struct PortalRecordingScreenAwakeTests {
    @Test func restoresAfterRepeatedStartsAndForegroundReturns() {
        var disabled = false
        let screen = PortalRecordingScreenAwake(read: { disabled }, write: { disabled = $0 })
        screen.begin()
        #expect(disabled)
        screen.begin()
        screen.restore()
        #expect(!disabled)
        screen.restore()
        #expect(!disabled)
    }

    @Test func preservesAnExistingIdleTimerOverride() {
        var disabled = true
        let screen = PortalRecordingScreenAwake(read: { disabled }, write: { disabled = $0 })
        screen.begin()
        screen.restore()
        #expect(disabled)
    }

    @Test func reassertsWithoutReplacingTheOriginalValue() {
        var disabled = false
        let screen = PortalRecordingScreenAwake(read: { disabled }, write: { disabled = $0 })
        screen.begin()
        disabled = false
        screen.begin()
        #expect(disabled)
        screen.restore()
        #expect(!disabled)
    }

    @Test func restoresEvenWhenSavingThrows() {
        enum Failure: Error { case storage }
        var disabled = false
        let screen = PortalRecordingScreenAwake(read: { disabled }, write: { disabled = $0 })
        screen.begin()
        func finalize() throws {
            defer { screen.restore() }
            throw Failure.storage
        }
        #expect(throws: Failure.self) { try finalize() }
        #expect(!disabled)
    }

    @Test func failedStartDoesNotChangeTheIdleTimer() {
        var disabled = false
        var writes = 0
        let screen = PortalRecordingScreenAwake(read: { disabled }, write: { disabled = $0; writes += 1 })
        screen.restore()
        #expect(!disabled && writes == 0)
    }
}
