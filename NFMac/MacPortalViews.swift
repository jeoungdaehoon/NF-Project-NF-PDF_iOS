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
            try? await Task.sleep(for: .milliseconds(850))
            withAnimation(.easeInOut(duration: 0.3)) { showingIntro = false }
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
        ZStack(alignment: .bottomTrailing) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Color.blue.opacity(0.16))
                        .frame(width: 92, height: 92)
                    Text("NF")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                }
                Text("NF Project Portal")
                    .font(.system(size: 30, weight: .bold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(MacAppVersion.displayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(18)
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

                Text("Gmail 또는 Google Workspace 계정으로 가입할 수 있습니다. 계정별 데이터는 분리되며 상호 동의한 회원만 서로의 프로젝트를 볼 수 있습니다.")
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
}

private struct MacNoteFreeMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 32
            var mark = Path()
            mark.move(to: CGPoint(x: 5 * scale, y: 27 * scale))
            mark.addLine(to: CGPoint(x: 5 * scale, y: 5 * scale))
            mark.addLine(to: CGPoint(x: 25 * scale, y: 27 * scale))
            mark.addLine(to: CGPoint(x: 25 * scale, y: 5 * scale))
            context.stroke(
                mark,
                with: .linearGradient(
                    Gradient(colors: [.white, Color(white: 0.74), .white]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                ),
                style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .square, lineJoin: .miter)
            )

            let accentRect = CGRect(x: 25.2 * scale, y: 25.2 * scale, width: 2.2 * scale, height: 2.2 * scale)
            context.fill(Path(ellipseIn: accentRect), with: .color(MacLoginPalette.borderBlue))
        }
        .accessibilityLabel("NoteFree")
    }
}

private struct MacPortalWorkspace: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @ObservedObject var authentication: MacAuthenticationModel
    @StateObject private var primary = MacPortalBrowserModel(identifier: "primary")
    @StateObject private var secondary = MacPortalBrowserModel(identifier: "secondary")
    @State private var isSplit = false

    var body: some View {
        Group {
            if isSplit {
                HSplitView {
                    MacPortalPane(
                        model: primary,
                        reservesTrafficLights: true,
                        isSplit: true,
                        onToggleSplit: toggleSplit
                    )
                    .frame(minWidth: 480)
                    MacPortalPane(
                        model: secondary,
                        reservesTrafficLights: false,
                        isSplit: true,
                        onToggleSplit: toggleSplit
                    )
                    .frame(minWidth: 480)
                }
            } else {
                MacPortalPane(
                    model: primary,
                    reservesTrafficLights: true,
                    isSplit: false,
                    onToggleSplit: toggleSplit
                )
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            configureCallbacks(for: primary)
            configureCallbacks(for: secondary)
        }
    }

    private func configureCallbacks(for model: MacPortalBrowserModel) {
        model.onGoogleLogin = authentication.startGoogleLogin
        model.onLogout = authentication.logout
    }

    private func toggleSplit() {
        if !isSplit { secondary.cloneState(from: primary) }
        withAnimation(.easeInOut(duration: 0.18)) { isSplit.toggle() }
    }
}

private struct MacPortalPane: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @ObservedObject var model: MacPortalBrowserModel
    let reservesTrafficLights: Bool
    let isSplit: Bool
    let onToggleSplit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MacPortalToolbar(
                model: model,
                preferences: preferences,
                reservesTrafficLights: reservesTrafficLights,
                isSplit: isSplit,
                onToggleSplit: onToggleSplit
            )
            if model.sidebarHidden {
                MacBreadcrumbBar(model: model)
            }
            MacPortalWebView(model: model, preferences: preferences)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(model.themeBackground)
    }
}

private struct MacPortalToolbar: View {
    @ObservedObject var model: MacPortalBrowserModel
    @ObservedObject var preferences: MacPortalPreferences
    let reservesTrafficLights: Bool
    let isSplit: Bool
    let onToggleSplit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.toggleSidebar) {
                Image(systemName: model.sidebarHidden ? "line.3.horizontal" : "sidebar.left")
                    .frame(width: 20, height: 20)
            }
            .help(model.sidebarHidden ? "전체 메뉴 열기" : "전체 메뉴 닫기")
            Divider().frame(height: 20)
            Button(action: model.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack).help("뒤로 가기")
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help("앞으로 가기")
            Divider().frame(height: 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(model.pages) { page in
                        MacPortalTabButton(
                            page: page,
                            isSelected: page.id == model.activePageID,
                            canClose: model.pages.count > 1,
                            onSelect: { model.open(page) },
                            onClose: { model.close(page) }
                        )
                    }
                }
            }
            Spacer(minLength: 4)
            Button(action: onToggleSplit) {
                Image(systemName: isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(isSplit ? "2분할 닫기" : "현재 페이지를 좌우로 2분할")
            Divider().frame(height: 20)
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
        .overlay(alignment: .bottom) { Divider() }
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2) }
                    Button(item.title) { model.open(item) }
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
        .overlay(alignment: .bottom) { Divider() }
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
        .frame(width: 560, height: 250)
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
