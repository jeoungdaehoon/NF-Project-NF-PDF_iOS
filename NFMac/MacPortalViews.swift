import AppKit
import AuthenticationServices
import SwiftUI

struct MacPortalRootView: View {
    @EnvironmentObject private var preferences: MacPortalPreferences
    @StateObject private var authentication = MacAuthenticationModel()
    @State private var showingIntro = true
    @State private var rawAppleNonce: String?

    var body: some View {
        ZStack {
            if showingIntro {
                MacIntroView()
                    .transition(.opacity)
            } else if authentication.isAuthenticated {
                MacPortalWorkspace(authentication: authentication)
                    .transition(.opacity)
            } else {
                MacLoginView(
                    authentication: authentication,
                    rawAppleNonce: $rawAppleNonce
                )
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
    @ObservedObject var authentication: MacAuthenticationModel
    @Binding var rawAppleNonce: String?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NF PROJECT OPERATIONS")
                            .font(.caption.weight(.bold))
                            .tracking(2.5)
                            .foregroundStyle(.secondary)
                        Text("NF Project Portal")
                            .font(.system(size: 34, weight: .bold))
                    }
                    Spacer()
                    Text("NF").font(.system(size: 28, weight: .semibold, design: .rounded))
                }
                Text("Apple 또는 Google 계정으로 로그인할 수 있습니다. 로그인 세션은 macOS 전용 보안 쿠키 저장소에 유지됩니다.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SignInWithAppleButton(.signIn) { request in
                    authentication.beginAppleRequest(request, rawNonce: &rawAppleNonce)
                } onCompletion: { result in
                    authentication.completeAppleLogin(result, rawNonce: rawAppleNonce)
                    rawAppleNonce = nil
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 48)
                Button(action: authentication.startGoogleLogin) {
                    HStack {
                        if authentication.isProcessing { ProgressView().controlSize(.small) }
                        Text(authentication.isProcessing ? "로그인 정보 확인 중…" : "Google 계정으로 로그인")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(authentication.isProcessing)
            }
            .padding(34)
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.accentColor, lineWidth: 1.5))
            .shadow(radius: 30, y: 14)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(MacAppVersion.displayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(18)
        }
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
                        Button { model.open(page) } label: {
                            Text(page.title)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(page.id == model.activePageID ? Color.accentColor.opacity(0.25) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .help(page.url.absoluteString)
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
            }
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
