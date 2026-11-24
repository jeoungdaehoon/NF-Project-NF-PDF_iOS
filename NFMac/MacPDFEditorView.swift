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
    var initialFreeNote: String?
    var registerDetailExit: ((@escaping () async -> Bool) -> Void)?
    init(document: PDFDocument, identifier: String, fileName: String, sourceURL: URL? = nil, initialFreeNote: String? = nil, cookieHeader: String? = nil, sourceData: Data? = nil, isContainerResizing: Bool = false, exportOnSave: Bool = false, isFullscreen: Bool = false, onToggleFullscreen: (() -> Void)? = nil, onExitPaneExpansion: (() -> Void)? = nil, isPaneExpanded: Bool = false, onTogglePaneExpanded: (() -> Void)? = nil, editorDirectory: URL? = nil, detailWorkspace: DetailPDFWorkspace? = nil, registerDetailExit: ((@escaping () async -> Bool) -> Void)? = nil, onSave: ((Data) async throws -> Void)? = nil) {
        let directory = detailWorkspace?.directory.appendingPathComponent("editor", isDirectory: true) ?? editorDirectory
        let editor = MacPDFEditorState(document: document, identifier: identifier, fileName: fileName, sourceURL: sourceURL, cookieHeader: cookieHeader, sourceData: sourceData, directory: directory, detailWorkspace: detailWorkspace)
        editor.onSave = onSave; editor.exportOnSave = exportOnSave; _state = StateObject(wrappedValue: editor); self.isContainerResizing = isContainerResizing
        self.isFullscreen = isFullscreen; self.onToggleFullscreen = onToggleFullscreen
        self.onExitPaneExpansion = onExitPaneExpansion
        self.isPaneExpanded = isPaneExpanded; self.onTogglePaneExpanded = onTogglePaneExpanded
        self.initialFreeNote = initialFreeNote
        self.registerDetailExit = registerDetailExit
    }
    var body: some View { MacPDFEditorView(state: state, isContainerResizing: isContainerResizing, isFullscreen: isFullscreen, onToggleFullscreen: onToggleFullscreen, onExitPaneExpansion: onExitPaneExpansion, isPaneExpanded: isPaneExpanded, onTogglePaneExpanded: onTogglePaneExpanded, initialFreeNote: initialFreeNote, registerDetailExit: registerDetailExit) }
}

struct MacPDFEditorView: View {
    @StateObject private var freeNotes = PDFNoteWorkspaceState(origin: URL(string: MacPortalConfig.origin)!)
    @AppStorage(MacPortalPreferences.appearanceKey) private var appearance = MacPortalAppearance.system
    @ObservedObject var state: MacPDFEditorState
    var isContainerResizing = false
    var isFullscreen = false
    var onToggleFullscreen: (() -> Void)?
    var onExitPaneExpansion: (() -> Void)?
    var isPaneExpanded = false
    var onTogglePaneExpanded: (() -> Void)?
    var initialFreeNote: String?
    var registerDetailExit: ((@escaping () async -> Bool) -> Void)?
    var liveSurface: MacPDFLiveSurface?
    @StateObject private var sharing = MacPDFExportController()
    @State private var photo: PhotosPickerItem?
    @State private var modal: Modal?
    @State private var showReset = false
    @State private var connectorSettingsExpanded = false
    @GestureState private var paletteDrag = CGSize.zero
    private var detachedPaletteVisible: Bool { (state.alwaysShowPalette || state.paletteDetached) && !state.presentation && !freeNotes.documentTool }
    enum Modal: String, Identifiable { case crop, board, imageEditor, systemImageEditor; var id: String { rawValue } }
    var body: some View {
        VStack(spacing: 0) {
            if !state.presentation && liveSurface == nil { header; Divider() }
            if state.keepsPreviousDetailPDF && !state.presentation {
                Text(DetailPDFWorkspace.retainedEditsMessage)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            if liveSurface == nil { MacPDFFindBar(find: state.find) }
            HStack(spacing: 0) {
                if state.showPages && !state.presentation && liveSurface == nil { MacPDFPagesView(state: state).frame(width: 190); Divider() }
                PDFNoteWorkspace(state: freeNotes, enabled: !state.presentation) {
                    GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        MacPDFCanvas(state: state, isContainerResizing: isContainerResizing, onExitPaneExpansion: onExitPaneExpansion, freeNotes: freeNotes, liveSurface: liveSurface)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !state.presentation {
                            MacPDFMovableToolbar(state: state, viewport: geometry.size) { handle, size in
                                floatingToolbar(handle: handle, availableSize: size)
                            }
                        } else {
                            Button("프레젠테이션 종료") { state.presentation = false }
                                .padding(8).background(Color(nsColor: .windowBackgroundColor), in: Capsule()).padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if let liveSurface { MacPDFLiveControls(surface: liveSurface, state: state).padding(8) }
                    }
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
                        if !state.presentation && state.pageControlPosition != "bottom" && liveSurface == nil { sidePageControls }
                    }
                    .overlayPreferenceValue(MacPDFToolbarBounds.self) { anchor in
                        if (freeNotes.showsDocumentOptions || state.optionsTool != nil) && !detachedPaletteVisible && !state.presentation, let anchor {
                            GeometryReader { overlay in
                                toolOptionsPanel(near: overlay[anchor], in: overlay.size)
                            }
                        }
                    }
                    }
                }
                .task(id: state.identifier) {
                    freeNotes.activate(state.document, source: state.sourceURL, localID: registerDetailExit == nil ? state.identifier : nil,
                                       note: initialFreeNote, popupLayoutDirectory: state.notePopupLayoutDirectory)
                }
            }
            if !state.presentation && liveSurface == nil { footer }
        }
        .onAppear {
            registerDetailExit? {
                guard await freeNotes.flush() else { return false }
                return state.persistBeforeReturningToDetail()
            }
        }
        .onDisappear { Task { _ = await freeNotes.flush() } }
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
        .onChange(of: state.tool) { _, tool in
            if tool != .view { liveSurface?.editsSource = false }
        }
        .onChange(of: freeNotes.documentTool) { _, active in
            if active { liveSurface?.editsSource = false }
        }
        .onChange(of: state.optionsTool) { _, tool in
            if tool == nil && !detachedPaletteVisible && state.editingPaletteIndex != nil { state.editingPaletteIndex = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pdf.editor")
        .preferredColorScheme(appearance.colorScheme)
    }
    private var header: some View {
        HStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button { state.showPages.toggle() } label: { Image(systemName: "sidebar.left") }.help("페이지 목록")
                MacPDFActionButton(title: "", symbol: "arrow.uturn.backward", identifier: "pdf.undo", accessibilityTitle: "실행 취소") { state.undo() }
                    .frame(width: 22, height: 22).disabled(!state.canUndo).help("실행 취소 ⌘Z")
                MacPDFActionButton(title: "", symbol: "arrow.uturn.forward", identifier: "pdf.redo", accessibilityTitle: "다시 실행") { state.redo() }
                    .frame(width: 22, height: 22).disabled(!state.canRedo).help("다시 실행 ⇧⌘Z")
                Menu("페이지") {
                    Button("빈 페이지 추가", systemImage: "doc.badge.plus") { state.pageOperation("add") }
                    Button("현재 페이지 복제", systemImage: "doc.on.doc") { state.pageOperation("duplicate") }
                    Divider()
                    Button(state.favorites.contains(state.currentPage) ? "즐겨찾기 해제" : "즐겨찾기 추가", systemImage: "star") { state.toggleFavorite() }
                    Button(role: .destructive) { state.pageOperation("delete") } label: { Label("현재 페이지 삭제", systemImage: "trash") }
                        .disabled(state.pageCount <= 1)
                }
                Menu("보기") {
                    Toggle("가로 보기", isOn: $state.horizontal)
                    Toggle("페이지 단위 보기", isOn: $state.paged)
                    Toggle("두 페이지 보기", isOn: $state.twoPages)
                    Divider()
                    Button("화면에 맞춤", systemImage: "viewfinder") { state.canvas?.autoScales = true }
                    Button(isFullscreen ? "전체화면 종료" : "전체화면 보기", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullscreen() }
                    Button("프레젠테이션", systemImage: "rectangle.on.rectangle") { state.presentation = true }
                    Divider()
                    Picker("페이지 이동 버튼 위치", selection: $state.pageControlPosition) { Text("아래").tag("bottom"); Text("왼쪽").tag("left"); Text("오른쪽").tag("right") }
                    .pickerStyle(.menu)
                }
                Button("저장") { Task { await state.save() } }.disabled(state.isSaving)
                    .help(state.sourceURL == nil ? "이 Mac의 문서와 편집 정보를 저장합니다. 서버 첨부 파일은 변경하지 않습니다." : "편집 내용을 포함한 PDF로 기존 서버 첨부 파일을 교체하고 저장 결과를 확인합니다.")
                MacPDFActionButton(title: "PDF 다운로드", identifier: "pdf.download") { sharing.download(state) }.frame(width: 90, height: 22)
                Button { sharing.share(state) } label: { Image(systemName: "square.and.arrow.up") }.help("편집 PDF 외부 공유")
                Menu("더보기") {
                    Button(isFullscreen ? "전체화면 종료" : "전체화면 보기", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullscreen() }
                    Button("문서 연결 보드", systemImage: "point.3.connected.trianglepath.dotted") { modal = .board }
                    Section("Google Drive") {
                        Button("저장", systemImage: "icloud.and.arrow.up") { Task { await state.syncToGoogleDrive() } }
                        Button("연결 해제", systemImage: "link.badge.minus") { state.unlinkGoogleDrive() }
                    }
                    Menu("편집 도구", systemImage: "slider.horizontal.3") {
                        Toggle("도구창 세로 배치", isOn: $state.verticalToolbar)
                        Button("편집 도구 설정 초기화", systemImage: "arrow.counterclockwise") { showReset = true }
                    }
                }
            }.buttonStyle(.borderless).padding(10)
        }
        .frame(maxWidth: .infinity)
        HStack(spacing: 12) {
            if state.tool == .neon {
                MacPDFNeonTypePicker(selection: Binding(get: { state.neonType }, set: { state.selectNeonType($0) }))
                    .frame(width: 150, height: 22)
                    .help("네온 타입 선택: 라인은 자유롭게, 박스와 화살표는 시작점에서 끝점까지 드래그합니다.")
                MacPDFActionButton(title: "네온 전체 삭제", identifier: "pdf.clearNeon", accessibilityTitle: "네온 전체 삭제") { if state.tool == .neon { state.clearNeon() } }
                    .frame(width: 100, height: 22)
                    .help("이 PDF 뷰어의 임시 네온을 모두 지웁니다. 일반 펜·텍스트·도형·연결선은 유지합니다.")
            }
            MacPDFFindButton(find: state.find)
            if let onTogglePaneExpanded, !isFullscreen {
                // Keep these actions pinned right, even in a narrow pane.
                MacPDFActionButton(title: "", symbol: isPaneExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", identifier: "pdf.expandPane", accessibilityTitle: isPaneExpanded ? "분할 영역 전체보기 종료" : "분할 영역 전체보기", action: onTogglePaneExpanded)
                    .frame(width: 22, height: 22)
                    .help(isPaneExpanded ? "분할 영역 전체보기 종료" : "분할 영역 전체보기")
            }
        }
        .padding(.horizontal, 10)
        }
        .onChange(of: state.horizontal) { _, _ in state.configureView() }
        .onChange(of: state.paged) { _, _ in state.configureView() }
        .onChange(of: state.twoPages) { _, _ in state.configureView() }
    }
    private func toggleFullscreen() {
        if let onToggleFullscreen { onToggleFullscreen() }
        else { state.canvas?.window?.toggleFullScreen(nil) }
    }
    private func floatingToolbar(handle: MacPDFToolbarDragHandle, availableSize: CGSize) -> some View {
        MacPDFToolPalette(vertical: state.verticalToolbar, availableSize: availableSize) {
            toolbarUtilities(handle: handle)
            toolButtons
        }
    }

    // Keep the settings in the PDF canvas so AppKit does not have to negotiate
    // the size of a separate popover window while SwiftUI lays out the toolbar.
    private func toolOptionsPanel(near toolbar: CGRect, in viewport: CGSize) -> some View {
        let placement = MacPDFToolbarLayout.optionsPanel(near: toolbar, in: viewport, vertical: state.verticalToolbar,
                                                        preferredHeight: freeNotes.documentTool ? 520 : 384)
        let rect = placement.frame
        return options(maxHeight: max(1, rect.height - 24), onClose: closeToolOptions)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(MacPDFPanelSurface(radius: 12))
            .shadow(radius: 5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pdf.toolOptions.panel")
            .onExitCommand(perform: closeToolOptions)
            .frame(width: rect.width, height: rect.height, alignment: placement.alignment)
            .offset(x: rect.minX, y: rect.minY)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func closeToolOptions() {
        state.optionsTool = nil
        freeNotes.showsDocumentOptions = false
    }
    @ViewBuilder private func toolbarUtilities(handle: MacPDFToolbarDragHandle) -> some View {
                handle.frame(width: 32, height: 30)
                MacPDFActionButton(title: "", symbol: "slider.horizontal.3", identifier: "pdf.toolOptions.toggle", accessibilityTitle: "도구 상세 설정") {
                    if freeNotes.documentTool { freeNotes.showsDocumentOptions.toggle() }
                    else { state.optionsTool = state.optionsTool == state.tool ? nil : state.tool }
                }.frame(width: 32, height: 30)
                Menu {
                    ForEach(MacPDFTool.allCases) { tool in
                        Button { selectTool(tool) } label: {
                            Label(tool.title, systemImage: toolSelected(tool) ? "checkmark" : tool.symbol)
                        }
                    }
                    Button(action: selectDocumentTool) {
                        Label("문서 도구", systemImage: freeNotes.documentTool ? "checkmark" : "doc.text")
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 30)
                .help("도구 지원")
                .accessibilityLabel("도구 지원")
                Button { state.paletteLocked.toggle() } label: { Image(systemName: state.paletteLocked ? "lock.fill" : "lock.open") }.help("도구창 위치 잠금")
                Button { state.verticalToolbar.toggle(); state.rememberSettings() } label: { Image(systemName: "rectangle.portrait.rotate") }.help("가로·세로 전환")
    }
    @ViewBuilder private var toolButtons: some View {
        ForEach(MacPDFTool.allCases) { tool in
            MacPDFToolPaletteButton(toolID: tool.rawValue, title: tool.title, symbol: tool.symbol,
                                    isSelected: toolSelected(tool),
                                    tooltip: tool == .connector ? "연결점 표시 켜기·끄기 (다른 도구와 함께 사용)" : nil,
                                    onOffValue: tool == .connector) {
                selectTool(tool)
            }
        }
        MacPDFToolPaletteButton(toolID: "document", title: "문서 도구", symbol: "doc.text",
                                isSelected: freeNotes.documentTool, action: selectDocumentTool)
    }
    private func toolSelected(_ tool: MacPDFTool) -> Bool {
        tool == .connector ? state.connectorEnabled : state.tool == tool && !freeNotes.documentTool
    }
    private func selectTool(_ tool: MacPDFTool) {
        liveSurface?.editsSource = false
        freeNotes.documentTool = false
        state.selectTool(tool)
    }
    private func selectDocumentTool() {
        if freeNotes.documentTool {
            freeNotes.showsDocumentOptions.toggle()
            return
        }
        state.selectTool(.view)
        state.optionsTool = nil
        state.menuVisible = false
        freeNotes.documentTool = true
        freeNotes.showsDocumentOptions = true
    }
    private func options(maxHeight: CGFloat = 360, onClose: (() -> Void)? = nil) -> some View {
        MacPDFCompactOptions(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 10) {
                MacPDFToolOptionsHeader(title: freeNotes.documentTool ? "문서 설정" : "\(state.tool.title) 설정",
                                        symbol: freeNotes.documentTool ? "doc.text" : state.tool.symbol, onClose: onClose)
                if freeNotes.documentTool {
                    PDFDocumentToolOptions(style: Binding(get: { freeNotes.configuredMarkerStyle }, set: { freeNotes.configuredMarkerStyle = $0 }),
                                              recent: freeNotes.recentDocumentIcons,
                                              onChooseIcon: freeNotes.chooseDocumentIcon)
                } else {
                    toolOptions
                    if state.tool == .text || state.selected?.kind == .text { textOptions }
                    if state.connectorEnabled || state.selected?.kind == .connector {
                        DisclosureGroup("연결선 설정", isExpanded: $connectorSettingsExpanded) {
                            connectorOptions.padding(.top, 8)
                        }
                    }
                    if !state.selection.isEmpty {
                        DisclosureGroup("선택 객체") { selectedOptions.padding(.top, 8) }
                    }
                }
                Divider()
                DisclosureGroup("도구창 설정") {
                    VStack(alignment: .leading, spacing: 8) {
                        panelSlider("도구창 크기", value: $state.toolbarScale, in: 0.7...1.5, display: "\(Int(state.toolbarScale * 100))%")
                        Toggle("세로 배치", isOn: $state.verticalToolbar)
                        Toggle("위치 잠금", isOn: $state.paletteLocked)
                        Toggle("필기 팔레트 항상 열기", isOn: $state.alwaysShowPalette)
                        Toggle("상세 팔레트 분리", isOn: $state.paletteDetached)
                        DisclosureGroup("팔레트 크기") {
                            panelSlider("너비", value: Binding(get: { Double(state.paletteSize.width) }, set: { state.paletteSize.width = $0 }),
                                        in: 280...600, display: "\(Int(state.paletteSize.width)) pt")
                            panelSlider("높이", value: Binding(get: { Double(state.paletteSize.height) }, set: { state.paletteSize.height = $0 }),
                                        in: 220...650, display: "\(Int(state.paletteSize.height)) pt")
                        }
                        Button("현재 색상·두께·필압 설정 저장") { state.rememberSettings() }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(1)
            .onChange(of: state.selected?.kind) { _, kind in
                if kind == .connector { connectorSettingsExpanded = true }
            }
        }
        .onDisappear { state.rememberSettings() }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch state.tool {
        case .view, .select, .lasso:
            EmptyView()
        case .image:
            Button("이미지 파일 가져오기", systemImage: "folder", action: chooseImage)
            PhotosPicker(selection: $photo, matching: .images) {
                Label("사진 보관함에서 추가", systemImage: "photo.on.rectangle")
            }
            DisclosureGroup("최근 사진") {
                MacPDFPhotoGallery { image in state.insertImage(image) }.padding(.top, 8)
            }
        case .eraser:
            toolPreview
            panelSlider("지우개 크기", value: $state.eraserSize, in: 6...100, display: "\(Int(state.eraserSize)) pt")
        default:
            toolPreview
            if state.tool == .neon {
                MacPDFNeonTypePicker(selection: Binding(get: { state.neonType }, set: { state.selectNeonType($0, keepsOptionsOpen: true) }))
                    .frame(height: 23)
                Button("네온 전체 삭제", systemImage: "eraser") { state.clearNeon() }
            }
            HStack(spacing: 14) {
                ColorPicker(state.tool == .text ? "문자" : "선", selection: colorBinding(\.stroke, field: "stroke"), supportsOpacity: true)
                ColorPicker("배경", selection: colorBinding(\.fill, field: "fill"), supportsOpacity: true)
            }
            if [.pen, .highlighter, .neon].contains(state.tool) { inkPalette }
            if state.tool != .text {
                panelSlider("두께", value: styleBinding(\.width, field: "width"), in: 0...48, display: String(format: "%.1f pt", state.style.width))
            }
            if [.pen, .highlighter, .neon].contains(state.tool) {
                DisclosureGroup("필압·선 끝") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("필압 사용 (지원 입력 장치)", isOn: styleBinding(\.pressure, field: "pressure"))
                        panelSlider("필압 강도", value: styleBinding(\.pressureStrength, field: "pressureStrength"), in: 0...2,
                                    display: String(format: "%.1f", state.style.pressureStrength))
                            .disabled(!state.style.pressure)
                        Toggle("선 끝 둥글게", isOn: styleBinding(\.roundCap, field: "roundCap"))
                    }.padding(.top, 8)
                }
            }
            if state.tool == .shape {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 94))]) {
                    ForEach(MacPDFShape.allCases) { shape in
                        MacPDFActionButton(title: shape.title, identifier: "pdf.add.shape.\(shape.rawValue)") {
                            state.shape = shape
                            state.addVisibleObject(.shape, shape: shape)
                        }
                        .frame(height: 28)
                        .background(state.shape == shape ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    private var inkPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(state.palette.enumerated()), id: \.offset) { index, color in
                            Button { state.selectPalette(color) } label: {
                                Circle().fill(Color(nsColor: color.color)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(state.style.stroke == color ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: state.style.stroke == color ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pdf.palette.color.\(index)")
                            .accessibilityLabel("팔레트 색상 \(index + 1)")
                            .help("선택한 색상을 다시 누르면 색상·두께 편집")
                        }
                    }
                    .padding(1)
                }
                Button { state.palette.append(state.style.stroke); state.rememberSettings() } label: { Image(systemName: "plus") }
                    .help("현재 색상을 팔레트에 추가")
            }
            if state.editingPaletteIndex != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("색상·두께 편집", systemImage: "paintpalette").font(.headline)
                        Spacer()
                        Button { state.editingPaletteIndex = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("색상 편집 닫기")
                    }
                    ColorPicker("색상", selection: colorBinding(\.stroke, field: "stroke"), supportsOpacity: true)
                    panelSlider("두께", value: styleBinding(\.width, field: "width"),
                                in: state.tool == .highlighter ? 18...48 : 0.3...8,
                                display: String(format: "%.1f pt", state.style.width))
                    DisclosureGroup(state.tool == .highlighter ? "선 끝" : "필압") {
                        if state.tool == .highlighter {
                            Toggle("끝모양 둥글게", isOn: styleBinding(\.roundCap, field: "roundCap"))
                        } else {
                            Toggle("필압", isOn: styleBinding(\.pressure, field: "pressure"))
                            panelSlider("필압 강도", value: styleBinding(\.pressureStrength, field: "pressureStrength"),
                                        in: 0...2, display: String(format: "%.1f", state.style.pressureStrength))
                                .disabled(!state.style.pressure)
                        }
                    }
                }
                .padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var toolPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            switch state.tool {
            case .eraser:
                Circle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: min(40, state.eraserSize), height: min(40, state.eraserSize))
            case .shape:
                let shape = Path(MacPDFObjectRenderer.shapePath(state.shape, bounds: CGRect(x: 0, y: 0, width: 52, height: 30)))
                shape.fill(Color(nsColor: state.style.fill.color))
                    .overlay(shape.stroke(Color(nsColor: state.style.stroke.color), lineWidth: min(8, state.style.width)))
                    .frame(width: 52, height: 30)
            case .text:
                MacPDFTextPreview(style: state.style)
            case .neon:
                neonPreview
            default:
                RoundedRectangle(cornerRadius: state.style.roundCap ? 20 : 0)
                    .fill(Color(nsColor: state.style.stroke.color))
                    .frame(height: min(22, max(1, state.style.width)))
                    .padding(.horizontal, 36)
            }
        }
        .frame(height: 54)
        .accessibilityHidden(true)
    }

    private var neonPreview: some View {
        let color = Color(nsColor: state.style.stroke.color)
        return Canvas { context, size in
            let width = min(12, max(1, state.style.width))
            let left = size.width * 0.2
            let right = size.width * 0.8
            let center = size.height / 2
            var path = Path()
            switch state.neonType {
            case .line:
                path.move(to: CGPoint(x: left, y: center + 8))
                path.addLine(to: CGPoint(x: right, y: center - 8))
            case .box:
                path.addRoundedRect(in: CGRect(x: left, y: 12, width: right - left, height: size.height - 24),
                                    cornerSize: CGSize(width: 4, height: 4))
            case .arrow:
                path.move(to: CGPoint(x: left, y: center))
                path.addLine(to: CGPoint(x: right, y: center))
                path.move(to: CGPoint(x: right - 10, y: center - 7))
                path.addLine(to: CGPoint(x: right, y: center))
                path.addLine(to: CGPoint(x: right - 10, y: center + 7))
            }
            context.addFilter(.shadow(color: color, radius: 4))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: state.style.roundCap ? .round : .butt))
        }
    }

    private func panelSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, display: String) -> some View {
        MacPDFOptionSlider(title: title, value: value, range: range, display: display)
    }

    private var textOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("글꼴", selection: styleBinding(\.fontName, field: "fontName")) { ForEach(NSFontManager.shared.availableFonts.sorted(), id: \.self) { Text($0).tag($0) } }
            Stepper("글자 크기 \(Int(state.style.fontSize))", value: styleBinding(\.fontSize, field: "fontSize"), in: 6...144)
            HStack { Toggle("굵게", isOn: styleBinding(\.bold, field: "bold")); Toggle("기울임", isOn: styleBinding(\.italic, field: "italic")) }
            HStack { Toggle("밑줄", isOn: styleBinding(\.underline, field: "underline")); Toggle("취소선", isOn: styleBinding(\.strike, field: "strike")) }
            Picker("정렬", selection: styleBinding(\.alignment, field: "alignment")) { Text("왼쪽").tag(0); Text("오른쪽").tag(1); Text("중앙").tag(2) }
            MacPDFActionButton(title: "텍스트 박스 추가", identifier: "pdf.add.text") { state.addVisibleObject(.text) }
                .frame(height: 30)
            DisclosureGroup("텍스트 박스 테두리") {
                VStack(alignment: .leading, spacing: 8) {
                    ColorPicker("색상", selection: Binding(
                        get: { Color(nsColor: state.style.textBorder?.color ?? .clear) },
                        set: {
                            var style = state.style
                            style.textBorder = MacPDFRGBA(NSColor($0))
                            if style.width == 0 { style.width = 0.5 }
                            state.setStyle(style, field: "textBorder")
                        }
                    ), supportsOpacity: true)
                    MacPDFTextBoxControls(state: state)
                }.padding(.top, 8)
            }
            if state.selected?.kind == .text {
                TextField("연결 URL", text: Binding(get: { state.selected?.link ?? "" }, set: { value in state.updateSelected { $0.link = value.isEmpty ? nil : value } }))
                Button("문구 편집") { if let object = state.selected { state.canvas?.beginTextEditing(object) } }
            }
        }
    }
    private var connectorOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                context.withCGContext { graphics in
                    let style = state.connectionStyle
                    graphics.setStrokeColor(style.stroke.color.cgColor)
                    graphics.setFillColor(style.stroke.color.cgColor)
                    graphics.setLineWidth(style.width)
                    MacPDFObjectRenderer.drawConnection(
                        from: CGPoint(x: 24, y: size.height * 0.25),
                        to: CGPoint(x: size.width - 24, y: size.height * 0.75),
                        style: style, context: graphics
                    )
                }
            }
            .frame(height: 48)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            Picker("연결선", selection: connectionStyleBinding(\.connectorRoute, field: "connectorRoute")) {
                Text("직선").tag("straight"); Text("꺾인선").tag("elbow"); Text("곡선").tag("curve")
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("화살표", isOn: connectionStyleBinding(\.arrow, field: "arrow"))
                Toggle("점선", isOn: connectionStyleBinding(\.dashed, field: "dashed"))
                Spacer()
                ColorPicker("색상", selection: Binding(get: { Color(nsColor: state.connectionStyle.stroke.color) }, set: { value in var next = state.connectionStyle; next.stroke = .init(NSColor(value)); state.setConnectionStyle(next, field: "stroke") }), supportsOpacity: true)
            }
            panelSlider("두께", value: connectionStyleBinding(\.width, field: "width"), in: 0.5...12,
                        display: String(format: "%.1f pt", state.connectionStyle.width))
            Text("연결점을 켠 뒤 아이템을 선택하세요. 상하좌우 화살표를 다른 아이템으로 드래그하고, 대상이 강조되면 놓아 연결합니다. 다른 도구를 선택해도 연결점은 켜진 상태로 유지됩니다.").font(.caption)
            if state.selected?.kind == .connector {
                DisclosureGroup("연결점과 경로") {
                    VStack(alignment: .leading, spacing: 6) {
                Text("선 중간의 원형 점을 드래그하면 양 끝 연결을 유지하면서 경로를 조정합니다.").font(.caption)
                Button("중간 경로 초기화") { state.updateSelected { $0.connectorOffset = nil } }
                Picker("시작 연결점", selection: Binding(get: { state.selected.map { anchorIndex($0.sourceAnchor) } ?? 0 }, set: { index in state.updateSelected { $0.sourceAnchor = anchor(index) } })) { anchorLabels }
                Picker("끝 연결점", selection: Binding(get: { state.selected.map { anchorIndex($0.targetAnchor) } ?? 1 }, set: { index in state.updateSelected { $0.targetAnchor = anchor(index) } })) { anchorLabels }
                        Button("연결 해제", role: .destructive) { state.deleteSelected() }
                    }.padding(.top, 8)
                }
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
        VStack(spacing: 12) {
            Button { state.goToPage(max(0, state.currentPage - 1)) } label: { Image(systemName: "chevron.up") }
            Text("\(state.currentPage + 1)/\(state.pageCount)").font(.caption)
            Button { state.goToPage(min(state.pageCount - 1, state.currentPage + 1)) } label: { Image(systemName: "chevron.down") }
            Button { state.showPages.toggle() } label: { Image(systemName: "rectangle.grid.1x2") }
        }.buttonStyle(.borderless).padding(10).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).padding(8)
    }
    private func detachedPalette(in size: CGSize) -> some View {
        let width = max(220, min(state.paletteSize.width, size.width - 20)), height = max(140, min(state.paletteSize.height, size.height - 70))
        let offset = CGSize(width: min(0, max(-max(0, size.width - width - 20), state.paletteOffset.width + paletteDrag.width)), height: max(0, min(max(0, size.height - height - 70), state.paletteOffset.height + paletteDrag.height)))
        return VStack(spacing: 8) {
            HStack { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right"); Text("상세 팔레트").font(.headline); Spacer(); Button { state.paletteDetached = false; state.alwaysShowPalette = false; state.rememberSettings() } label: { Image(systemName: "xmark") } }
                .contentShape(Rectangle()).gesture(DragGesture().updating($paletteDrag) { value, drag, _ in if !state.paletteLocked { drag = value.translation } }.onEnded { value in if !state.paletteLocked { state.paletteOffset.width += value.translation.width; state.paletteOffset.height += value.translation.height; state.rememberSettings() } })
            options(maxHeight: max(1, height - 54))
        }.padding(12).frame(width: width, height: height, alignment: .top)
            .background(MacPDFPanelSurface(radius: 12)).shadow(radius: 4).offset(offset).padding(10)
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

private struct MacPDFOptionsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Coalesce measurements for the next run-loop turn and keep the scroll
/// viewport stable when the measured size rounds to the same point.
@MainActor
private final class MacPDFOptionsSizing: ObservableObject {
    @Published private(set) var height: CGFloat = 360
    private var pendingHeight: CGFloat?
    private var updateScheduled = false

    func measure(_ value: CGFloat) {
        guard value.isFinite, value > 0 else { return }
        pendingHeight = min(360, max(1, value.rounded(.up)))
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let next = self.pendingHeight else { return }
            self.pendingHeight = nil
            guard self.height != next else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.height = next }
        }
    }
}

/// Short palettes hug their contents; longer palettes remain fully scrollable.
struct MacPDFCompactOptions<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @StateObject private var sizing = MacPDFOptionsSizing()
    var body: some View {
        ScrollView {
            content().fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in Color.clear.preference(key: MacPDFOptionsHeight.self, value: geometry.size.height) })
        }
        .frame(height: min(maxHeight, sizing.height))
        .onPreferenceChange(MacPDFOptionsHeight.self) { sizing.measure($0) }
    }
}

struct MacPDFToolOptionsHeader: View {
    let title: String
    let symbol: String
    let onClose: (() -> Void)?

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(.headline)
            if let onClose {
                Spacer(minLength: 4)
                MacPDFActionButton(title: "", symbol: "xmark", identifier: "pdf.toolOptions.close",
                                   accessibilityTitle: "도구 설정 닫기", action: onClose)
                    .frame(width: 22, height: 22)
            }
        }
        Divider()
    }
}

struct MacPDFOptionSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize()
            Slider(value: value, in: range).accessibilityLabel(title)
            Text(display).monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }
        .font(.caption)
    }
}

struct MacPDFPagesView: View {
    @ObservedObject var state: MacPDFEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("페이지 목록", systemImage: "sidebar.left")
                .font(.headline)
            Picker("페이지 목록", selection: $state.favoritesOnly) {
                Text("전체").tag(false)
                Text("즐겨찾기").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if state.favoritesOnly && state.favorites.isEmpty {
                Text("즐겨찾기 페이지가 없습니다.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach((0..<state.pageCount).filter { !state.favoritesOnly || state.favorites.contains($0) }, id: \.self) { index in
                            if let page = state.document.page(at: index) { row(page, index: index) }
                        }
                    }
                }
            }
            Divider()
            Text("\(state.currentPage + 1)페이지 선택")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("위로", systemImage: "arrow.up") { state.movePage(from: state.currentPage, to: state.currentPage - 1) }
                    .disabled(state.currentPage <= 0 || !visibleCurrentPage)
                Button("아래로", systemImage: "arrow.down") { state.movePage(from: state.currentPage, to: state.currentPage + 1) }
                    .disabled(state.currentPage >= state.pageCount - 1 || !visibleCurrentPage)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var visibleCurrentPage: Bool {
        !state.favoritesOnly || state.favorites.contains(state.currentPage)
    }

    private func row(_ page: PDFPage, index: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                state.goToPage(index)
            } label: {
                HStack(spacing: 8) {
                    MacPDFThumbnail(page: page)
                        .id(ObjectIdentifier(page))
                        .frame(width: 40, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1)페이지").font(.caption)
                        if state.currentPage == index {
                            Text("현재").font(.caption2).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                state.goToPage(index)
                state.toggleFavorite()
            } label: {
                Image(systemName: state.favorites.contains(index) ? "star.fill" : "star")
                    .foregroundStyle(state.favorites.contains(index) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.favorites.contains(index) ? "즐겨찾기 해제" : "즐겨찾기 추가")
        }
        .padding(5)
        .background(state.currentPage == index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
            cropSlider("너비", value: $width, in: 0.05...1)
            cropSlider("높이", value: $height, in: 0.05...1)
            DisclosureGroup("자르기 위치") {
                cropSlider("왼쪽", value: $x, in: 0...0.95)
                cropSlider("위", value: $y, in: 0...0.95)
            }
            Toggle("원본 이미지 보관", isOn: $keepOriginal)
            HStack { Button("취소") { dismiss() }; Spacer(); Button("자르기 적용") { crop(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
    }

    private func cropSlider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 36, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(label)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
        }
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
