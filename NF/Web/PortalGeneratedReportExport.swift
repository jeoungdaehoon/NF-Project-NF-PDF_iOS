import Foundation
import UIKit
import WebKit

nonisolated struct PortalGeneratedReportFile {
    let name: String
    let data: Data
    init(_ input: [String: Any]) throws {
        guard let name = input["name"] as? String, (4...150).contains(name.count),
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.hasSuffix(".pdf") || name.hasSuffix(".md"),
              let encoded = input["base64"] as? String, encoded.utf8.count <= 1_000_000,
              let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw NSError(domain: "NFReport", code: 1, userInfo: [NSLocalizedDescriptionKey: "파일 이름·형식·크기를 확인해 주세요."])
        }
        self.name = name; self.data = data
    }
}

/// A separate temporary directory per request. Cancellation never reports a save.
@MainActor
final class PortalGeneratedReportExporter: NSObject, UIDocumentPickerDelegate {
    static let shared = PortalGeneratedReportExporter()
    private var completion: CheckedContinuation<Bool, Never>?
    private var directory: URL?

    func export(_ input: [String: Any], share: Bool, webView: WKWebView) async throws -> Bool {
        guard completion == nil else { throw NSError(domain: "NFReport", code: 2, userInfo: [NSLocalizedDescriptionKey: "현재 파일 저장·공유를 먼저 완료해 주세요."]) }
        let file = try PortalGeneratedReportFile(input)
        guard var presenter = webView.window?.rootViewController else { throw NSError(domain: "NFReport", code: 3, userInfo: [NSLocalizedDescriptionKey: "파일 저장 화면을 열 수 없습니다."]) }
        while let next = presenter.presentedViewController { presenter = next }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file.name)
        do { try file.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        self.directory = directory
        return await withCheckedContinuation { continuation in
            completion = continuation
            if share {
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = webView
                sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
                sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in Task { @MainActor in self?.finish(completed) } }
                presenter.present(sheet, animated: true)
            } else {
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                picker.delegate = self
                presenter.present(picker, animated: true)
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    private func finish(_ saved: Bool) {
        let pending = completion; completion = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        pending?.resume(returning: saved)
    }
}
