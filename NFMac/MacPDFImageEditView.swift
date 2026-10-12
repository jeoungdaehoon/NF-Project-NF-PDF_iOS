import AppKit
import PDFKit
import SwiftUI

struct MacPDFImageEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var parent: MacPDFEditorState
    @StateObject private var editor: MacPDFEditorState
    private let targetID: UUID?
    private let originalSize: CGSize
    init(parent: MacPDFEditorState) {
        self.parent = parent; targetID = parent.selected?.id
        let image = parent.selected?.imageData.flatMap(NSImage.init(data:))
        originalSize = image?.size ?? CGSize(width: 1000, height: 1000)
        let document = PDFDocument()
        if let image, let page = PDFPage(image: image) { document.insert(page, at: 0) }
        else { let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 600), for: .mediaBox); document.insert(page, at: 0) }
        _editor = StateObject(wrappedValue: MacPDFEditorState(document: document, identifier: "image-edit-\(UUID().uuidString)", fileName: "이미지 편집.pdf"))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("취소") { dismiss() }; Text("이미지에 필기·도형·문구 추가").font(.headline); Spacer()
                Button("이미지에 적용") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
            MacPDFEditorView(state: editor)
        }
    }
    private func apply() {
        guard let targetID, let data = editor.exportPDF(), let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) else { parent.error = "편집한 이미지를 만들지 못했습니다."; return }
        let ratio = min(1, 4096 / max(originalSize.width, originalSize.height))
        let size = CGSize(width: max(1, originalSize.width * ratio), height: max(1, originalSize.height * ratio))
        guard let imageData = page.thumbnail(of: size, for: .mediaBox).tiffRepresentation else { parent.error = "편집한 이미지를 저장하지 못했습니다."; return }
        parent.change { if let index = parent.objects.firstIndex(where: { $0.id == targetID }) { parent.objects[index].imageData = imageData } }
    }
}
