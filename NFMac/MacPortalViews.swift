import AppKit
import AuthenticationServices
import SwiftUI

enum MacPortalTitlebarPalette {
    static let backgroundNSColor = NSColor(
        srgbRed: 40.0 / 255.0,
        green: 40.0 / 255.0,
        blue: 40.0 / 255.0,
        alpha: 1
    )
    static let background = Color(nsColor: backgroundNSColor)
    static let foreground = Color(
        nsColor: NSColor(
            srgbRed: 220.0 / 255.0,
            green: 220.0 / 255.0,
            blue: 218.0 / 255.0,
            alpha: 1
        )
    )
    static let separator = Color.white.opacity(0.18)
}

private final class MacPortalTitlebarBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private func applyMacPortalTitlebarBackground(to window: NSWindow) {
    guard let closeButton = window.standardWindowButton(.closeButton),
          let titlebarView = closeButton.superview else { return }

    // macOS draws the traffic-light area in a separate AppKit titlebar view.
    // An opaque child must sit above the system material but below the buttons;
    // changing only the container layer is hidden by NSVisualEffectView.
    let backgroundIdentifier = NSUserInterfaceItemIdentifier("NFMacTitlebarBackground")
    let backgroundView: NSView
    if let existing = titlebarView.subviews.first(where: { $0.identifier == backgroundIdentifier }) {
        backgroundView = existing
    } else {
        let created = MacPortalTitlebarBackgroundView(frame: titlebarView.bounds)
        created.identifier = backgroundIdentifier
        created.autoresizingMask = [.width, .height]
        titlebarView.addSubview(created, positioned: .below, relativeTo: nil)
        backgroundView = created
    }
    backgroundView.frame = titlebarView.bounds
    backgroundView.wantsLayer = true
    backgroundView.layer?.backgroundColor = MacPortalTitlebarPalette.backgroundNSColor.cgColor

    [titlebarView, titlebarView.superview]
        .compactMap { $0 }
        .forEach { view in
            view.wantsLayer = true
            view.layer?.backgroundColor = MacPortalTitlebarPalette.backgroundNSColor.cgColor
        }
}

struct MacPortalRootView: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @StateObject private var authentication = MacAuthenticationModel()
    @State private var showingIntro = true

    var body: some View {
        ZStack {
            if showingIntro {
                MacIntroView()
                    .transition(.opacity)
            } else if authentication.isAuthenticated {
                MacPortalWorkspace(authentication: authentication)
                    .transition(.opacity)
            } else {
                MacLoginView(authentication: authentication)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .background(MacWindowConfigurator())
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.72)) { showingIntro = false }
        }
        .onOpenURL(perform: authentication.handle)
        .alert("안내", isPresented: Binding(
            get: { authentication.message != nil },
            set: { if !$0 { authentication.message = nil } }
        )) {
            Button("확인", role: .cancel) { authentication.message = nil }
        } message: {
            Text(authentication.message ?? "")
        }
    }
}

private struct MacIntroView: View {
    var body: some View {
        ZStack {
            MacLoginPalette.background.ignoresSafeArea()

            VStack(spacing: 18) {
                MacNoteFreeMark()
                    .frame(width: 86, height: 86)

                HStack(spacing: 6) {
                    Text("NF")
                    Text("Portal")
                }
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(MacLoginPalette.introTitle)

                Text("PROJECT OPERATIONS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(MacLoginPalette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MacLoginView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var authentication: MacAuthenticationModel
    @State private var borderRotation = 0.0
    @State private var rawAppleNonce: String?

    private let privacyURL = URL(string: "\(MacPortalConfig.origin)/privacy")!
    private let accountDeletionURL = URL(string: "\(MacPortalConfig.origin)/account-deletion")!

    var body: some View {
        ZStack {
            MacLoginPalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                MacNoteFreeMark()
                    .frame(width: 32, height: 32)

                Text("NF PROJECT OPERATIONS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(MacLoginPalette.muted)
                    .padding(.top, 20)

                Text("NF Project Portal")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(MacLoginPalette.title)
                    .padding(.top, 12)

                Text("Apple, Gmail 또는 Google Workspace 계정으로 가입할 수 있습니다. 계정별 데이터는 분리되며 상호 동의한 회원만 서로의 프로젝트를 볼 수 있습니다.")
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(MacLoginPalette.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white)

                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo")
                        Text("Apple로 로그인")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.black)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    SignInWithAppleButton(.signIn) { request in
                        authentication.beginAppleRequest(request, rawNonce: &rawAppleNonce)
                    } onCompletion: { result in
                        authentication.completeAppleLogin(result, rawNonce: rawAppleNonce)
                        rawAppleNonce = nil
                    }
                    .signInWithAppleButtonStyle(.white)
                    .opacity(0.001)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .disabled(authentication.isProcessing)
                .opacity(authentication.isProcessing ? 0.72 : 1)
                .padding(.top, 32)

                Button(action: authentication.startGoogleLogin) {
                    HStack(spacing: 8) {
                        if authentication.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(authentication.isProcessing ? "로그인 페이지로 이동 중…" : "Google 계정으로 로그인")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(MacLoginPalette.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(authentication.isProcessing)
                .opacity(authentication.isProcessing ? 0.72 : 1)
                .padding(.top, 12)

                Divider()
                    .overlay(MacLoginPalette.border)
                    .padding(.top, 24)

                HStack(spacing: 16) {
                    Link("개인정보처리방침", destination: privacyURL)
                    Link("계정 및 데이터 삭제 요청", destination: accountDeletionURL)
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(MacLoginPalette.muted)
                .padding(.top, 16)
            }
            .padding(32)
            .frame(width: 448)
            .background(MacLoginPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { loginCardBorder(lineWidth: 2) }
            .background {
                loginCardBorder(lineWidth: 3)
                    .blur(radius: 5)
                    .opacity(0.58)
            }
            .shadow(color: .black.opacity(0.35), radius: 25, x: 0, y: 12)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(MacAppVersion.displayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MacLoginPalette.muted)
                .padding(18)
        }
        .onAppear(perform: updateBorderAnimation)
        .onChange(of: accessibilityReduceMotion) { _, _ in updateBorderAnimation() }
    }

    private func loginCardBorder(lineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    colors: [
                        MacLoginPalette.borderLight,
                        MacLoginPalette.borderDeep,
                        MacLoginPalette.borderBlue,
                        .white,
                        MacLoginPalette.borderLight,
                    ],
                    center: .center,
                    angle: .degrees(borderRotation)
                ),
                lineWidth: lineWidth
            )
            .allowsHitTesting(false)
    }

    private func updateBorderAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { borderRotation = 0 }
        guard !accessibilityReduceMotion else { return }
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            borderRotation = 360
        }
    }
}

private enum MacLoginPalette {
    static let background = Color(red: 0.098, green: 0.098, blue: 0.098)
    static let card = Color(red: 0.125, green: 0.125, blue: 0.125)
    static let border = Color(red: 0.20, green: 0.20, blue: 0.20)
    static let title = Color(red: 0.831, green: 0.831, blue: 0.831)
    static let body = Color(red: 0.651, green: 0.651, blue: 0.651)
    static let muted = Color(red: 0.561, green: 0.561, blue: 0.561)
    static let blue = Color(red: 0.184, green: 0.494, blue: 0.847)
    static let borderLight = Color(red: 0.561, green: 0.718, blue: 1.0)
    static let borderDeep = Color(red: 0.122, green: 0.333, blue: 0.820)
    static let borderBlue = Color(red: 0.275, green: 0.404, blue: 0.925)
    static let introTitle = Color(red: 0.930, green: 0.930, blue: 0.930)
    static let mint = Color(red: 0.231, green: 0.965, blue: 0.722)
}

private struct MacNoteFreeMark: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                Capsule()
                    .fill(MacLoginPalette.introTitle)
                    .frame(width: width * 0.08, height: height * 0.72)
                    .position(x: width * 0.20, y: height * 0.50)
                Capsule()
                    .fill(MacLoginPalette.introTitle)
                    .frame(width: width * 0.08, height: height * 0.84)
                    .rotationEffect(.degrees(-30))
                    .position(x: width * 0.42, y: height * 0.50)
                Capsule()
                    .fill(MacLoginPalette.introTitle)
                    .frame(width: width * 0.08, height: height * 0.72)
                    .position(x: width * 0.62, y: height * 0.50)
                Capsule()
                    .fill(MacLoginPalette.introTitle)
                    .frame(width: width * 0.34, height: height * 0.08)
                    .position(x: width * 0.75, y: height * 0.16)
                Capsule()
                    .fill(MacLoginPalette.mint)
                    .frame(width: width * 0.25, height: height * 0.08)
                    .position(x: width * 0.72, y: height * 0.50)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("NoteFree")
    }
}

private struct MacPortalPaneFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [MacPortalPaneSelection: CGRect] = [:]
    static func reduce(value: inout [MacPortalPaneSelection: CGRect], nextValue: () -> [MacPortalPaneSelection: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MacPrimaryPaneWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let nextValue = nextValue()
        if nextValue > 0 {
            value = nextValue
        }
    }
}

private struct MacPortalWorkspace: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @ObservedObject var authentication: MacAuthenticationModel
    @StateObject private var primary = MacPortalBrowserModel(identifier: "primary")
    @StateObject private var secondary = MacPortalBrowserModel(identifier: "secondary")
    @StateObject private var tabTransfer = MacPortalTabTransfer()
    @State private var slideRouter = MacPortalSlideRouter()
    @State private var slideRoutingError: String?
    @State private var isSplit = false
    @State private var activePane: MacPortalPaneSelection = .primary
    @State private var isPDFLibraryPresented = false
    @State private var remotePDFRequest: MacPDFRemoteRequest?
    @State private var remotePDFPane: MacPortalPaneSelection = .primary
    @State private var paneFrames: [MacPortalPaneSelection: CGRect] = [:]
    @State private var primaryPaneWidth: CGFloat = 0
    @State private var titlebarLeadingInset: CGFloat = 0

    var body: some View {
        HSplitView {
            MacPortalPane(
                model: primary,
                onActivate: { activePane = .primary },
                onSidebarNavigate: navigateFromSharedSidebar
            )
            .frame(minWidth: 480)
            .background(MacPortalTabDropRegion(transfer: tabTransfer, pane: primary.identifier))
            .overlay { if tabTransfer.targetPane == primary.identifier { MacPortalTabDropHighlight() } }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MacPrimaryPaneWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
                    .preference(key: MacPortalPaneFramesPreferenceKey.self, value: [.primary: proxy.frame(in: .named("portal.workspace"))])
                }
            }

            if isSplit {
                MacPortalPane(
                    model: secondary,
                    onActivate: { activePane = .secondary },
                    onSidebarNavigate: navigateFromSharedSidebar
                )
                .frame(minWidth: 480)
                .background(MacPortalTabDropRegion(transfer: tabTransfer, pane: secondary.identifier))
                .overlay { if tabTransfer.targetPane == secondary.identifier { MacPortalTabDropHighlight() } }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: MacPortalPaneFramesPreferenceKey.self, value: [.secondary: proxy.frame(in: .named("portal.workspace"))])
                    }
                }
            }
        }
        .coordinateSpace(name: "portal.workspace")
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(MacPortalPaneFramesPreferenceKey.self) { paneFrames = $0 }
        .onPreferenceChange(MacPrimaryPaneWidthPreferenceKey.self) { width in
            if width > 0, abs(primaryPaneWidth - width) > 0.5 {
                primaryPaneWidth = width
            }
        }
        .background {
            MacTitlebarAccessory(onLeadingInsetChange: { inset in
                if abs(titlebarLeadingInset - inset) > 0.5 {
                    titlebarLeadingInset = inset
                }
            }) {
                HStack(spacing: 0) {
                    if isSplit, primaryPaneWidth > titlebarLeadingInset {
                        primaryToolbar
                            .frame(width: primaryPaneWidth - titlebarLeadingInset)
                    } else {
                        primaryToolbar
                            .frame(maxWidth: .infinity)
                    }

                    if isSplit {
                        secondaryToolbar
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            tabTransfer.configure(primary: primary, secondary: secondary)
            configureCallbacks(for: primary)
            configureCallbacks(for: secondary)
            if preferences.slideDestination != .current && !isSplit { toggleSplit() }
            configureSlideRouting()
            refreshPDFLibraryState()
        }
        .onDisappear {
            tabTransfer.cancel(animated: false)
            slideRouter.onFailure = nil
        }
        .onChange(of: preferences.slideDestination) { _, _ in configureSlideRouting() }
        .onChange(of: isSplit) { _, _ in configureSlideRouting() }
        .alert("슬라이드 표시 위치", isPresented: Binding(get: { slideRoutingError != nil }, set: { if !$0 { slideRoutingError = nil } })) {
            Button("확인", role: .cancel) { slideRoutingError = nil }
        } message: { Text(slideRoutingError ?? "") }
        .onChange(of: tabTransfer.completedPane) { _, pane in
            guard let pane else { return }
            activePane = pane == secondary.identifier ? .secondary : .primary
        }
        .onReceive(NotificationCenter.default.publisher(for: MacPDFLocalStorageRepository.didChangeNotification)) { _ in
            refreshPDFLibraryState()
        }
        .overlay(alignment: .trailing) {
            if let request = remotePDFRequest {
                MacResizableRemotePDFPanel(
                    request: request,
                    storesLocally: preferences.pdfLocalStorageEnabled,
                    onClose: closeRemotePDFPreview,
                    paneBounds: isSplit ? paneFrames[remotePDFPane] : nil,
                    containerBounds: isSplit ? (paneFrames[remotePDFPane] ?? .zero) : nil
                )
                // A left-pinned viewer must not animate across the other pane.
                .transition(isSplit ? .opacity : .move(edge: .trailing))
            }
        }
        .sheet(isPresented: $isPDFLibraryPresented, onDismiss: refreshPDFLibraryState) {
            MacPDFLibraryView()
                .frame(minWidth: 820, minHeight: 620)
        }
    }

    private func configureCallbacks(for model: MacPortalBrowserModel) {
        model.onGoogleLogin = authentication.startGoogleLogin
        model.onLogout = authentication.logout
        model.onAuthenticationRequired = authentication.requireLogin
        model.onOpenPDFDocuments = {
            activePane = model.identifier == secondary.identifier ? .secondary : .primary
            isPDFLibraryPresented = true
        }
        model.onPreviewPDFAttachment = { request in
            activePane = model.identifier == secondary.identifier ? .secondary : .primary
            remotePDFPane = preferences.slideDestination.pane(source: activePane, isSplit: isSplit)
            withAnimation(MacPDFSlidePanelLayout.animation) {
                remotePDFRequest = request
            }
        }
    }

    private func closeRemotePDFPreview() {
        withAnimation(MacPDFSlidePanelLayout.animation) {
            remotePDFRequest = nil
        }
        refreshPDFLibraryState()
    }

    private func refreshPDFLibraryState() {
        primary.refreshLocalPDFDocumentCount()
        secondary.refreshLocalPDFDocumentCount()
    }

    private func toggleSplit() {
        if isSplit && slideRouter.hasOpenSlides {
            slideRoutingError = "편집 중인 슬라이드를 먼저 닫은 뒤 좌우 분할을 닫아 주세요. 저장 중인 내용을 보호하기 위한 안내입니다."
            return
        }
        tabTransfer.cancel(animated: false)
        if isSplit {
            activePane = .primary
            isSplit = false
            return
        }

        secondary.cloneState(from: primary, sidebarHidden: true)
        activePane = .primary
        isSplit = true
    }

    private func configureSlideRouting() {
        slideRouter.configure(primary: primary, secondary: secondary,
                              destination: preferences.slideDestination, isSplit: isSplit)
        slideRouter.onFailure = { slideRoutingError = $0 }
    }

    private func selectSlideDestination(_ destination: MacPortalSlideDestination) {
        if destination == preferences.slideDestination && (destination == .current || isSplit) { return }
        guard !slideRouter.hasOpenSlides else {
            slideRoutingError = "열린 슬라이드를 먼저 닫은 뒤 표시 위치를 변경해 주세요."
            return
        }
        if destination != .current, !isSplit { toggleSplit() }
        preferences.slideDestination = destination
        if remotePDFRequest != nil {
            remotePDFPane = destination.pane(source: remotePDFPane, isSplit: isSplit)
        }
        configureSlideRouting()
    }

    private func toggleSharedSidebar() {
        primary.toggleSidebar()
    }

    private func navigateFromSharedSidebar(to url: URL) {
        primary.dismissTransientSidebarAfterSelection()
        secondary.dismissTransientSidebarAfterSelection()
        let target = isSplit && activePane == .secondary ? secondary : primary
        target.navigate(to: url)
    }

    private var primaryToolbar: some View {
        MacPortalToolbar(
            model: primary,
            tabTransfer: tabTransfer,
            preferences: preferences,
            isSplit: isSplit,
            sidebarHidden: primary.sidebarHidden,
            showsSidebarButton: true,
            showsTrailingControls: !isSplit,
            onToggleSidebar: toggleSharedSidebar,
            onToggleSplit: toggleSplit,
            onActivate: { activePane = .primary },
            onSelectSlideDestination: selectSlideDestination
        )
    }

    private var secondaryToolbar: some View {
        MacPortalToolbar(
            model: secondary,
            tabTransfer: tabTransfer,
            preferences: preferences,
            isSplit: true,
            sidebarHidden: primary.sidebarHidden,
            showsSidebarButton: false,
            showsTrailingControls: true,
            onToggleSidebar: toggleSharedSidebar,
            onToggleSplit: toggleSplit,
            onActivate: { activePane = .secondary },
            onSelectSlideDestination: selectSlideDestination
        )
    }
}

struct MacResizableRemotePDFPanel: View {
    let request: MacPDFRemoteRequest
    let storesLocally: Bool
    let onClose: () -> Void
    var paneBounds: CGRect?
    var editorDirectory: URL?
    var containerBounds: CGRect?

    @State private var preferredWidth: CGFloat?
    @State private var resizeStartWidth: CGFloat?
    @State private var isResizing = false
    @State private var isPaneExpanded = false
    @StateObject private var presentation = MacPDFViewerWindowState()

    var body: some View {
        GeometryReader { geometry in
            let container = containerBounds ?? CGRect(origin: .zero, size: geometry.size)
            let panelWidth = MacPDFSlidePanelLayout.width(
                preferredWidth: preferredWidth,
                for: container.width
            )
            let expanded = isPaneExpanded && paneBounds != nil
            let localBounds = MacPDFSlidePanelLayout.frame(preferredWidth: preferredWidth, availableSize: container.size,
                                                         expandedPane: expanded ? (containerBounds == nil ? paneBounds : CGRect(origin: .zero, size: container.size)) : nil)
            let bounds = localBounds.offsetBy(dx: container.minX, dy: container.minY)

            ZStack(alignment: .leading) {
                MacPDFMovableViewer(presentation: presentation, content: MacRemotePDFPreviewView(
                    request: request,
                    storesLocally: storesLocally,
                    isContainerResizing: isResizing,
                    onClose: onClose,
                    isFullscreen: presentation.isFullscreen,
                    onToggleFullscreen: {
                        isResizing = false; resizeStartWidth = nil
                        if presentation.isFullscreen { presentation.exit() }
                        else { presentation.enterEmbeddedFullscreen(title: request.url.lastPathComponent) }
                    },
                    isPaneExpanded: expanded,
                    onTogglePaneExpanded: paneBounds == nil ? nil : {
                        isResizing = false; resizeStartWidth = nil
                        withAnimation(.easeInOut(duration: 0.22)) { isPaneExpanded.toggle() }
                    },
                    editorDirectory: editorDirectory
                ).ignoresSafeArea(.container, edges: .top))
                .id(request.id)

                if !presentation.isFullscreen && !expanded { MacPDFPanelResizeHandle()
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let startWidth = resizeStartWidth ?? panelWidth
                                if resizeStartWidth == nil {
                                    resizeStartWidth = startWidth
                                    isResizing = true
                                }
                                let nextWidth = MacPDFSlidePanelLayout.width(
                                    preferredWidth: startWidth - value.translation.width,
                                    for: container.width
                                )
                                if abs((preferredWidth ?? panelWidth) - nextWidth) >= 0.5 {
                                    preferredWidth = nextWidth
                                }
                            }
                            .onEnded { _ in
                                resizeStartWidth = nil
                                isResizing = false
                            }
                    ) }
            }
            .frame(width: bounds.width, height: bounds.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipped()
            .overlay(alignment: .leading) {
                if !expanded {
                    Rectangle()
                        .fill(Color.primary.opacity(isResizing ? 0.38 : 0.22))
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
            .position(x: bounds.midX, y: bounds.midY)
        }
        // Measure from the window top, like MacPortalPane. The 32pt inset
        // above reserves the title-bar tabs once, without a second safe-area gap.
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: paneBounds == nil) { _, unavailable in
            if unavailable { isPaneExpanded = false }
        }
    }
}

private struct MacPDFPanelResizeHandle: View {
    @State private var isHovering = false

    var body: some View {
        Color.clear
        .contentShape(Rectangle())
        .frame(width: MacPDFSlidePanelLayout.resizeHandleWidth)
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
            }
        }
        .accessibilityLabel("PDF 보기 너비 조절")
        .accessibilityHint("가로로 드래그하여 PDF 보기 너비를 변경합니다.")
    }
}

private struct MacPortalPane: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @ObservedObject var model: MacPortalBrowserModel
    let onActivate: () -> Void
    let onSidebarNavigate: (URL) -> Void

    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var findMatchFound: Bool?
    @State private var findRequestSequence = 0
    @FocusState private var isFindFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The interactive toolbar is hosted by a native title-bar accessory.
            // Keep its exact layout height here so the web view never shifts.
            model.themeBackground
                .frame(height: 32)
                .allowsHitTesting(false)
            // Breadcrumbs live inside WKWebView so web slides/fullscreen calendars
            // can cover them without resizing either the breadcrumb or document.
            portalWebView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(model.themeBackground)
        .overlay(alignment: .topTrailing) {
            if isFindPresented {
                MacPortalFindBar(
                    query: $findQuery,
                    matchFound: findMatchFound,
                    isFieldFocused: $isFindFieldFocused,
                    onPrevious: { performFind(backwards: true) },
                    onNext: { performFind(backwards: false) },
                    onClose: closeFind
                )
                .padding(.top, 40)
                .padding(.trailing, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: findQuery) { _, query in
            guard isFindPresented else { return }
            if query.isEmpty {
                findRequestSequence += 1
                findMatchFound = nil
                model.clearTextFind()
            } else {
                performFind(backwards: false)
            }
        }
        // NSSplitView applies the title-bar safe area to each arranged pane.
        // Ignore it per pane so both toolbars stay beside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var portalWebView: some View {
        MacPortalWebView(
            model: model,
            preferences: preferences,
            onFocus: onActivate,
            onSidebarNavigate: onSidebarNavigate,
            onFindCommand: presentFind,
            onFindNextCommand: { backwards in
                if isFindPresented, !findQuery.isEmpty {
                    performFind(backwards: backwards)
                } else {
                    presentFind()
                }
            }
        )
    }

    private func presentFind() {
        onActivate()
        withAnimation(.easeOut(duration: 0.16)) {
            isFindPresented = true
        }
        Task { @MainActor in
            isFindFieldFocused = true
        }
    }

    private func performFind(backwards: Bool) {
        guard !findQuery.isEmpty else {
            isFindFieldFocused = true
            return
        }
        findRequestSequence += 1
        let requestSequence = findRequestSequence
        model.findText(findQuery, backwards: backwards) { found in
            guard requestSequence == findRequestSequence else { return }
            findMatchFound = found
        }
    }

    private func closeFind() {
        findRequestSequence += 1
        model.clearTextFind()
        findMatchFound = nil
        withAnimation(.easeIn(duration: 0.12)) {
            isFindPresented = false
        }
    }
}

private struct MacPortalFindBar: View {
    @Binding var query: String
    let matchFound: Bool?
    let isFieldFocused: FocusState<Bool>.Binding
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("문구 검색", text: $query)
                .textFieldStyle(.plain)
                .focused(isFieldFocused)
                .onSubmit(onNext)
                .frame(width: 210)

            if let matchFound {
                Text(matchFound ? "찾음" : "일치 없음")
                    .font(.caption)
                    .foregroundStyle(matchFound ? Color.secondary : Color.red)
                    .frame(minWidth: 36)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("이전 결과")
            .disabled(query.isEmpty)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .help("다음 결과")
            .disabled(query.isEmpty)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help("검색 닫기")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("현재 페이지 문구 검색")
    }
}

struct MacPortalToolbar: View {
    @ObservedObject var model: MacPortalBrowserModel
    @ObservedObject var tabTransfer: MacPortalTabTransfer
    @ObservedObject var preferences: MacPortalPreferences
    let isSplit: Bool
    let sidebarHidden: Bool
    let showsSidebarButton: Bool
    let showsTrailingControls: Bool
    let onToggleSidebar: () -> Void
    let onToggleSplit: () -> Void
    let onActivate: () -> Void
    var onSelectSlideDestination: (MacPortalSlideDestination) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsSidebarButton {
                Button {
                    onActivate()
                    onToggleSidebar()
                } label: {
                    Image(systemName: sidebarHidden ? "line.3.horizontal" : "sidebar.left")
                        .frame(width: 20, height: 20)
                        .offset(y: -2)
                }
                .help(sidebarHidden ? "전체 메뉴 열기" : "전체 메뉴 닫기")
                .onHover { model.setToolbarSidebarHover($0) }
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1, height: 20)
            }
            Button {
                onActivate()
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 20, height: 20, alignment: .center)
                    .offset(y: -2)
            }
                .disabled(!model.canGoBack).help("뒤로 가기")
            Button {
                onActivate()
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 20, height: 20, alignment: .center)
                    .offset(y: -2)
            }
                .disabled(!model.canGoForward).help("앞으로 가기")
            Button {
                onActivate()
                model.reloadCurrentPage()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20, alignment: .center)
                    .offset(y: -2)
            }
            .help("현재 페이지 새로고침")
            Button {
                onActivate()
                model.goHome()
            } label: {
                Image(systemName: "house")
                    .frame(width: 20, height: 20, alignment: .center)
                    .offset(y: -2)
            }
            .help("홈")
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1, height: 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(model.pages) { page in
                        MacPortalTabButton(
                            page: page,
                            pane: model.identifier,
                            tabTransfer: tabTransfer,
                            allowsTabMove: isSplit,
                            isSelected: page.id == model.activePageID,
                            selectedBackground: model.themeBackground,
                            selectedForeground: model.themeForeground,
                            canClose: model.pages.count > 1,
                            onSelect: {
                                onActivate()
                                model.open(page)
                            },
                            onClose: { model.close(page) }
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: model.pages.map(\.id))
            }
            .background(MacPortalTabDropRegion(transfer: tabTransfer, pane: model.identifier, strip: true))
            .overlay(alignment: .leading) {
                if tabTransfer.targetPane == model.identifier {
                    RoundedRectangle(cornerRadius: 2).fill(MacPortalTitlebarPalette.foreground.opacity(0.5)).frame(width: 3, height: 24)
                        .padding(.leading, 2).allowsHitTesting(false).transition(.opacity)
                }
            }
            Spacer(minLength: 4)
            if showsTrailingControls {
                Menu {
                    Text("슬라이드 팝업 표시 위치")
                    ForEach(MacPortalSlideDestination.allCases) { destination in
                        Button {
                            onSelectSlideDestination(destination)
                        } label: {
                            if preferences.slideDestination == destination {
                                Label(destination.title, systemImage: "checkmark")
                            } else { Text(destination.title) }
                        }
                        .accessibilityIdentifier("portal.slideDestination.\(destination.rawValue)")
                    }
                    Divider()
                    Button(isSplit ? "좌우 분할 닫기" : "좌우 분할 열기") { onToggleSplit() }
                    Text("고정 위치를 선택하면 반대쪽에서 연 문서도 해당 영역에 표시됩니다.")
                } label: {
                    Image(systemName: isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .frame(width: 20, height: 20, alignment: .center)
                        .offset(y: -2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("슬라이드 표시 위치 및 좌우 분할 설정")
                .accessibilityIdentifier("portal.slideDestination")
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1, height: 20)
                Menu {
                    ForEach(Array(stride(from: 80, through: 200, by: 5)), id: \.self) { percent in
                        Button(percent == preferences.zoomPercent ? "✓ \(percent)%" : "\(percent)%") {
                            preferences.zoomPercent = percent
                        }
                    }
                } label: {
                    Label("\(preferences.zoomPercent)%", systemImage: "textformat.size")
                        .frame(height: 20, alignment: .center)
                        .offset(y: -2)
                        .foregroundStyle(MacPortalTitlebarPalette.foreground)
                }
                .tint(MacPortalTitlebarPalette.foreground)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(MacPortalTitlebarPalette.foreground)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: 32, alignment: .center)
        .background(MacPortalTitlebarPalette.background)
    }

    private var separatorColor: Color {
        MacPortalTitlebarPalette.separator
    }
}

private struct MacPortalTabButton: View {
    let page: MacPortalPage
    let pane: String
    @ObservedObject var tabTransfer: MacPortalTabTransfer
    let allowsTabMove: Bool
    let isSelected: Bool
    let selectedBackground: Color
    let selectedForeground: Color
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            MacPortalTabPressLabel(page: page, pane: pane, transfer: tabTransfer, enabled: allowsTabMove,
                                   foreground: NSColor(isSelected ? selectedForeground : MacPortalTitlebarPalette.foreground), onSelect: onSelect)
                .fixedSize(horizontal: true, vertical: false).frame(height: 28)
                .offset(x: showsCloseButton ? 0 : 11.5)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .help(canClose ? "탭 닫기" : "마지막 탭은 닫을 수 없습니다")
            .disabled(!canClose)
            .opacity(showsCloseButton ? 1 : 0)
            .scaleEffect(showsCloseButton ? 1 : 0.85)
            .accessibilityHidden(!showsCloseButton)
            .allowsHitTesting(showsCloseButton)
            .accessibilityIdentifier("portal.tab.close.\(pane).\(page.id)")
        }
        .offset(y: -2)
        .padding(.trailing, 3)
        .frame(height: 32, alignment: .center)
        .foregroundStyle(isSelected ? selectedForeground : MacPortalTitlebarPalette.foreground)
        .background(alignment: .bottom) {
            if isSelected {
                ZStack(alignment: .bottom) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 7,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 7,
                        style: .continuous
                    )
                    .fill(selectedBackground)
                    .frame(height: 32)

                    Rectangle()
                        .fill(selectedBackground)
                        .frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(tabTransfer.pageID == page.id && tabTransfer.sourcePane == pane ? 0.3 : 1)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .onHover { hovering in
            guard tabTransfer.pageID == nil else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }

    private var showsCloseButton: Bool {
        isHovering && canClose
    }
}

struct MacPortalTabDropHighlight: View {
    var body: some View {
        ZStack(alignment: .top) {
            MacPortalTitlebarPalette.background.opacity(0.10)
            RoundedRectangle(cornerRadius: 8).stroke(MacPortalTitlebarPalette.foreground.opacity(0.35), lineWidth: 2).padding(3)
            Text("놓으면 이 화면으로 탭 이동").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MacPortalTitlebarPalette.foreground)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(MacPortalTitlebarPalette.background.opacity(0.85), in: Capsule()).padding(.top, 44)
        }.allowsHitTesting(false).transition(.opacity)
    }
}

struct MacPortalSettingsView: View {
    @EnvironmentObject private var preferences: MacPortalPreferences

    var body: some View {
        TabView {
            Form {
                LabeledContent("앱") { Text("NF Project Portal") }
                LabeledContent("버전") { Text(MacAppVersion.displayText) }
                LabeledContent("플랫폼") { Text("네이티브 macOS · AppKit WebKit") }
                Toggle("PDF 파일 로컬 저장", isOn: $preferences.pdfLocalStorageEnabled)
                Text("웹의 설정 > 기본 정보와 같은 값입니다. PDF를 기기에 저장해 문서 목록에서 다시 열 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .tabItem { Label("기본", systemImage: "gearshape") }

            Form {
                Picker("화면 테마", selection: $preferences.appearance) {
                    ForEach(MacPortalAppearance.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("화면 배율")
                    Slider(
                        value: Binding(
                            get: { Double(preferences.zoomPercent) },
                            set: { preferences.zoomPercent = Int($0) }
                        ),
                        in: 80...200,
                        step: 5
                    )
                    Text("\(preferences.zoomPercent)%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Text("Safari와 같은 WebKit 페이지 배율로 글자·아이콘·콘텐츠가 함께 확대됩니다. 설정은 앱 종료 후에도 유지됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .tabItem { Label("화면", systemImage: "display") }
        }
        .frame(width: 560, height: 310)
    }
}

private struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? WindowView)?.configure() }

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = MacPortalTitlebarPalette.backgroundNSColor
            window.styleMask.insert([.resizable, .fullSizeContentView])
            window.minSize = NSSize(width: 980, height: 680)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.isMovableByWindowBackground = false
            applyMacPortalTitlebarBackground(to: window)
        }
    }
}

private struct MacTitlebarAccessory: NSViewRepresentable {
    let rootView: AnyView
    let onLeadingInsetChange: (CGFloat) -> Void

    init<Content: View>(
        onLeadingInsetChange: @escaping (CGFloat) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onLeadingInsetChange = onLeadingInsetChange
        rootView = AnyView(content())
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: rootView, onLeadingInsetChange: onLeadingInsetChange)
    }

    func makeNSView(context: Context) -> WindowAnchorView {
        let view = WindowAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAnchorView, context: Context) {
        context.coordinator.update(
            rootView: rootView,
            onLeadingInsetChange: onLeadingInsetChange
        )
        context.coordinator.install(in: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowAnchorView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private let hostingController: NSHostingController<AnyView>
        private let accessoryController = NSTitlebarAccessoryViewController()
        private weak var installedWindow: NSWindow?
        private var resizeObserver: NSObjectProtocol?
        private var onLeadingInsetChange: (CGFloat) -> Void
        private var reportedLeadingInset: CGFloat = -1

        init(rootView: AnyView, onLeadingInsetChange: @escaping (CGFloat) -> Void) {
            hostingController = NSHostingController(rootView: rootView)
            self.onLeadingInsetChange = onLeadingInsetChange
            hostingController.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 32)
            hostingController.view.autoresizingMask = [.width]
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.backgroundColor = MacPortalTitlebarPalette.backgroundNSColor.cgColor
            accessoryController.view = hostingController.view
            accessoryController.layoutAttribute = .left
        }

        func update(
            rootView: AnyView,
            onLeadingInsetChange: @escaping (CGFloat) -> Void
        ) {
            hostingController.rootView = rootView
            self.onLeadingInsetChange = onLeadingInsetChange
            resizeToWindow()
        }

        func install(in window: NSWindow?) {
            guard let window else { return }
            applyMacPortalTitlebarBackground(to: window)
            if installedWindow !== window {
                uninstall()
                installedWindow = window
                window.addTitlebarAccessoryViewController(accessoryController)
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.resizeToWindow()
                }
            }
            resizeToWindow()
        }

        func uninstall() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
            guard let installedWindow,
                  let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessoryController })
            else {
                self.installedWindow = nil
                return
            }
            installedWindow.removeTitlebarAccessoryViewController(at: index)
            self.installedWindow = nil
        }

        private func resizeToWindow() {
            guard let window = installedWindow else { return }
            applyMacPortalTitlebarBackground(to: window)
            let leadingInset: CGFloat
            if let zoomButton = window.standardWindowButton(.zoomButton) {
                leadingInset = zoomButton.convert(zoomButton.bounds, to: nil).maxX + 8
            } else {
                leadingInset = 0
            }
            hostingController.view.setFrameSize(
                NSSize(width: max(320, window.frame.width - leadingInset), height: 32)
            )

            if abs(reportedLeadingInset - leadingInset) > 0.5 {
                reportedLeadingInset = leadingInset
                let callback = onLeadingInsetChange
                DispatchQueue.main.async {
                    callback(leadingInset)
                }
            }
        }
    }

    final class WindowAnchorView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
