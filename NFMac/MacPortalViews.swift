import AppKit
import AuthenticationServices
import SwiftUI

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

private enum MacPortalPaneSelection {
    case primary
    case secondary
}

private struct MacPortalWorkspace: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @ObservedObject var authentication: MacAuthenticationModel
    @StateObject private var primary = MacPortalBrowserModel(identifier: "primary")
    @StateObject private var secondary = MacPortalBrowserModel(identifier: "secondary")
    @State private var isSplit = false
    @State private var activePane: MacPortalPaneSelection = .primary
    @State private var isPDFLibraryPresented = false
    @State private var remotePDFRequest: MacPDFRemoteRequest?

    var body: some View {
        HSplitView {
            MacPortalPane(
                model: primary,
                reservesTrafficLights: true,
                isSplit: isSplit,
                sharedSidebarHidden: primary.sidebarHidden,
                onToggleSidebar: toggleSharedSidebar,
                onToggleSplit: toggleSplit,
                onActivate: { activePane = .primary },
                onSidebarNavigate: navigateFromSharedSidebar
            )
            .frame(minWidth: 480)

            if isSplit {
                MacPortalPane(
                    model: secondary,
                    reservesTrafficLights: false,
                    isSplit: true,
                    sharedSidebarHidden: primary.sidebarHidden,
                    onToggleSidebar: toggleSharedSidebar,
                    onToggleSplit: toggleSplit,
                    onActivate: { activePane = .secondary },
                    onSidebarNavigate: navigateFromSharedSidebar
                )
                .frame(minWidth: 480)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            configureCallbacks(for: primary)
            configureCallbacks(for: secondary)
            refreshPDFLibraryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacPDFLocalStorageRepository.didChangeNotification)) { _ in
            refreshPDFLibraryState()
        }
        .sheet(isPresented: $isPDFLibraryPresented, onDismiss: refreshPDFLibraryState) {
            MacPDFLibraryView()
                .frame(minWidth: 820, minHeight: 620)
        }
        .sheet(item: $remotePDFRequest, onDismiss: refreshPDFLibraryState) { request in
            MacRemotePDFPreviewView(
                request: request,
                storesLocally: preferences.pdfLocalStorageEnabled
            )
            .frame(minWidth: 900, minHeight: 700)
        }
    }

    private func configureCallbacks(for model: MacPortalBrowserModel) {
        model.onGoogleLogin = authentication.startGoogleLogin
        model.onLogout = authentication.logout
        model.onAuthenticationRequired = authentication.requireLogin
        model.onOpenPDFDocuments = { isPDFLibraryPresented = true }
        model.onPreviewPDFAttachment = { remotePDFRequest = $0 }
    }

    private func refreshPDFLibraryState() {
        primary.refreshLocalPDFDocumentCount()
        secondary.refreshLocalPDFDocumentCount()
    }

    private func toggleSplit() {
        if isSplit {
            activePane = .primary
            isSplit = false
            return
        }

        secondary.cloneState(from: primary, sidebarHidden: true)
        activePane = .primary
        isSplit = true
    }

    private func toggleSharedSidebar() {
        primary.toggleSidebar()
    }

    private func navigateFromSharedSidebar(to url: URL) {
        let target = isSplit && activePane == .secondary ? secondary : primary
        target.navigate(to: url)
    }
}

private struct MacPortalPane: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @ObservedObject var model: MacPortalBrowserModel
    let reservesTrafficLights: Bool
    let isSplit: Bool
    let sharedSidebarHidden: Bool
    let onToggleSidebar: () -> Void
    let onToggleSplit: () -> Void
    let onActivate: () -> Void
    let onSidebarNavigate: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            MacPortalToolbar(
                model: model,
                preferences: preferences,
                reservesTrafficLights: reservesTrafficLights,
                isSplit: isSplit,
                sidebarHidden: sharedSidebarHidden,
                onToggleSidebar: onToggleSidebar,
                onToggleSplit: onToggleSplit,
                onActivate: onActivate
            )
            if model.sidebarHidden {
                GeometryReader { geometry in
                    let sidebarInset = model.isSidebarHoverVisible ? model.sidebarHoverWidth : 0

                    ZStack(alignment: .topLeading) {
                        portalWebView
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        MacBreadcrumbBar(model: model, onActivate: onActivate)
                            .frame(width: max(geometry.size.width - sidebarInset, 0))
                            .offset(x: sidebarInset)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                }
            } else {
                portalWebView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(model.themeBackground)
        // NSSplitView applies the title-bar safe area to each arranged pane.
        // Ignore it per pane so both toolbars stay beside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var portalWebView: some View {
        MacPortalWebView(
            model: model,
            preferences: preferences,
            onFocus: onActivate,
            onSidebarNavigate: onSidebarNavigate
        )
    }
}

private struct MacPortalToolbar: View {
    @ObservedObject var model: MacPortalBrowserModel
    @ObservedObject var preferences: MacPortalPreferences
    let reservesTrafficLights: Bool
    let isSplit: Bool
    let sidebarHidden: Bool
    let onToggleSidebar: () -> Void
    let onToggleSplit: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onActivate()
                onToggleSidebar()
            } label: {
                Image(systemName: sidebarHidden ? "line.3.horizontal" : "sidebar.left")
                    .frame(width: 20, height: 20)
            }
            .help(sidebarHidden ? "전체 메뉴 열기" : "전체 메뉴 닫기")
            .onHover { model.setToolbarSidebarHover($0) }
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1, height: 20)
            Button {
                onActivate()
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
                .disabled(!model.canGoBack).help("뒤로 가기")
            Button {
                onActivate()
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
                .disabled(!model.canGoForward).help("앞으로 가기")
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1, height: 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(model.pages) { page in
                        MacPortalTabButton(
                            page: page,
                            isSelected: page.id == model.activePageID,
                            canClose: model.pages.count > 1,
                            onSelect: {
                                onActivate()
                                model.open(page)
                            },
                            onClose: { model.close(page) }
                        )
                    }
                }
            }
            Spacer(minLength: 4)
            Button {
                onActivate()
                onToggleSplit()
            } label: {
                Image(systemName: isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(isSplit ? "2분할 닫기" : "현재 페이지를 좌우로 2분할")
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
                    // borderless Menu가 상위 foregroundStyle 대신 시스템 색을 선택하는
                    // 경우에도 웹에서 전달된 현재 테마의 문구색을 유지합니다.
                    .foregroundStyle(model.themeForeground)
            }
            .tint(model.themeForeground)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(model.themeForeground)
        .padding(.leading, reservesTrafficLights ? 86 : 10)
        .padding(.trailing, 10)
        .frame(height: 43)
        .background(model.themeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
        }
    }

    private var separatorColor: Color {
        model.themeForeground.opacity(0.16)
    }
}

private struct MacPortalTabButton: View {
    let page: MacPortalPage
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                Text(page.title)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.vertical, 5)
            }
            .help(page.url.absoluteString)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .help(canClose ? "탭 닫기" : "마지막 탭은 닫을 수 없습니다")
            .disabled(!canClose)
            .opacity(isHovering && canClose ? 1 : 0)
            .accessibilityHidden(!canClose)
        }
        .padding(.trailing, 3)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct MacBreadcrumbBar: View {
    @ObservedObject var model: MacPortalBrowserModel
    let onActivate: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2) }
                    Button(item.title) {
                        onActivate()
                        model.open(item)
                    }
                        .buttonStyle(.plain)
                        .disabled(item.url == nil)
                }
            }
            .padding(.horizontal, 14)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(model.themeForeground)
        .frame(height: 34)
        .background(model.themeBackground)
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
            window.styleMask.insert([.resizable, .fullSizeContentView])
            window.minSize = NSSize(width: 980, height: 680)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.isMovableByWindowBackground = false
        }
    }
}
