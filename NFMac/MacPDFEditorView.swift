import AppKit
import Combine
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MacPDFWorkspace: View {
    @StateObject private var state: MacPDFEditorState
    var isContainerResizing = false
    var isFullscreen = false
    var onToggleFullscreen: (() -> Void)?
    var onExitPaneExpansion: (() -> Void)?
    var isPaneExpanded = false
    var onTogglePaneExpanded: (() -> Void)?
    init(document: PDFDocument, identifier: String, fileName: String, sourceURL: URL? = nil, cookieHeader: String? = nil, sourceData: Data? = nil, isContainerResizing: Bool = false, exportOnSave: Bool = false, isFullscreen: Bool = false, onToggleFullscreen: (() -> Void)? = nil, onExitPaneExpansion: (() -> Void)? = nil, isPaneExpanded: Bool = false, onTogglePaneExpanded: (() -> Void)? = nil, editorDirectory: URL? = nil, onSave: ((Data) async throws -> Void)? = nil) {
        let editor = MacPDFEditorState(document: document, identifier: identifier, fileName: fileName, sourceURL: sourceURL, cookieHeader: cookieHeader, sourceData: sourceData, directory: editorDirectory)
        editor.onSave = onSave; editor.exportOnSave = exportOnSave; _state = StateObject(wrappedValue: editor); self.isContainerResizing = isContainerResizing
        self.isFullscreen = isFullscreen; self.onToggleFullscreen = onToggleFullscreen
        self.onExitPaneExpansion = onExitPaneExpansion
        self.isPaneExpanded = isPaneExpanded; self.onTogglePaneExpanded = onTogglePaneExpanded
    }
    var body: some View { MacPDFEditorView(state: state, isContainerResizing: isContainerResizing, isFullscreen: isFullscreen, onToggleFullscreen: onToggleFullscreen, onExitPaneExpansion: onExitPaneExpansion, isPaneExpanded: isPaneExpanded, onTogglePaneExpanded: onTogglePaneExpanded) }
}

struct MacPDFEditorView: View {
    @ObservedObject var state: MacPDFEditorState
    var isContainerResizing = false
    var isFullscreen = false
    var onToggleFullscreen: (() -> Void)?
    var onExitPaneExpansion: (() -> Void)?
    var isPaneExpanded = false
    var onTogglePaneExpanded: (() -> Void)?
    @StateObject private var sharing = MacPDFExportController()
    @State private var photo: PhotosPickerItem?
    @State private var modal: Modal?
    @State private var showReset = false
    @GestureState private var toolbarDrag = CGSize.zero
    @GestureState private var paletteDrag = CGSize.zero
    private var detachedPaletteVisible: Bool { (state.alwaysShowPalette || state.paletteDetached) && !state.presentation }
    enum Modal: String, Identifiable { case crop, board, imageEditor, systemImageEditor; var id: String { rawValue } }
    var body: some View {
        VStack(spacing: 0) {
            if !state.presentation { header; Divider() }
            HStack(spacing: 0) {
                if state.showPages && !state.presentation { MacPDFPagesView(state: state).frame(width: 160); Divider() }
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        MacPDFCanvas(state: state, isContainerResizing: isContainerResizing, onExitPaneExpansion: onExitPaneExpansion)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !state.presentation {
                            floatingToolbar
                                .scaleEffect(state.toolbarScale, anchor: .bottom)
                                .offset(clampedToolbarOffset(in: geometry.size))
                                .padding(.bottom, 14)
                        } else {
                            Button("프레젠테이션 종료") { state.presentation = false }
                                .padding(8).background(.regularMaterial, in: Capsule()).padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if detachedPaletteVisible { detachedPalette(in: geometry.size) }
                    }
                    .overlay(alignment: .topLeading) {
                        if state.menuVisible && !state.isTextEditing && !state.selection.isEmpty && !state.presentation {
                            MacPDFObjectMenu(state: state, canvasSize: geometry.size, onImageAction: handleImageAction)
                        }
                    }
                    .overlay(alignment: .top) {
                        if state.isTextEditing { MacPDFTextAssistant(state: state).padding(8) }
                    }
                    .overlay(alignment: state.pageControlPosition == "left" ? .leading : .trailing) {
                        if !state.presentation && state.pageControlPosition != "bottom" { sidePageControls }
                    }
                }
            }
            if !state.presentation { footer }
        }
        .sheet(item: $modal, onDismiss: { state.menuVisible = !state.selection.isEmpty; state.canvas?.window?.makeFirstResponder(state.canvas) }) { item in
            switch item {
            case .crop: MacPDFCropView(state: state).frame(width: 620, height: 620)
            case .board: MacPDFBoardView().frame(minWidth: 1000, minHeight: 700)
            case .imageEditor: MacPDFImageEditView(parent: state).frame(minWidth: 850, minHeight: 650)
            case .systemImageEditor: MacPDFSystemImageEditView(parent: state).frame(width: 580, height: 420)
            }
        }
        .alert("PDF 편집", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("확인", role: .cancel) { state.error = nil }
        } message: { Text(state.error ?? "") }
        .confirmationDialog("도구 위치·크기·팔레트 설정을 초기화할까요? PDF 편집 내용은 유지됩니다.", isPresented: $showReset) {
            Button("설정 초기화") { state.resetSettings() }
        }
        .onChange(of: photo) { _, item in
            Task {
                do { if let data = try await item?.loadTransferable(type: Data.self), let image = NSImage(data: data) { state.insertImage(image) } }
                catch { state.error = "사진을 불러오지 못했습니다: \(error.localizedDescription)" }
                photo = nil
            }
        }
        .onDisappear { state.close() }
        .onChange(of: state.selection) { _, _ in state.canvas?.refreshAnnotations() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pdf.editor")
    }
    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { state.showPages.toggle() } label: { Image(systemName: "sidebar.left") }.help("페이지 목록")
                Button { state.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(state.undoCount == 0).help("실행 취소 ⌘Z")
                Button { state.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(state.redoCount == 0).help("다시 실행 ⇧⌘Z")
                Menu("페이지") {
                    Button("빈 페이지 추가") { state.pageOperation("add") }
                    Button("현재 페이지 복제") { state.pageOperation("duplicate") }
                    Button("현재 페이지 삭제", role: .destructive) { state.pageOperation("delete") }.disabled(state.pageCount <= 1)
                    Button(state.favorites.contains(state.currentPage) ? "즐겨찾기 해제" : "즐겨찾기 추가") { state.toggleFavorite() }
                }
                Menu("보기") {
                    Toggle("가로 보기", isOn: $state.horizontal)
                    Toggle("페이지 단위 보기", isOn: $state.paged)
                    Toggle("두 페이지 보기", isOn: $state.twoPages)
                    Picker("페이지 이동 버튼 위치", selection: $state.pageControlPosition) { Text("아래").tag("bottom"); Text("왼쪽").tag("left"); Text("오른쪽").tag("right") }
                    Button("화면에 맞춤") { state.canvas?.autoScales = true }
                    Button(isFullscreen ? "전체화면 종료" : "전체화면 보기") { toggleFullscreen() }
                    Button("프레젠테이션") { state.presentation = true }
                }
                Button("저장") { Task { await state.save() } }.disabled(state.isSaving)
                    .help(state.sourceURL == nil ? "이 Mac의 문서와 편집 정보를 저장합니다. 서버 첨부 파일은 변경하지 않습니다." : "편집 내용을 포함한 PDF로 기존 서버 첨부 파일을 교체하고 저장 결과를 확인합니다.")
                if let onTogglePaneExpanded, !isFullscreen {
                    MacPDFActionButton(title: "", symbol: isPaneExpanded ? "arrow.down.right.and.arrow.up.left" : "rectangle.split.2x1", identifier: "pdf.expandPane", accessibilityTitle: isPaneExpanded ? "분할 영역 전체보기 종료" : "분할 영역 전체보기", action: onTogglePaneExpanded)
                    .frame(width: 22, height: 22)
                    .help(isPaneExpanded ? "분할 영역 전체보기 종료" : "분할 영역 전체보기")
                }
                MacPDFActionButton(title: "PDF 다운로드", identifier: "pdf.download") { sharing.download(state) }.frame(width: 90, height: 22)
                Button { sharing.share(state) } label: { Image(systemName: "square.and.arrow.up") }.help("편집 PDF 외부 공유")
                Menu("더보기") {
                    Button(isFullscreen ? "전체화면 종료" : "전체화면 보기") { toggleFullscreen() }
                    Button("문서 연결 보드") { modal = .board }
                    Button("Google Drive에 저장") { Task { await state.syncToGoogleDrive() } }
                    Button("Google Drive 연결 해제") { state.unlinkGoogleDrive() }
                    Toggle("도구창 세로 배치", isOn: $state.verticalToolbar)
                    Button("편집 도구 설정 초기화") { showReset = true }
                }
            }.buttonStyle(.borderless).padding(10)
        }
        .onChange(of: state.horizontal) { _, _ in state.configureView() }
        .onChange(of: state.paged) { _, _ in state.configureView() }
        .onChange(of: state.twoPages) { _, _ in state.configureView() }
    }
    private func toggleFullscreen() {
        if let onToggleFullscreen { onToggleFullscreen() }
        else { state.canvas?.window?.toggleFullScreen(nil) }
    }
    private var floatingToolbar: some View {
        Group {
            if state.verticalToolbar {
                ScrollView(.vertical, showsIndicators: false) { VStack(spacing: 6) { toolbarUtilities; toolButtons } }.frame(width: 42, height: 400)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 7) { toolbarUtilities; toolButtons } }.frame(maxWidth: 720, minHeight: 36, maxHeight: 36)
            }
        }
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).shadow(radius: 4)
        .popover(isPresented: Binding(get: { state.optionsTool != nil && !detachedPaletteVisible }, set: { if !$0 { state.optionsTool = nil } }), arrowEdge: .top) { options.frame(width: 350).padding(16) }
    }
    @ViewBuilder private var toolbarUtilities: some View {
                Image(systemName: state.paletteLocked ? "lock" : "arrow.up.and.down.and.arrow.left.and.right")
                    .frame(width: 32, height: 30)
                    .help("드래그하여 도구창 이동")
                    .gesture(DragGesture().updating($toolbarDrag) { value, drag, _ in if !state.paletteLocked { drag = value.translation } }.onEnded { value in
                        if !state.paletteLocked { state.toolbarOffset.width += value.translation.width; state.toolbarOffset.height += value.translation.height; state.rememberSettings() }
                    })
                Button { state.optionsTool = state.optionsTool == state.tool ? nil : state.tool } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 30) }.buttonStyle(.plain).help("도구 상세 설정")
                Button { state.paletteLocked.toggle() } label: { Image(systemName: state.paletteLocked ? "lock.fill" : "lock.open") }.help("도구창 위치 잠금")
                Button { state.verticalToolbar.toggle(); state.rememberSettings() } label: { Image(systemName: "rectangle.portrait.rotate") }.help("가로·세로 전환")
    }
    private var toolButtons: some View {
        ForEach(MacPDFTool.allCases) { tool in
            MacPDFActionButton(title: "", symbol: tool.symbol, identifier: "pdf.tool.\(tool.rawValue)", accessibilityTitle: tool.title) { state.selectTool(tool) }
                .frame(width: 32, height: 30).background((tool == .connector ? state.connectorEnabled : state.tool == tool) ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6)).help(tool == .connector ? "연결점 표시 켜기·끄기 (다른 도구와 함께 사용)" : tool.title).accessibilityLabel(tool.title)
                .accessibilityValue(tool == .connector ? (state.connectorEnabled ? "켜짐" : "꺼짐") : (state.tool == tool ? "선택됨" : ""))
        }
    }
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(state.tool.title) 설정").font(.headline)
                if ![.view, .select, .image, .eraser, .lasso].contains(state.tool) {
                HStack {
                    ColorPicker("선·문구", selection: colorBinding(\.stroke, field: "stroke"), supportsOpacity: true)
                    ColorPicker("배경", selection: colorBinding(\.fill, field: "fill"), supportsOpacity: true)
                }
                if [.pen, .highlighter, .neon].contains(state.tool) { HStack {
                    ForEach(Array(state.palette.enumerated()), id: \.offset) { index, color in
                        Button { state.selectPalette(color) } label: { Circle().fill(Color(nsColor: color.color)).frame(width: 22, height: 22).overlay(Circle().stroke(state.style.stroke == color ? Color.accentColor : .clear, lineWidth: 2)) }.buttonStyle(.plain).help("선택한 색상을 다시 누르면 색상·두께 편집")
                            .popover(isPresented: Binding(get: { state.editingPaletteIndex == index }, set: { if !$0 { state.editingPaletteIndex = nil } })) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ColorPicker("색상", selection: colorBinding(\.stroke, field: "stroke"), supportsOpacity: true)
                                    Text("두께 \(state.style.width, specifier: "%.1f")")
                                    Slider(value: styleBinding(\.width, field: "width"), in: state.tool == .highlighter ? 18...48 : 0.3...8)
                                    if state.tool == .highlighter { Toggle("끝모양 둥글게", isOn: styleBinding(\.roundCap, field: "roundCap")) }
                                    else { Toggle("필압", isOn: styleBinding(\.pressure, field: "pressure")); Slider(value: styleBinding(\.pressureStrength, field: "pressureStrength"), in: 0...2) }
                                }.padding(14).frame(width: 220)
                            }
                    }
                    Button { state.palette.append(state.style.stroke); state.rememberSettings() } label: { Image(systemName: "plus") }.help("현재 색상을 팔레트에 추가")
                } }
                Text("두께 \(state.style.width, specifier: "%.1f")")
                Slider(value: styleBinding(\.width, field: "width"), in: 0...48)
                }
                if [.pen, .highlighter, .neon].contains(state.tool) {
                    Toggle("필압 사용 (지원 입력 장치)", isOn: styleBinding(\.pressure, field: "pressure"))
                    Text("필압 강도 \(state.style.pressureStrength, specifier: "%.1f")"); Slider(value: styleBinding(\.pressureStrength, field: "pressureStrength"), in: 0...2)
                    Toggle("선 끝 둥글게", isOn: styleBinding(\.roundCap, field: "roundCap"))
                }
                if state.tool == .eraser { Text("지우개 크기 \(Int(state.eraserSize))"); Slider(value: $state.eraserSize, in: 6...100) }
                if state.tool == .shape {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 94))]) {
                        ForEach(MacPDFShape.allCases) { shape in MacPDFActionButton(title: shape.title, identifier: "pdf.add.shape.\(shape.rawValue)") { state.shape = shape; state.addVisibleObject(.shape, shape: shape) }.frame(height: 28) }
                    }
                }
                if state.tool == .text { MacPDFActionButton(title: "텍스트 박스 추가", identifier: "pdf.add.text") { state.addVisibleObject(.text) }.frame(height: 30) }
                if state.tool == .text || state.selected?.kind == .text { textOptions }
                if state.connectorEnabled || state.selected?.kind == .connector { connectorOptions }
                if !state.selection.isEmpty { selectedOptions }
                Divider()
                if state.tool == .image {
                    PhotosPicker("사진 보관함에서 추가", selection: $photo, matching: .images)
                    Button("이미지 파일 가져오기", action: chooseImage)
                    MacPDFPhotoGallery { image in state.insertImage(image) }
                }
                Text("도구창 크기"); Slider(value: $state.toolbarScale, in: 0.7...1.5)
                Toggle("필기 팔레트 항상 열기", isOn: $state.alwaysShowPalette)
                Toggle("상세 팔레트 분리", isOn: $state.paletteDetached)
                Text("상세 팔레트 너비"); Slider(value: $state.paletteSize.width, in: 280...600)
                Text("상세 팔레트 높이"); Slider(value: $state.paletteSize.height, in: 220...650)
                Button("현재 색상·두께·필압 설정 저장") { state.rememberSettings() }
                Text("PDF 원본 내용은 배경으로 유지됩니다. iOS 편집 주석과 추가한 편집 객체를 선택·수정할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxHeight: 500)
        .onDisappear { state.rememberSettings() }
    }
    private var textOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorPicker("텍스트 박스 테두리", selection: Binding(get: { Color(nsColor: state.style.textBorder?.color ?? .clear) }, set: { var style = state.style; style.textBorder = MacPDFRGBA(NSColor($0)); if style.width == 0 { style.width = 1 }; state.setStyle(style, field: "textBorder") }), supportsOpacity: true)
            Picker("글꼴", selection: styleBinding(\.fontName, field: "fontName")) { ForEach(NSFontManager.shared.availableFonts.sorted(), id: \.self) { Text($0).tag($0) } }
            Stepper("글자 크기 \(Int(state.style.fontSize))", value: styleBinding(\.fontSize, field: "fontSize"), in: 6...144)
            HStack { Toggle("굵게", isOn: styleBinding(\.bold, field: "bold")); Toggle("기울임", isOn: styleBinding(\.italic, field: "italic")) }
            HStack { Toggle("밑줄", isOn: styleBinding(\.underline, field: "underline")); Toggle("취소선", isOn: styleBinding(\.strike, field: "strike")) }
            Picker("정렬", selection: styleBinding(\.alignment, field: "alignment")) { Text("왼쪽").tag(0); Text("오른쪽").tag(1); Text("중앙").tag(2) }
            if state.selected?.kind == .text {
                TextField("연결 URL", text: Binding(get: { state.selected?.link ?? "" }, set: { value in state.updateSelected { $0.link = value.isEmpty ? nil : value } }))
                Button("문구 편집") { if let object = state.selected { state.canvas?.beginTextEditing(object) } }
            }
        }
    }
    private var connectorOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("연결선", selection: connectionStyleBinding(\.connectorRoute, field: "connectorRoute")) { Text("직선").tag("straight"); Text("꺾인선").tag("elbow"); Text("곡선").tag("curve") }
            Toggle("화살표", isOn: connectionStyleBinding(\.arrow, field: "arrow")); Toggle("점선", isOn: connectionStyleBinding(\.dashed, field: "dashed"))
            ColorPicker("연결선 색상", selection: Binding(get: { Color(nsColor: state.connectionStyle.stroke.color) }, set: { value in var next = state.connectionStyle; next.stroke = .init(NSColor(value)); state.setConnectionStyle(next, field: "stroke") }), supportsOpacity: true)
            Slider(value: connectionStyleBinding(\.width, field: "width"), in: 0.5...12) { Text("연결선 두께") }
            Text("연결점을 켠 뒤 아이템을 선택하세요. 상하좌우 화살표를 다른 아이템으로 드래그하고, 대상이 강조되면 놓아 연결합니다. 다른 도구를 선택해도 연결점은 켜진 상태로 유지됩니다.").font(.caption)
            if state.selected?.kind == .connector {
                Text("선 중간의 원형 점을 드래그하면 양 끝 연결을 유지하면서 경로를 조정합니다.").font(.caption)
                Button("중간 경로 초기화") { state.updateSelected { $0.connectorOffset = nil } }
                Picker("시작 연결점", selection: Binding(get: { state.selected.map { anchorIndex($0.sourceAnchor) } ?? 0 }, set: { index in state.updateSelected { $0.sourceAnchor = anchor(index) } })) { anchorLabels }
                Picker("끝 연결점", selection: Binding(get: { state.selected.map { anchorIndex($0.targetAnchor) } ?? 1 }, set: { index in state.updateSelected { $0.targetAnchor = anchor(index) } })) { anchorLabels }
                Button("연결 해제", role: .destructive) { state.deleteSelected() }
            }
        }
    }
    private var anchorLabels: some View { Group { Text("왼쪽").tag(0); Text("오른쪽").tag(1); Text("위").tag(2); Text("아래").tag(3) } }
    private func connectionStyleBinding<T>(_ key: WritableKeyPath<MacPDFStyle, T>, field: String) -> Binding<T> {
        Binding(get: { state.connectionStyle[keyPath: key] }, set: { value in var next = state.connectionStyle; next[keyPath: key] = value; state.setConnectionStyle(next, field: field) })
    }
    private func anchor(_ index: Int) -> MacPDFPoint { MacPDFPoint([CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)][index]) }
    private func anchorIndex(_ p: MacPDFPoint) -> Int { p.x == 0 ? 0 : p.x == 1 ? 1 : p.y == 1 ? 2 : 3 }
    private var selectedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("서식 변경은 선택 객체에 즉시 반영됩니다.").font(.caption)
            HStack {
                Button("복사") { state.copySelected() }; Button("복제") { state.duplicateSelected() }
                Button("삭제", role: .destructive) { state.deleteSelected() }
            }
            HStack { Button("최상단") { state.reorderSelected(front: true) }; Button("최하단") { state.reorderSelected(front: false) } }
            Button("90° 회전") { if state.selected?.kind == .image { state.rotateSelectedImageContent() } else { state.updateSelected { if $0.kind != .ink && $0.kind != .connector { $0.rotation += .pi / 2 } } } }
            if state.selected?.kind == .image {
                HStack {
                    Button("좌우 반전") { state.updateSelected { $0.flipped.toggle() } }
                    Button("자르기") { modal = .crop }; Button("교체") { chooseImage(replacing: true) }
                    Button("이미지 편집") { modal = .imageEditor }
                }
                Button("원본 이미지 복원") { state.updateSelected { if let data = $0.originalImageData { $0.imageData = data }; $0.rotation = 0; $0.flipped = false } }
                Button("원본 크기") { state.resetSelectedImageSize() }
            }
        }
    }
    private var footer: some View {
        HStack {
            if state.pageControlPosition == "bottom" {
                Button { state.goToPage(max(0, state.currentPage - 1)) } label: { Image(systemName: "chevron.left") }
                Text("\(state.currentPage + 1) / \(state.pageCount)")
                Button { state.goToPage(min(state.pageCount - 1, state.currentPage + 1)) } label: { Image(systemName: "chevron.right") }
            }
            Spacer(); Text(state.status).font(.caption).foregroundStyle(.secondary)
            Button("−") { state.setZoom(state.zoom - 10) }; Text("\(state.zoom)%"); Button("+") { state.setZoom(state.zoom + 10) }
        }.buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 30)
    }
    private var sidePageControls: some View {
        VStack(spacing: 10) {
            Button { state.goToPage(max(0, state.currentPage - 1)) } label: { Image(systemName: "chevron.up") }
            Text("\(state.currentPage + 1)/\(state.pageCount)").font(.caption)
            Button { state.goToPage(min(state.pageCount - 1, state.currentPage + 1)) } label: { Image(systemName: "chevron.down") }
            Button { state.showPages.toggle() } label: { Image(systemName: "rectangle.grid.1x2") }
        }.buttonStyle(.borderless).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(8)
    }
    private func detachedPalette(in size: CGSize) -> some View {
        let width = max(220, min(state.paletteSize.width, size.width - 20)), height = max(140, min(state.paletteSize.height, size.height - 70))
        let offset = CGSize(width: min(0, max(-max(0, size.width - width - 20), state.paletteOffset.width + paletteDrag.width)), height: max(0, min(max(0, size.height - height - 70), state.paletteOffset.height + paletteDrag.height)))
        return VStack(spacing: 8) {
            HStack { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right"); Text("상세 팔레트").font(.headline); Spacer(); Button { state.paletteDetached = false; state.alwaysShowPalette = false; state.rememberSettings() } label: { Image(systemName: "xmark") } }
                .contentShape(Rectangle()).gesture(DragGesture().updating($paletteDrag) { value, drag, _ in if !state.paletteLocked { drag = value.translation } }.onEnded { value in if !state.paletteLocked { state.paletteOffset.width += value.translation.width; state.paletteOffset.height += value.translation.height; state.rememberSettings() } })
            options
        }.padding(12).frame(width: width, height: height).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 4).offset(offset).padding(10)
    }
    private func clampedToolbarOffset(in size: CGSize) -> CGSize {
        let halfWidth = state.verticalToolbar ? 50.0 : min(300, size.width / 2)
        return CGSize(width: min(max(0, size.width / 2 - halfWidth), max(-max(0, size.width / 2 - halfWidth), state.toolbarOffset.width + toolbarDrag.width)), height: min(0, max(-max(0, size.height - 430), state.toolbarOffset.height + toolbarDrag.height)))
    }
    private func chooseImage() { chooseImage(replacing: false) }
    private func styleBinding<T>(_ key: WritableKeyPath<MacPDFStyle, T>, field: String) -> Binding<T> {
        Binding(get: { state.style[keyPath: key] }, set: { value in var style = state.style; style[keyPath: key] = value; state.setStyle(style, field: field) })
    }
    private func colorBinding(_ key: WritableKeyPath<MacPDFStyle, MacPDFRGBA>, field: String) -> Binding<Color> {
        Binding(get: { Color(nsColor: state.style[keyPath: key].color) }, set: { value in var style = state.style; style[keyPath: key] = MacPDFRGBA(NSColor(value)); state.setStyle(style, field: field) })
    }
    private func handleImageAction(_ action: MacPDFImageAction) {
        state.menuVisible = false
        switch action {
        case .replace: chooseImage(replacing: true)
        case .resetSize: state.resetSelectedImageSize()
        case .rotate: state.rotateSelectedImageContent()
        case .flip: state.updateSelected { $0.flipped.toggle() }
        case .crop: modal = .crop
        case .edit: modal = .imageEditor
        case .systemEdit: modal = .systemImageEditor
        case .front: state.reorderSelected(front: true)
        case .back: state.reorderSelected(front: false)
        }
        if [.resetSize, .rotate, .flip, .front, .back].contains(action) { state.menuVisible = true }
    }
    private func chooseImage(replacing: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = !replacing
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let image = NSImage(contentsOf: url) else { state.error = "이미지 파일을 열지 못했습니다."; continue }
                if replacing, let data = image.tiffRepresentation { state.updateSelected { $0.imageData = data; $0.originalImageData = data } }
                else { state.insertImage(image) }
            }
        }
    }
}

struct MacPDFPagesView: View {
    @ObservedObject var state: MacPDFEditorState
    var body: some View {
        VStack {
            Toggle("즐겨찾기만", isOn: $state.favoritesOnly).padding(8)
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach((0..<state.pageCount).filter { !state.favoritesOnly || state.favorites.contains($0) }, id: \.self) { index in
                        VStack(spacing: 5) {
                            if let page = state.document.page(at: index) {
                                MacPDFThumbnail(page: page)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(state.currentPage == index ? Color.accentColor : .clear, lineWidth: 2))
                                    .onTapGesture { state.goToPage(index) }
                            }
                            HStack {
                                Button { state.goToPage(index); state.toggleFavorite() } label: { Image(systemName: state.favorites.contains(index) ? "star.fill" : "star") }
                                Text("\(index + 1)")
                                Button { state.movePage(from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                                Button { state.movePage(from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == state.pageCount - 1)
                            }.buttonStyle(.borderless)
                        }.padding(.horizontal, 10)
                    }
                }
            }
        }
    }
}

private struct MacPDFThumbnail: View {
    let page: PDFPage
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView() } }
            .frame(width: 130, height: 150)
            .task(id: ObjectIdentifier(page)) { image = page.thumbnail(of: CGSize(width: 150, height: 180), for: .cropBox) }
    }
}

struct MacPDFCropView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: MacPDFEditorState
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var width = 1.0
    @State private var height = 1.0
    @State private var keepOriginal = true
    var body: some View {
        VStack(spacing: 12) {
            Text("이미지 자르기").font(.headline)
            if let data = state.selected?.imageData, let image = NSImage(data: data) {
                GeometryReader { geometry in
                    let ratio = min(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height))
                    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                    Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) { Rectangle().stroke(Color.accentColor, lineWidth: 2).background(Color.accentColor.opacity(0.12)).frame(width: size.width * min(width, 1 - x), height: size.height * min(height, 1 - y)).offset(x: size.width * x, y: size.height * y) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: 280)
            }
            Text("왼쪽 \(Int(x * 100))% · 위 \(Int(y * 100))%")
            Slider(value: $x, in: 0...0.95); Slider(value: $y, in: 0...0.95)
            Text("너비 \(Int(width * 100))% · 높이 \(Int(height * 100))%")
            Slider(value: $width, in: 0.05...1); Slider(value: $height, in: 0.05...1)
            Toggle("원본 이미지 보관", isOn: $keepOriginal)
            HStack { Button("취소") { dismiss() }; Spacer(); Button("자르기 적용") { crop(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20)
    }
    private func crop() {
        guard let data = state.selected?.imageData, let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rect = CGRect(x: Double(cg.width) * x, y: Double(cg.height) * y, width: Double(cg.width) * min(width, 1 - x), height: Double(cg.height) * min(height, 1 - y)).integral
        guard let cropped = cg.cropping(to: rect), let output = NSImage(cgImage: cropped, size: .zero).tiffRepresentation else { state.error = "이미지를 자르지 못했습니다."; return }
        state.updateSelected { $0.imageData = output; if !keepOriginal { $0.originalImageData = output }; $0.bounds.size.height = $0.bounds.width * Double(cropped.height) / Double(cropped.width) }
    }
}

@MainActor
final class MacPDFExportController: NSObject, ObservableObject {
    private var picker: NSSharingServicePicker?
    func download(_ state: MacPDFEditorState) {
        guard let data = state.exportPDF() else { state.error = "공유 PDF를 만들지 못했습니다."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = state.fileName; panel.title = "편집 PDF 다운로드"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); state.status = "PDF 파일 저장됨" } catch { state.error = error.localizedDescription }
        }
    }
    func share(_ state: MacPDFEditorState) {
        guard let data = state.exportPDF(), let view = state.canvas else { state.error = "공유 PDF를 만들지 못했습니다."; return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NF-PDF-Share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = state.fileName.replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent(name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf")
            try data.write(to: url, options: .atomic)
            picker = NSSharingServicePicker(items: [url]); picker?.show(relativeTo: CGRect(x: view.bounds.maxX - 30, y: view.bounds.maxY - 30, width: 1, height: 1), of: view, preferredEdge: .minY)
        } catch { state.error = error.localizedDescription }
    }
}
