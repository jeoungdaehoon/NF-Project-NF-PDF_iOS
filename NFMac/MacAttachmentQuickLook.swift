import AppKit
import Foundation
import QuickLookUI
import SwiftUI

/// Only explicitly supported formats enter Quick Look; PDF keeps its existing editor.
enum MacAttachmentQuickLookKind: Equatable {
    case numbers
    case powerPoint(fileExtension: String)
    case excel

    static func detect(fileName: String, sourceURL: URL, mimeType: String) -> Self? {
        let extensions = [(fileName as NSString).pathExtension.lowercased(), sourceURL.pathExtension.lowercased()]
        for ext in extensions {
            if ["ppt", "pptx"].contains(ext) { return .powerPoint(fileExtension: ext) }
            if ext == "xlsx" { return .excel }
            if ext == "numbers" { return .numbers }
        }
        switch mimeType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "application/vnd.ms-powerpoint": return .powerPoint(fileExtension: "ppt")
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return .powerPoint(fileExtension: "pptx")
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return .excel
        case "application/vnd.apple.numbers", "application/x-iwork-numbers-sffnumbers": return .numbers
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .numbers: return "numbers"
        case .powerPoint(let ext): return ext
        case .excel: return "xlsx"
        }
    }

    var title: String {
        switch self {
        case .numbers: return "Numbers"
        case .powerPoint: return "PowerPoint"
        case .excel: return "Excel"
        }
    }

    static func handlesNavigation(_ url: URL) -> Bool {
        ["ppt", "pptx", "csv", "xlsx"].contains(url.pathExtension.lowercased())
    }

    static func handlesResponse(_ response: URLResponse) -> Bool {
        guard let url = response.url else { return false }
        if MacCSVDocument.matches(fileName: response.suggestedFilename ?? "", sourceURL: url, mimeType: response.mimeType ?? "") { return true }
        guard let kind = detect(fileName: response.suggestedFilename ?? "", sourceURL: url, mimeType: response.mimeType ?? "") else { return false }
        return kind != .numbers
    }
}

/// Own the temporary copy for the entire preview session, not an individual NSView.
/// Fullscreen/resizing can rebuild the view without deleting the file it still needs.
final class MacAttachmentQuickLookFile {
    let url: URL
    let kind: MacAttachmentQuickLookKind
    private let directory: URL

    init(data: Data, fileName: String, kind: MacAttachmentQuickLookKind) throws {
        self.kind = kind
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NF-AttachmentQuickLook", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeName = fileName.components(separatedBy: CharacterSet(charactersIn: "/:\0"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safeName.isEmpty ? "첨부 파일" : safeName
        url = directory.appendingPathComponent(
            (name as NSString).pathExtension.lowercased() == kind.fileExtension ? name : "\(name).\(kind.fileExtension)"
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct MacAttachmentQuickLookView: NSViewRepresentable {
    let file: MacAttachmentQuickLookFile

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero)
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = file.url as NSURL
        view.setAccessibilityIdentifier("attachment.viewer.quickLook")
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if context.coordinator.file.url != file.url {
            view.previewItem = file.url as NSURL
            context.coordinator.file = file
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.previewItem = nil
        view.close()
    }

    final class Coordinator {
        var file: MacAttachmentQuickLookFile
        init(file: MacAttachmentQuickLookFile) { self.file = file }
    }
}
