import Foundation

/// Owns a temporary override, never the user's system Auto-Lock preference.
@MainActor
final class PortalRecordingScreenAwake {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var previous: Bool?

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func begin() {
        if previous == nil { previous = read() }
        write(true)
    }

    func restore() {
        guard let original = previous else { return }
        previous = nil
        write(original)
    }
}
