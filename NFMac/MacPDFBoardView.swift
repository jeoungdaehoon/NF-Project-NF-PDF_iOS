import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A separate large-page workspace: source PDFs stay intact inside their cards.
struct MacPDFBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: MacPDFEditorState
    @State private var preview: Preview?
    private struct Preview: Identifiable { let id: UUID; let data: Data; let name: String }
    init() {
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 3000, height: 2000), for: .mediaBox); pdf.insert(page, at: 0)
        _state = StateObject(wrappedValue: MacPDFEditorState(document: pdf, identifier: "mac-document-connection-board", fileName: "문서 연결 보드.pdf"))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("닫기") { dismiss() }; Text("문서 연결 보드").font(.headline); Spacer()
                Text("PDF 카드를 더블 클릭하면 원본을 엽니다").font(.caption)
                Button("PDF·이미지 카드 추가", action: importCards)
                Button("선택 PDF 열기") { if let object = state.selected, let data = object.attachmentPDF { preview = Preview(id: object.id, data: data, name: object.attachmentName ?? "PDF") } }.disabled(state.selected?.attachmentPDF == nil)
            }.padding(10)
            MacPDFEditorView(state: state)
        }
        .onAppear { state.onOpenAttachment = { data, name in if let id = state.selected?.id { preview = Preview(id: id, data: data, name: name) } } }
        .onDisappear { state.onOpenAttachment = nil }
        .sheet(item: $preview) { item in
            VStack {
                HStack { Text(item.name).font(.headline); Spacer(); Button("닫기") { preview = nil } }.padding(12)
                if let document = PDFDocument(data: item.data) {
                    MacPDFWorkspace(document: document, identifier: "board-card-\(item.id)", fileName: item.name, exportOnSave: true, onSave: { data in
                        state.change {
                            if let index = state.objects.firstIndex(where: { $0.id == item.id }) {
                                state.objects[index].attachmentPDF = data
                                if let page = PDFDocument(data: data)?.page(at: 0) { state.objects[index].imageData = page.thumbnail(of: CGSize(width: 600, height: 850), for: .cropBox).tiffRepresentation }
                            }
                        }
                    })
                }
            }.frame(minWidth: 850, minHeight: 650)
        }
    }
    private func importCards() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf, .image]; panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for (offset, url) in panel.urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let visible = state.canvas?.visibleInsertion().1 ?? CGRect(x: 0, y: 0, width: 3000, height: 2000)
                    let center = CGPoint(x: visible.midX + Double(offset % 3) * 25, y: visible.midY - Double(offset / 3) * 25)
                    if let pdf = PDFDocument(data: data), let page = pdf.page(at: 0), let image = page.thumbnail(of: CGSize(width: 600, height: 850), for: .cropBox).tiffRepresentation {
                        let bounds = state.imageInsertionBounds(CGSize(width: 260, height: 380), visible: visible, page: state.document.page(at: 0)!.bounds(for: .cropBox), center: center)
                        let object = MacPDFObject(page: 0, kind: .image, bounds: bounds, imageData: image, originalImageData: image, attachmentPDF: data, attachmentName: url.lastPathComponent)
                        state.add(object); state.selectObjects([object.id], showMenu: true)
                    } else if let image = NSImage(data: data) { state.insertImage(image, at: center) }
                    else { state.error = "지원하지 않는 파일입니다: \(url.lastPathComponent)" }
                } catch { state.error = error.localizedDescription }
            }
            state.tool = .select
        }
    }
}
