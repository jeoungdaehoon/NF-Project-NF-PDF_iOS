import AppKit
import Combine
import PDFKit
import SwiftUI

/// The document body stays in WebKit. The PDF editor receives a scrollable
/// coordinate space and owns the same objects, gestures and settings as a PDF file.
@MainActor
final class MacPDFLiveSurface: ObservableObject {
    private(set) var viewport: LiveDetailPDF.NativeViewport?
    @Published private(set) var frame: CGRect?
    @Published private(set) var editor: MacPDFEditorState?
    let zoomPercent = CurrentValueSubject<Int, Never>(100)
    @Published var editsSource = false
    weak var bridge: LiveDetailPDF?
    var flushEditor: (() async -> Bool)?
    private var edits: AnyCancellable?
    private var lastExtent: CGSize?
    private var extentUpdateScheduled = false

    func open(directory: URL, legacy: Data) throws {
        reset()
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: -1, width: 1, height: 1), for: .mediaBox)
        document.insert(page, at: 0)
        let state = MacPDFEditorState(document: document, identifier: directory.lastPathComponent,
                                      fileName: "상세페이지 주석", directory: directory, guardsArchiveRevision: true)
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("edits.plist").path) {
            state.objects = try LegacyLivePDFAnnotations.read(legacy)
        }
        editor = state
        edits = state.$undoCount.combineLatest(state.$redoCount)
            .sink { [weak self] _, _ in self?.scheduleExtentUpdate() }
    }

    func update(_ viewport: LiveDetailPDF.NativeViewport) {
        let previous = self.viewport
        guard previous != viewport, let editor, let page = editor.document.page(at: 0) else { return }
        if previous?.scale != viewport.scale { editor.canvas?.finishTextEditing() }
        self.viewport = viewport

        // Scroll and scale update the AppKit coordinate space. SwiftUI only
        // needs to re-lay out the editor when the viewport frame changes.
        let frame = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
        if self.frame != frame { self.frame = frame }
        let bounds = CGRect(x: 0, y: -viewport.contentHeight, width: viewport.contentWidth, height: viewport.contentHeight)
        if page.bounds(for: .mediaBox) != bounds {
            page.setBounds(bounds, for: .mediaBox)
            page.setBounds(bounds, for: .cropBox)
        }
        let percent = Int((viewport.zoom * 100).rounded())
        if zoomPercent.value != percent { zoomPercent.send(percent) }
        editor.canvas?.updateInteractionOverlay()
        editor.canvas?.freeNotes?.viewportChanged()
        if previous == nil { scheduleExtentUpdate() }
    }

    private func scheduleExtentUpdate() {
        guard !extentUpdateScheduled else { return }
        extentUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.extentUpdateScheduled = false
            guard let editor = self.editor, let page = editor.document.page(at: 0), self.viewport != nil else { return }
            var extent = CGSize.zero
            for bounds in editor.objects.lazy.filter({ !$0.isTransient }).map(\.bounds) + page.annotations.map(\.bounds) {
                extent.width = max(extent.width, bounds.maxX + 16)
                extent.height = max(extent.height, -bounds.minY + 16)
            }
            guard extent != self.lastExtent else { return }
            self.lastExtent = extent
            self.bridge?.nativeCommand("extent", x: extent.width, y: extent.height)
        }
    }

    func prepareToClose() async -> Bool {
        guard let editor else { return true }
        if let flushEditor { return await flushEditor() }
        return editor.persistBeforeReturningToDetail()
    }

    func reset() {
        viewport = nil
        frame = nil
        zoomPercent.send(100)
        edits?.cancel()
        edits = nil
        editor = nil
        flushEditor = nil
        lastExtent = nil
        editsSource = false
    }

    var requestedZoom: Double { bridge?.requestedNativeZoom ?? viewport?.zoom ?? 1 }

    func zoom(to factor: Double) { bridge?.nativeCommand("zoom", x: factor) }
    func zoom(by multiplier: Double) { zoom(to: requestedZoom * multiplier) }
    func scroll(x: Double, y: Double) { bridge?.nativeCommand("scroll", x: x, y: y) }
    func close() { bridge?.nativeCommand("close") }

    func localPoint(_ point: CGPoint, in bounds: CGRect, flipped: Bool) -> CGPoint {
        guard let viewport else { return .zero }
        let x = point.x * viewport.scale - viewport.scrollX
        let y = -point.y * viewport.scale - viewport.scrollY
        return CGPoint(x: x, y: flipped ? y : bounds.height - y)
    }

    func pagePoint(_ point: CGPoint, in bounds: CGRect, flipped: Bool) -> CGPoint {
        guard let viewport else { return .zero }
        let y = flipped ? point.y : bounds.height - point.y
        return CGPoint(x: (point.x + viewport.scrollX) / viewport.scale, y: -(y + viewport.scrollY) / viewport.scale)
    }
}

struct MacPDFLiveEditor: View {
    @ObservedObject var surface: MacPDFLiveSurface

    var body: some View {
        if let frame = surface.frame, let editor = surface.editor {
            MacPDFEditorView(state: editor, registerDetailExit: { surface.flushEditor = $0 }, liveSurface: surface)
                .id(editor.identifier)
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .offset(x: frame.minX, y: frame.minY)
        }
    }
}

private enum LegacyLivePDFAnnotations {
    private struct Layout: Decodable { let annotations: [Annotation] }
    private struct Annotation: Decodable {
        let id: String
        let kind: String
        let x, y, w, h, width, fontSize: Double?
        let color, background, shape, text, image, source, target: String?
        let points: [[Double]]?
        let fill: Bool?
    }

    static func read(_ data: Data) throws -> [MacPDFObject] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        let annotations = try (try? decoder.decode(Layout.self, from: data).annotations) ?? decoder.decode([Annotation].self, from: data)
        let identifiers = annotations.reduce(into: [String: UUID]()) { result, annotation in
            result[annotation.id] = UUID(uuidString: annotation.id) ?? UUID()
        }
        let objects = annotations.compactMap { annotation -> MacPDFObject? in
            guard let id = identifiers[annotation.id] else { return nil }
            var style = MacPDFStyle()
            style.stroke = color(annotation.color) ?? style.stroke
            style.width = max(0.1, annotation.width ?? style.width)
            var object = MacPDFObject(page: 0, kind: .shape, bounds: .zero, style: style)
            object.id = id
            switch annotation.kind {
            case "pen", "highlighter", "handwriting":
                guard let samples = annotation.points, !samples.isEmpty,
                      samples.allSatisfy({ $0.count >= 2 && $0.prefix(2).allSatisfy({ abs($0) < 10_000_000 }) }) else { return nil }
                object.kind = .ink
                for sample in samples {
                    MacPDFPoint.appendInterpolated(MacPDFPoint(CGPoint(x: sample[0], y: -sample[1])), to: &object.points)
                }
                object.bounds = object.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: CGSize(width: 0.1, height: 0.1))) }
                if annotation.kind == "highlighter" { object.style.stroke.a = 0.32 }
                return object
            case "connector":
                guard let source = annotation.source.flatMap({ identifiers[$0] }),
                      let target = annotation.target.flatMap({ identifiers[$0] }) else { return nil }
                object.kind = .connector
                object.sourceID = source
                object.targetID = target
                return object
            case "shape", "text", "image":
                guard let x = annotation.x, let y = annotation.y, let w = annotation.w, let h = annotation.h,
                      w > 0, h > 0 else { return nil }
                object.bounds = CGRect(x: x, y: -y - h, width: w, height: h)
                object.kind = MacPDFObject.Kind(rawValue: annotation.kind) ?? .shape
                switch annotation.shape {
                case "rounded": object.shape = .roundedRectangle
                case "ellipse": object.shape = .circle
                case "triangle": object.shape = .triangle
                case "arrow": object.shape = .rightArrow
                default: break
                }
                object.style.fill = color(annotation.background) ?? .init(.clear)
                if annotation.fill == true {
                    object.style.fill = style.stroke
                    object.style.fill.a = 0.2
                }
                if let fontSize = annotation.fontSize { object.style.fontSize = fontSize }
                object.text = annotation.text ?? ""
                if let image = annotation.image, let separator = image.firstIndex(of: ",") {
                    object.imageData = Data(base64Encoded: String(image[image.index(after: separator)...]))
                }
                return object
            default:
                return nil
            }
        }
        let available = Set(objects.map(\.id))
        return objects.filter { object in
            object.sourceID.map(available.contains) != false && object.targetID.map(available.contains) != false
        }
    }

    private static func color(_ hex: String?) -> MacPDFRGBA? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return MacPDFRGBA(NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                                  blue: Double(value & 255) / 255, alpha: 1))
    }
}

struct MacPDFLiveControls: View {
    @ObservedObject var surface: MacPDFLiveSurface
    @ObservedObject var state: MacPDFEditorState

    var body: some View {
        HStack(spacing: 8) {
            Button("상세페이지로 돌아가기", systemImage: "chevron.left", action: surface.close)
            Toggle(isOn: Binding(get: { surface.editsSource && state.tool == .view }, set: { editing in
                surface.editsSource = editing
                if editing {
                    state.canvas?.freeNotes?.documentTool = false
                    state.selectTool(.view)
                }
            })) {
                Label("본문 편집", systemImage: "square.and.pencil")
            }
            .toggleStyle(.button)
            Divider().frame(height: 16)
            control("실행 취소", symbol: "arrow.uturn.backward", id: "pdf.live.undo", action: state.undo).disabled(!state.canUndo)
            control("다시 실행", symbol: "arrow.uturn.forward", id: "pdf.live.redo", action: state.redo).disabled(!state.canRedo)
            control("축소", symbol: "minus.magnifyingglass", id: "pdf.live.zoomOut") { surface.zoom(by: 0.8) }
            control("확대", symbol: "plus.magnifyingglass", id: "pdf.live.zoomIn") { surface.zoom(by: 1.25) }
            MacPDFLiveZoomLabel(percent: surface.zoomPercent)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(MacPDFPanelSurface(radius: 10))
    }

    private func control(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        MacPDFActionButton(title: "", symbol: symbol, identifier: id, accessibilityTitle: title, action: action)
            .frame(width: 22, height: 22)
    }
}

private struct MacPDFLiveZoomLabel: View {
    let percent: CurrentValueSubject<Int, Never>
    @State private var displayedPercent = 100

    var body: some View {
        Text("\(displayedPercent)%")
            .font(.caption)
            .monospacedDigit()
            .onReceive(percent) { displayedPercent = $0 }
    }
}
