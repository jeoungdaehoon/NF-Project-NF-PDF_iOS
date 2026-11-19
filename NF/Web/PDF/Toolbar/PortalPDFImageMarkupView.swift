import PDFKit
import SwiftUI
import UIKit

struct PortalPDFImageMarkupItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct PortalPDFImageMarkupView: View {
    let item: PortalPDFImageMarkupItem
    let onDismiss: () -> Void
    let onApply: (UIImage) -> Void
    @Environment(\.portalAppTheme) private var theme
    @State private var document: PDFDocument?
    @State private var error: String?

    var body: some View {
        Group {
            if let document {
                PortalPDFPreviewView(
                    item: PortalAttachmentPreviewItem(
                        url: FileManager.default.temporaryDirectory
                            .appendingPathComponent("NF-Image-\(item.id.uuidString).pdf"),
                        cookieHeader: nil
                    ),
                    onClose: onDismiss,
                    usesCompactTitleBar: true,
                    imageMarkupDocument: document,
                    onApplyImageMarkup: apply
                )
            } else {
                VStack(spacing: 12) {
                    if error == nil { ProgressView() }
                    Button("취소", action: onDismiss)
                }
            }
        }
        .background(theme.backgroundColor)
        .task(id: item.id) {
            guard document == nil else { return }
            let image = item.image
            let scale = min(1, 720 / max(image.size.width, image.size.height, 1))
            let bounds = CGRect(origin: .zero,
                size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            guard bounds.width >= 1, bounds.height >= 1 else {
                error = "이미지 크기가 올바르지 않습니다."
                return
            }
            let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage()
                image.draw(in: bounds)
            }
            document = PDFDocument(data: data)
            if document == nil { error = "이미지 편집 화면을 열지 못했습니다." }
        }
        .alert("이미지 편집", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("확인") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func apply(_ edited: PDFDocument) {
        guard let data = edited.portalFlattenedDataRepresentation(),
              let page = PDFDocument(data: data)?.page(at: 0) else {
            error = "편집한 이미지를 적용하지 못했습니다."
            return
        }
        let scale = min(item.image.scale, 3000 / max(item.image.size.width, item.image.size.height, 1))
        let size = CGSize(width: item.image.size.width * scale, height: item.image.size.height * scale)
        onApply(page.thumbnail(of: size, for: .cropBox))
    }
}
