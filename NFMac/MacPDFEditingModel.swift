import AppKit
import Combine
import CryptoKit
import PDFKit

enum MacPDFTool: String, CaseIterable, Identifiable, Codable {
    case view, select, pen, highlighter, neon, eraser, lasso, shape, text, image, connector
    var id: String { rawValue }
    var title: String {
        switch self {
        case .view: "화면 이동"
        case .select: "선택"
        case .pen: "펜"
        case .highlighter: "형광펜"
        case .neon: "네온"
        case .eraser: "지우개"
        case .lasso: "올가미"
        case .shape: "도형"
        case .text: "텍스트"
        case .image: "이미지"
        case .connector: "연결선"
        }
    }
    var symbol: String {
        switch self {
        case .view: "hand.draw"
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .neon: "light.beacon.max"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .shape: "square.on.circle"
        case .text: "textbox"
        case .image: "photo.badge.plus"
        case .connector: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

enum MacPDFShape: String, CaseIterable, Identifiable, Codable {
    case rectangle, roundedRectangle, circle, triangle, hexagon, rightArrow, star, speechBubble, diagonalArrow, diamond
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: "사각형"
        case .roundedRectangle: "둥근 사각형"
        case .circle: "원"
        case .triangle: "삼각형"
        case .hexagon: "육각형"
        case .rightArrow: "오른쪽 화살표"
        case .star: "별"
        case .speechBubble: "말풍선"
        case .diagonalArrow: "대각선 화살표"
        case .diamond: "마름모"
        }
    }
}

struct MacPDFRGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.deviceRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }
    var color: NSColor { NSColor(deviceRed: r, green: g, blue: b, alpha: a) }
    var key: String { "\(r),\(g),\(b),\(a)" }
}

struct MacPDFPoint: Codable, Equatable {
    var x: Double, y: Double, pressure: Double
    init(_ point: CGPoint, pressure: Double = 1) { x = point.x; y = point.y; self.pressure = pressure }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct MacPDFStyle: Codable, Equatable {
    var stroke = MacPDFRGBA(.systemBlue)
    var fill = MacPDFRGBA(.clear)
    var width: Double = 2.4
    var fontName = "Helvetica"
    var fontSize: Double = 18
    var bold = false, italic = false, underline = false, strike = false
    var alignment = 0
    var pressure = false
    var pressureStrength: Double = 1
    var roundCap = true
    var dashed = false, arrow = true
    var connectorRoute = "straight"
    var textBorder: MacPDFRGBA?
    mutating func apply(_ field: String, from other: MacPDFStyle) {
        switch field {
        case "stroke": stroke = other.stroke
        case "fill": fill = other.fill
        case "width": width = other.width
        case "fontName": fontName = other.fontName
        case "fontSize": fontSize = other.fontSize
        case "bold": bold = other.bold
        case "italic": italic = other.italic
        case "underline": underline = other.underline
        case "strike": strike = other.strike
        case "alignment": alignment = other.alignment
        case "pressure": pressure = other.pressure
        case "pressureStrength": pressureStrength = other.pressureStrength
        case "roundCap": roundCap = other.roundCap
        case "dashed": dashed = other.dashed
        case "arrow": arrow = other.arrow
        case "connectorRoute": connectorRoute = other.connectorRoute
        case "textBorder": textBorder = other.textBorder; width = max(1, width)
        default: break
        }
    }
}

struct MacPDFObject: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case ink, shape, text, image, connector }
    var id = UUID()
    var page: Int
    var kind: Kind
    var bounds: CGRect
    var style = MacPDFStyle()
    var shape = MacPDFShape.rectangle
    var points: [MacPDFPoint] = []
    var text = ""
    var textRTF: Data?
    var link: String?
    var imageData: Data?
    var originalImageData: Data?
    var attachmentPDF: Data?
    var attachmentName: String?
    var rotation: Double = 0
    var flipped = false
    var sourceID: UUID?, targetID: UUID?
    // Normalized edge anchors remain attached when objects move/resize/rotate.
    var sourceAnchor = MacPDFPoint(CGPoint(x: 1, y: 0.5))
    var targetAnchor = MacPDFPoint(CGPoint(x: 0, y: 0.5))
    var isTransient = false
}

struct MacPDFEditArchive: Codable {
    var version = 1
    var objects: [MacPDFObject] = []
    var favorites: Set<Int> = []
    var sourceHashes: Set<String>?
    var baseFileName: String?
}

@MainActor
final class MacPDFEditorState: ObservableObject {
    @Published var document: PDFDocument
    @Published var objects: [MacPDFObject] = []
    @Published var selection: Set<UUID> = []
    @Published var tool = MacPDFTool.view
    @Published var shape = MacPDFShape.rectangle
    @Published var style = MacPDFStyle()
    @Published var eraserSize: Double = 24
    @Published var currentPage = 0
    @Published var zoom = 100
    @Published var favorites: Set<Int> = []
    @Published var showPages = false
    @Published var favoritesOnly = false
    @Published var presentation = false
    @Published var fullscreen = false
    @Published var horizontal = false
    @Published var paged = false
    @Published var twoPages = false
    @Published var verticalToolbar = false
    @Published var toolbarOffset = CGSize.zero
    @Published var toolbarScale: Double = 1
    @Published var paletteLocked = false
    @Published var alwaysShowPalette = false
    @Published var paletteDetached = false
    @Published var paletteOffset = CGSize.zero
    @Published var paletteSize = CGSize(width: 350, height: 450)
    @Published var pageControlPosition = "bottom"
    @Published var palette: [MacPDFRGBA] = [.init(.black), .init(.systemBlue), .init(.systemRed), .init(.systemOrange), .init(.systemGreen)]
    @Published var status = ""
    @Published var error: String?
    @Published var isSaving = false
    @Published var optionsTool: MacPDFTool?
    @Published var editingPaletteIndex: Int?
    @Published var menuVisible = false
    @Published var selectionViewRect: CGRect = .zero
    @Published var isTextEditing = false
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    var onSave: ((Data) async throws -> Void)?
    var exportOnSave = false
    var onOpenAttachment: ((Data, String) -> Void)?
    weak var canvas: MacPDFEditingView?
    let identifier: String
    let fileName: String
    let sourceURL: URL?
    let cookieHeader: String?
    private var directory: URL
    private var sourceHashes: Set<String> = []
    private var undoStack: [Change] = [], redoStack: [Change] = []
    private var saveTask: Task<Void, Never>?
    private var baseChanged = false
    private var pendingDocumentSave = false
    private var neonTasks: [UUID: Task<Void, Never>] = [:]
    private var paletteOptions: [String: MacPDFStyle] = [:]
    private var toolOptions: [String: MacPDFStyle] = [:]
    private var archiveReadFailed = false
    private var baseFileName = "base.pdf"
    func markImportedAnnotationsChanged() { baseChanged = true; pendingDocumentSave = true }
    private struct Snapshot { var objects: [MacPDFObject]; var favorites: Set<Int>; var base: Data? }
    private struct Change { var before: Snapshot; var after: Snapshot }

    init(document: PDFDocument, identifier: String, fileName: String, sourceURL: URL? = nil, cookieHeader: String? = nil, sourceData: Data? = nil, directory: URL? = nil) {
        self.document = document; self.identifier = identifier; self.fileName = fileName
        self.sourceURL = sourceURL; self.cookieHeader = cookieHeader
        let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NF/PDFEdits/mac-\(digest)", isDirectory: true)
        if let data = sourceData { sourceHashes.insert(Self.hash(data)) }
        restore()
        if !archiveReadFailed { importEditableAnnotations() }
        if let data = UserDefaults.standard.data(forKey: "nf.mac.pdf.style"), let saved = try? JSONDecoder().decode(MacPDFStyle.self, from: data) { style = saved }
        if let data = UserDefaults.standard.data(forKey: "nf.mac.pdf.palette"), let saved = try? JSONDecoder().decode([MacPDFRGBA].self, from: data), !saved.isEmpty { palette = saved }
        if let data = UserDefaults.standard.data(forKey: "nf.mac.pdf.paletteOptions"), let saved = try? JSONDecoder().decode([String: MacPDFStyle].self, from: data) { paletteOptions = saved }
        if let data = UserDefaults.standard.data(forKey: "nf.mac.pdf.toolOptions"), let saved = try? JSONDecoder().decode([String: MacPDFStyle].self, from: data) { toolOptions = saved }
        paletteLocked = UserDefaults.standard.bool(forKey: "nf.mac.pdf.paletteLocked")
        alwaysShowPalette = UserDefaults.standard.bool(forKey: "nf.mac.pdf.alwaysShowPalette")
        paletteDetached = UserDefaults.standard.bool(forKey: "nf.mac.pdf.paletteDetached")
        paletteOffset = CGSize(width: UserDefaults.standard.double(forKey: "nf.mac.pdf.paletteX"), height: UserDefaults.standard.double(forKey: "nf.mac.pdf.paletteY"))
        paletteSize = CGSize(width: max(280, UserDefaults.standard.double(forKey: "nf.mac.pdf.paletteWidth").nonzero(default: 350)), height: max(220, UserDefaults.standard.double(forKey: "nf.mac.pdf.paletteHeight").nonzero(default: 450)))
        pageControlPosition = UserDefaults.standard.string(forKey: "nf.mac.pdf.pageControlPosition") ?? "bottom"
        verticalToolbar = UserDefaults.standard.bool(forKey: "nf.mac.pdf.verticalToolbar")
        toolbarScale = max(0.7, min(1.5, UserDefaults.standard.double(forKey: "nf.mac.pdf.toolbarScale").nonzero(default: 1)))
        toolbarOffset = CGSize(width: UserDefaults.standard.double(forKey: "nf.mac.pdf.toolbarX"), height: UserDefaults.standard.double(forKey: "nf.mac.pdf.toolbarY"))
    }

    var selected: MacPDFObject? { objects.first { selection.contains($0.id) } }
    var pageCount: Int { document.pageCount }
    func pageObjects(_ page: Int) -> [MacPDFObject] { objects.filter { $0.page == page } }
    private func snapshot(structure: Bool) -> Snapshot { Snapshot(objects: objects.filter { !$0.isTransient }, favorites: favorites, base: structure ? basePDFData() : nil) }

    func change(structure: Bool = false, _ action: () -> Void) {
        canvas?.finishTextEditing()
        let before = snapshot(structure: structure)
        action()
        let after = snapshot(structure: structure)
        guard before.objects != after.objects || before.favorites != after.favorites || before.base != after.base else { return }
        undoStack.append(Change(before: before, after: after)); if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll(); baseChanged = baseChanged || structure
        didChange()
    }

    // Dragging is preview-only; create one undo entry when the gesture ends.
    func commitObjects(from previous: [MacPDFObject]) {
        guard previous != objects else { return }
        undoStack.append(Change(before: Snapshot(objects: previous.filter { !$0.isTransient }, favorites: favorites, base: nil), after: snapshot(structure: false)))
        if undoStack.count > 60 { undoStack.removeFirst() }; redoStack.removeAll(); didChange()
    }
    private func didChange() {
        selection = selection.intersection(Set(objects.map(\.id)))
        pendingDocumentSave = true
        undoCount = undoStack.count; redoCount = redoStack.count
        canvas?.refreshAnnotations()
        let stored = persist()
        status = stored ? "로컬 편집 저장됨" : "로컬 저장 실패 · PDF 다운로드로 보관해 주세요"
        saveTask?.cancel()
        // Remote replacement is explicit. Local documents save after a pause.
        if sourceURL == nil {
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.save()
            }
        }
    }
    func undo() {
        canvas?.finishTextEditing()
        guard let item = undoStack.popLast() else { return }
        redoStack.append(item); apply(item.before)
    }
    func redo() {
        canvas?.finishTextEditing()
        guard let item = redoStack.popLast() else { return }
        undoStack.append(item); apply(item.after)
    }
    private func apply(_ snapshot: Snapshot) {
        if let base = snapshot.base, let pdf = PDFDocument(data: base) { document = pdf; canvas?.document = pdf; baseChanged = true }
        objects = snapshot.objects; favorites = snapshot.favorites; selection = []
        currentPage = min(currentPage, max(0, document.pageCount - 1)); didChange()
    }
    func add(_ object: MacPDFObject) {
        if object.isTransient {
            objects.append(object); canvas?.refreshAnnotations()
            neonTasks.values.forEach { $0.cancel() }; neonTasks.removeAll()
            neonTasks[object.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.objects.removeAll { $0.isTransient }; self.neonTasks[object.id] = nil; self.canvas?.refreshAnnotations()
            }
        } else { change { objects.append(object); selection = [object.id] } }
    }
    func updateSelected(_ action: (inout MacPDFObject) -> Void) {
        change { for index in objects.indices where selection.contains(objects[index].id) { action(&objects[index]) } }
    }
    func deleteSelected() {
        let ids = selection
        change { objects.removeAll { ids.contains($0.id) || $0.sourceID.map(ids.contains) == true || $0.targetID.map(ids.contains) == true }; selection = []; menuVisible = false }
    }
    func duplicateSelected() {
        let selectedObjects = objects.filter { selection.contains($0.id) && !$0.isTransient }
        var copies = selectedObjects.map { object -> MacPDFObject in
            var copy = object; copy.id = UUID(); copy.bounds = copy.bounds.offsetBy(dx: 18, dy: -18)
            copy.points = copy.points.map { MacPDFPoint($0.cgPoint.applying(CGAffineTransform(translationX: 18, y: -18)), pressure: $0.pressure) }
            return copy
        }
        let mapping = Dictionary(uniqueKeysWithValues: zip(selectedObjects, copies).map { ($0.id, $1.id) })
        for i in copies.indices { copies[i].sourceID = copies[i].sourceID.flatMap { mapping[$0] ?? $0 }; copies[i].targetID = copies[i].targetID.flatMap { mapping[$0] ?? $0 } }
        change { objects.append(contentsOf: copies); selection = Set(copies.map(\.id)) }
    }
    func reorderSelected(front: Bool) {
        change { let picked = objects.filter { selection.contains($0.id) }; objects.removeAll { selection.contains($0.id) }; objects = front ? objects + picked : picked + objects }
    }
    func copySelected() {
        guard let data = try? JSONEncoder().encode(objects.filter { selection.contains($0.id) && !$0.isTransient }) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .init("com.nf.pdf.objects"))
        if selection.count == 1, let object = selected, object.kind == .text { NSPasteboard.general.setString(object.text, forType: .string) }
    }
    func paste() {
        if let data = NSPasteboard.general.data(forType: .init("com.nf.pdf.objects")), var copies = try? JSONDecoder().decode([MacPDFObject].self, from: data) {
            let mapping = Dictionary(uniqueKeysWithValues: copies.map { ($0.id, UUID()) })
            for i in copies.indices {
                copies[i].id = mapping[copies[i].id]!; copies[i].page = currentPage; copies[i].bounds = copies[i].bounds.offsetBy(dx: 18, dy: -18)
                copies[i].points = copies[i].points.map { MacPDFPoint(CGPoint(x: $0.x + 18, y: $0.y - 18), pressure: $0.pressure) }
                func destination(_ id: UUID) -> UUID? { mapping[id] ?? (objects.contains { $0.id == id && $0.page == currentPage } ? id : nil) }
                copies[i].sourceID = copies[i].sourceID.flatMap(destination); copies[i].targetID = copies[i].targetID.flatMap(destination)
            }
            copies.removeAll { $0.kind == .connector && ($0.sourceID == nil || $0.targetID == nil) }
            change { objects.append(contentsOf: copies); selection = Set(copies.map(\.id)) }
        } else if let image = NSImage(pasteboard: .general) { insertImage(image) }
    }
    func insertImage(_ image: NSImage, at point: CGPoint? = nil) {
        guard let data = image.tiffRepresentation else { return }
        let placement = canvas?.visibleInsertion() ?? (currentPage, document.page(at: currentPage)?.bounds(for: .cropBox) ?? .zero)
        guard let page = document.page(at: placement.0) else { return }
        currentPage = placement.0
        let rect = imageInsertionBounds(image.size, visible: placement.1, page: page.bounds(for: .cropBox), center: point)
        add(MacPDFObject(page: currentPage, kind: .image, bounds: rect, imageData: data, originalImageData: data))
        selectObjects(selection, showMenu: true); optionsTool = nil
    }
    func imageInsertionBounds(_ size: CGSize, visible: CGRect, page: CGRect, center: CGPoint? = nil) -> CGRect {
        let scale = min(min(visible.width * 0.62, 320) / max(1, size.width), min(visible.height * 0.62, 320) / max(1, size.height))
        let fitted = CGSize(width: max(20, size.width * scale), height: max(20, size.height * scale))
        let p = center ?? CGPoint(x: visible.midX, y: visible.midY)
        return Self.clamped(CGRect(x: p.x - fitted.width / 2, y: p.y - fitted.height / 2, width: fitted.width, height: fitted.height), to: page)
    }
    static func clamped(_ rect: CGRect, to page: CGRect) -> CGRect {
        let w = min(rect.width, page.width), h = min(rect.height, page.height)
        return CGRect(x: min(max(rect.minX, page.minX), page.maxX - w), y: min(max(rect.minY, page.minY), page.maxY - h), width: w, height: h)
    }
    func addVisibleObject(_ kind: MacPDFObject.Kind, shape: MacPDFShape? = nil) {
        canvas?.finishTextEditing()
        let placement = canvas?.visibleInsertion() ?? (currentPage, document.page(at: currentPage)?.bounds(for: .cropBox) ?? .zero)
        guard let page = document.page(at: placement.0) else { return }
        currentPage = placement.0
        let size = kind == .text ? CGSize(width: min(230, placement.1.width * 0.62), height: 80) : CGSize(width: min(176, placement.1.width * 0.45), height: min(112, placement.1.height * 0.3))
        let rect = Self.clamped(CGRect(x: placement.1.midX - size.width / 2, y: placement.1.midY - size.height / 2, width: max(30, size.width), height: size.height), to: page.bounds(for: .cropBox))
        var object = MacPDFObject(page: currentPage, kind: kind, bounds: rect, style: style, shape: shape ?? self.shape, text: kind == .text ? "텍스트를 입력하세요" : "")
        if kind == .text { object.style.textBorder = object.style.textBorder ?? .init(.clear) }
        add(object); selectObjects([object.id], showMenu: true); optionsTool = nil
    }
    func selectObjects(_ ids: Set<UUID>, showMenu: Bool) {
        selection = ids; menuVisible = showMenu && !ids.isEmpty
        if let object = selected, ids.count == 1 {
            style = object.style; shape = object.shape
            switch object.kind { case .text: tool = .text; case .image: tool = .image; case .shape: tool = .shape; case .connector: tool = .connector; case .ink: tool = .select }
        }
        canvas?.refreshAnnotations()
    }
    func setStyle(_ next: MacPDFStyle, field: String) {
        style = next
        if isTextEditing { canvas?.applyTextFormat(field: field, style: next) }
        else if !selection.isEmpty {
            updateSelected { object in
                object.style.apply(field, from: next)
                if object.kind == .text {
                    let text = MacPDFTextFormatting.attributed(object)
                    object.textRTF = MacPDFTextFormatting.apply(field: field, style: object.style, to: text, range: NSRange(location: 0, length: text.length)).rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
                }
            }
        }
        if let index = editingPaletteIndex, palette.indices.contains(index) {
            if field == "stroke" { palette[index] = next.stroke }
            paletteOptions[next.stroke.key] = next
        }
        rememberSettings()
    }
    func resetSelectedImageSize() {
        guard let object = selected, let data = object.imageData, let image = NSImage(data: data), let page = document.page(at: object.page) else { return }
        let visible = canvas?.visibleInsertion().1 ?? page.bounds(for: .cropBox)
        let rect = imageInsertionBounds(image.size, visible: visible, page: page.bounds(for: .cropBox), center: CGPoint(x: object.bounds.midX, y: object.bounds.midY))
        updateSelected { $0.bounds = rect }
    }
    func rotateSelectedImageContent() {
        guard let object = selected, let data = object.imageData, let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.height, height: cg.width, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(cg.width)); context.rotate(by: -.pi / 2); context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let rotated = context.makeImage(), let output = NSImage(cgImage: rotated, size: .zero).tiffRepresentation else { return }
        updateSelected { $0.imageData = output }
    }
    func pageOperation(_ operation: String) {
        guard let page = document.page(at: currentPage) else { return }
        change(structure: true) {
            if operation == "delete" {
                guard document.pageCount > 1 else { return }
                document.removePage(at: currentPage)
                objects.removeAll { $0.page == currentPage }
                for i in objects.indices where objects[i].page > currentPage { objects[i].page -= 1 }
                favorites = Set(favorites.filter { $0 != currentPage }.map { $0 > currentPage ? $0 - 1 : $0 })
            } else {
                let insert = currentPage + 1
                let newPage: PDFPage
                if operation == "duplicate", let data = basePDFData(), let clean = PDFDocument(data: data), let copy = clean.page(at: currentPage)?.copy() as? PDFPage {
                    newPage = copy
                } else {
                    newPage = PDFPage(); newPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
                }
                document.insert(newPage, at: insert)
                let previous = objects.filter { $0.page == currentPage }
                for i in objects.indices where objects[i].page >= insert { objects[i].page += 1 }
                favorites = Set(favorites.map { $0 >= insert ? $0 + 1 : $0 })
                if operation == "duplicate" {
                    let mapping = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, UUID()) })
                    objects += previous.map { original in
                        var copy = original; copy.id = mapping[original.id]!; copy.page = insert
                        copy.sourceID = copy.sourceID.flatMap { mapping[$0] }; copy.targetID = copy.targetID.flatMap { mapping[$0] }; return copy
                    }
                }
                currentPage = insert
            }
            currentPage = min(currentPage, document.pageCount - 1)
        }
        goToPage(currentPage)
    }
    func movePage(from: Int, to: Int) {
        guard from != to, from >= 0, to >= 0, from < pageCount, to < pageCount, let page = document.page(at: from) else { return }
        func mapped(_ index: Int) -> Int { if index == from { return to }; if from < to && index > from && index <= to { return index - 1 }; if from > to && index >= to && index < from { return index + 1 }; return index }
        change(structure: true) { document.removePage(at: from); document.insert(page, at: to); for i in objects.indices { objects[i].page = mapped(objects[i].page) }; favorites = Set(favorites.map(mapped)); currentPage = to }
        goToPage(to)
    }
    func toggleFavorite() { change { if favorites.contains(currentPage) { favorites.remove(currentPage) } else { favorites.insert(currentPage) } } }
    func goToPage(_ index: Int) { guard let page = document.page(at: index) else { return }; canvas?.finishTextEditing(); selection = []; menuVisible = false; currentPage = index; canvas?.go(to: page) }
    func configureView() {
        let direction: PDFDisplayDirection = horizontal ? .horizontal : .vertical
        let mode: PDFDisplayMode = twoPages ? (paged ? .twoUp : .twoUpContinuous) : (paged ? .singlePage : .singlePageContinuous)
        if canvas?.displayDirection != direction { canvas?.finishTextEditing(); canvas?.displayDirection = direction }
        if canvas?.displayMode != mode { canvas?.finishTextEditing(); canvas?.displayMode = mode }
    }
    func setZoom(_ percent: Int) { canvas?.finishTextEditing(); zoom = max(10, min(1000, percent)); canvas?.autoScales = false; canvas?.scaleFactor = CGFloat(zoom) / 100 }
    func rememberSettings() {
        paletteOptions[style.stroke.key] = style; toolOptions[tool.rawValue] = style
        UserDefaults.standard.set(try? JSONEncoder().encode(style), forKey: "nf.mac.pdf.style")
        UserDefaults.standard.set(try? JSONEncoder().encode(palette), forKey: "nf.mac.pdf.palette")
        UserDefaults.standard.set(try? JSONEncoder().encode(paletteOptions), forKey: "nf.mac.pdf.paletteOptions")
        UserDefaults.standard.set(try? JSONEncoder().encode(toolOptions), forKey: "nf.mac.pdf.toolOptions")
        UserDefaults.standard.set(paletteLocked, forKey: "nf.mac.pdf.paletteLocked")
        UserDefaults.standard.set(alwaysShowPalette, forKey: "nf.mac.pdf.alwaysShowPalette")
        UserDefaults.standard.set(paletteDetached, forKey: "nf.mac.pdf.paletteDetached")
        UserDefaults.standard.set(paletteOffset.width, forKey: "nf.mac.pdf.paletteX")
        UserDefaults.standard.set(paletteOffset.height, forKey: "nf.mac.pdf.paletteY")
        UserDefaults.standard.set(paletteSize.width, forKey: "nf.mac.pdf.paletteWidth")
        UserDefaults.standard.set(paletteSize.height, forKey: "nf.mac.pdf.paletteHeight")
        UserDefaults.standard.set(pageControlPosition, forKey: "nf.mac.pdf.pageControlPosition")
        UserDefaults.standard.set(verticalToolbar, forKey: "nf.mac.pdf.verticalToolbar")
        UserDefaults.standard.set(toolbarScale, forKey: "nf.mac.pdf.toolbarScale")
        UserDefaults.standard.set(toolbarOffset.width, forKey: "nf.mac.pdf.toolbarX")
        UserDefaults.standard.set(toolbarOffset.height, forKey: "nf.mac.pdf.toolbarY")
    }
    func selectPalette(_ color: MacPDFRGBA) {
        if style.stroke == color { editingPaletteIndex = editingPaletteIndex == nil ? palette.firstIndex(of: color) : nil; return }
        rememberSettings(); editingPaletteIndex = nil
        var next = paletteOptions[color.key] ?? style; next.stroke = color
        setStyle(next, field: "stroke")
    }
    func selectTool(_ next: MacPDFTool) {
        if tool == next {
            menuVisible = false
            if next != .view && next != .select && next != .lasso { optionsTool = optionsTool == next ? nil : next }
            return
        }
        canvas?.finishTextEditing(); canvas?.cancelGesture(); selection = []; menuVisible = false; editingPaletteIndex = nil
        rememberSettings(); tool = next
        if let saved = toolOptions[next.rawValue] { style = saved }
        else if next == .highlighter { style.width = 18; style.pressure = false }
        optionsTool = [.shape, .text, .image, .connector].contains(next) || alwaysShowPalette ? next : nil
        canvas?.refreshAnnotations()
    }
    func resetSettings() { style = MacPDFStyle(); eraserSize = 24; toolbarOffset = .zero; toolbarScale = 1; verticalToolbar = false; paletteLocked = false; alwaysShowPalette = false; paletteDetached = false; paletteOffset = .zero; paletteSize = CGSize(width: 350, height: 450); pageControlPosition = "bottom"; paletteOptions = [:]; toolOptions = [:]; optionsTool = nil; editingPaletteIndex = nil; menuVisible = false; palette = [.init(.black), .init(.systemBlue), .init(.systemRed), .init(.systemOrange), .init(.systemGreen)]; rememberSettings() }

    func basePDFData() -> Data? {
        var removed: [(PDFPage, PDFAnnotation)] = []
        for index in 0..<pageCount { guard let page = document.page(at: index) else { continue }; for annotation in page.annotations where annotation is MacPDFObjectAnnotation { removed.append((page, annotation)); page.removeAnnotation(annotation) } }
        defer { removed.forEach { $0.0.addAnnotation($0.1) } }
        return document.dataRepresentation()
    }
    func exportPDF() -> Data? {
        canvas?.finishTextEditing()
        guard let base = basePDFData(), let clean = PDFDocument(data: base) else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        for index in 0..<clean.pageCount {
            guard let page = clean.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox)
            let boxData = withUnsafeBytes(of: &box) { Data($0) }
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            page.draw(with: .mediaBox, to: context)
            for object in pageObjects(index) where !object.isTransient { MacPDFObjectRenderer.draw(object, objects: objects, context: context) }
            for object in pageObjects(index) where object.kind == .text {
                if let link = object.link, let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { context.setURL(url as CFURL, for: object.bounds) }
            }
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    @discardableResult func persist() -> Bool {
        guard !archiveReadFailed else { error = "기존 편집 파일을 읽을 수 없어 덮어쓰지 않습니다. 현재 화면은 PDF 다운로드로 보관해 주세요."; return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previousBase = directory.appendingPathComponent(baseFileName)
            var nextBaseFileName = baseFileName
            if baseChanged || !FileManager.default.fileExists(atPath: previousBase.path) {
                guard let data = basePDFData() else { throw CocoaError(.fileWriteUnknown) }
                nextBaseFileName = "base-\(UUID().uuidString).pdf"
                try data.write(to: directory.appendingPathComponent(nextBaseFileName), options: .atomic)
            }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let archive = MacPDFEditArchive(objects: objects.filter { !$0.isTransient }, favorites: favorites, sourceHashes: sourceHashes, baseFileName: nextBaseFileName)
            try encoder.encode(archive).write(to: directory.appendingPathComponent("edits.plist"), options: .atomic)
            // The atomic manifest is the commit point for base + edit objects.
            // Never overwrite the base referenced by the previous manifest.
            baseFileName = nextBaseFileName; baseChanged = false
            if previousBase.lastPathComponent != nextBaseFileName { try? FileManager.default.removeItem(at: previousBase) }
            return true
        } catch { self.error = "편집 데이터를 저장하지 못했습니다: \(error.localizedDescription)"; return false }
    }
    private func restore() {
        let archiveURL = directory.appendingPathComponent("edits.plist")
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return }
        do {
            let archive = try PropertyListDecoder().decode(MacPDFEditArchive.self, from: Data(contentsOf: archiveURL))
            guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            if sourceURL != nil, let previous = archive.sourceHashes, !sourceHashes.isEmpty, previous.isDisjoint(with: sourceHashes) {
                // Never replace a newer server PDF with an older cached base.
                // Keep the previous editing folder and start a separate revision.
                directory = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-source-" + sourceHashes.sorted().joined().prefix(16), isDirectory: true)
                status = "서버 원본이 변경되어 별도 편집본으로 열었습니다. 이전 편집본은 보관됩니다."
                restore(); return
            }
            sourceHashes.formUnion(archive.sourceHashes ?? [])
            let name = archive.baseFileName ?? "base.pdf"
            guard name == (name as NSString).lastPathComponent, name.hasSuffix(".pdf"), let base = PDFDocument(url: directory.appendingPathComponent(name)) else { throw CocoaError(.fileReadCorruptFile) }
            document = base; baseFileName = name
            objects = archive.objects.filter { $0.page >= 0 && $0.page < document.pageCount }; favorites = archive.favorites.filter { $0 >= 0 && $0 < document.pageCount }
        } catch { archiveReadFailed = true; self.error = "저장된 편집 데이터를 복원하지 못했습니다. 원본과 기존 편집 파일은 유지됩니다: \(error.localizedDescription)" }
    }
    func save() async {
        guard !isSaving else { return }
        canvas?.finishTextEditing(); guard persist() else { return }; guard let base = basePDFData() else { error = "PDF를 생성하지 못했습니다."; return }
        guard let onSave else { pendingDocumentSave = false; status = "로컬 편집 저장됨"; return }
        isSaving = true; defer { isSaving = false }
        do {
            let data = sourceURL == nil && !exportOnSave ? base : (exportPDF() ?? base)
            try await onSave(data)
            if sourceURL != nil { sourceHashes.insert(Self.hash(data)); persist() }
            pendingDocumentSave = false; status = "저장 완료"
        }
        catch { self.error = "PDF 저장 실패: \(error.localizedDescription)"; status = "저장 실패" }
    }
    func close() { canvas?.finishTextEditing(); saveTask?.cancel(); persist(); rememberSettings(); if pendingDocumentSave && sourceURL == nil { Task { await save() } } }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private extension Double { func nonzero(default fallback: Double) -> Double { self == 0 ? fallback : self } }
