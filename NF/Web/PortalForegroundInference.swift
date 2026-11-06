import Foundation
import UIKit

/// iOS may suspend inference when the app leaves the foreground. Cancel the
/// current segment instead of leaving a web request waiting indefinitely;
/// completed segments and the original remain the durable checkpoint.
@MainActor
enum PortalForegroundInference {
    static func run(_ operation: @escaping @MainActor () async throws -> String) async throws -> String {
        let work = Task { @MainActor in try await operation() }
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in work.cancel() }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            if work.isCancelled { throw NSError(domain: "NFMeeting", code: 2, userInfo: [NSLocalizedDescriptionKey: "앱 전환으로 기기 내 AI 처리를 일시 중지했습니다. 원본과 저장된 구간은 유지됩니다. NF로 돌아와 이어서 처리해 주세요."]) }
            throw error
        }
    }
}
