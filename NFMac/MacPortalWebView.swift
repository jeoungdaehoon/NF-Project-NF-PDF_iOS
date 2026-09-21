import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private final class MacPortalCommandWebView: WKWebView {
    var onFindCommand: (() -> Void)?
    var onFindNextCommand: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        let hasUnsupportedModifier = modifiers.contains(.control) || modifiers.contains(.option)

        if modifiers.contains(.command), !hasUnsupportedModifier, key == "f" {
            onFindCommand?()
            return true
        }
        if modifiers.contains(.command), !hasUnsupportedModifier, key == "g" {
            onFindNextCommand?(modifiers.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct MacPortalWebView: NSViewRepresentable {
    @ObservedObject var model: MacPortalBrowserModel
    @ObservedObject var preferences: MacPortalPreferences
    let onFocus: () -> Void
    let onSidebarNavigate: (URL) -> Void
    let onFindCommand: () -> Void
    let onFindNextCommand: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            preferences: preferences,
            onFocus: onFocus,
            onSidebarNavigate: onSidebarNavigate,
            onFindCommand: onFindCommand,
            onFindNextCommand: onFindNextCommand
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(context.coordinator, name: "NFPortalMacNavigation")
        controller.add(context.coordinator, name: "NFPortalIOSGoogleLogin")
        controller.add(context.coordinator, name: "NFPortalIOSLogout")
        controller.add(context.coordinator, name: "NFPortalIOSPDFLocalStorage")
        controller.add(context.coordinator, name: "NFPortalIOSPDFDocuments")
        controller.add(context.coordinator, name: "NFPortalMacPageZoom")
        controller.add(context.coordinator, name: "NFPortalMacPaneFocus")
        controller.add(context.coordinator, name: "NFPortalMacSidebarNavigation")
        controller.add(context.coordinator, name: "NFPortalMacSidebarHover")
        controller.add(context.coordinator, name: "NFPortalMacLinkedDocumentPanel")
        controller.add(context.coordinator, name: "NFPortalMacPDFShare")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.applicationNameForUserAgent = "NFPortalMac/\(MacAppVersion.number)"
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = MacPortalCommandWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.onFindCommand = { [weak coordinator = context.coordinator] in
            coordinator?.onFindCommand()
        }
        webView.onFindNextCommand = { [weak coordinator = context.coordinator] backwards in
            coordinator?.onFindNextCommand(backwards)
        }
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = CGFloat(preferences.zoomPercent) / 100
        webView.appearance = preferences.appearance.webAppearance
        context.coordinator.lastAppliedZoomPercent = preferences.zoomPercent
        context.coordinator.lastAppliedAppearance = preferences.appearance
        context.coordinator.lastAppliedPDFLocalStorageEnabled = preferences.pdfLocalStorageEnabled
        context.coordinator.lastAppliedPDFDocumentCount = model.localPDFDocumentCount
        model.connect(webView)

        var request = URLRequest(url: model.startURL())
        request.setValue("ko-KR,ko;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        context.coordinator.preferences = preferences
        context.coordinator.onFocus = onFocus
        context.coordinator.onSidebarNavigate = onSidebarNavigate
        context.coordinator.onFindCommand = onFindCommand
        context.coordinator.onFindNextCommand = onFindNextCommand
        if model.webView !== webView { model.connect(webView) }
        if context.coordinator.lastAppliedZoomPercent != preferences.zoomPercent {
            webView.pageZoom = CGFloat(preferences.zoomPercent) / 100
            context.coordinator.lastAppliedZoomPercent = preferences.zoomPercent
            webView.evaluateJavaScript("""
            try { localStorage.setItem('nfPortalMacPageZoom', '\(preferences.zoomPercent)'); } catch (_) {}
            window.dispatchEvent(new CustomEvent('nfPortalMacZoomState', { detail: { percent: \(preferences.zoomPercent) } }));
            """)
        }
        if context.coordinator.lastAppliedAppearance != preferences.appearance {
            webView.appearance = preferences.appearance.webAppearance
            context.coordinator.lastAppliedAppearance = preferences.appearance
            let scheme = preferences.appearance == .dark ? "dark" : preferences.appearance == .light ? "light" : "normal"
            webView.evaluateJavaScript("document.documentElement.style.colorScheme='\(scheme)';")
        }
        if context.coordinator.lastAppliedPDFLocalStorageEnabled != preferences.pdfLocalStorageEnabled
            || context.coordinator.lastAppliedPDFDocumentCount != model.localPDFDocumentCount {
            context.coordinator.deliverPDFState(to: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.closePopupWindows()
        let controller = webView.configuration.userContentController
        [
            "NFPortalMacNavigation",
            "NFPortalIOSGoogleLogin",
            "NFPortalIOSLogout",
            "NFPortalIOSPDFLocalStorage",
            "NFPortalIOSPDFDocuments",
            "NFPortalMacPageZoom",
            "NFPortalMacPaneFocus",
            "NFPortalMacSidebarNavigation",
            "NFPortalMacSidebarHover",
            "NFPortalMacLinkedDocumentPanel",
            "NFPortalMacPDFShare",
        ]
            .forEach(controller.removeScriptMessageHandler(forName:))
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let commandWebView = webView as? MacPortalCommandWebView {
            commandWebView.onFindCommand = nil
            commandWebView.onFindNextCommand = nil
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, NSWindowDelegate, NSSharingServicePickerDelegate {
        var model: MacPortalBrowserModel
        var preferences: MacPortalPreferences
        var onFocus: () -> Void
        var onSidebarNavigate: (URL) -> Void
        var onFindCommand: () -> Void
        var onFindNextCommand: (Bool) -> Void
        var lastAppliedZoomPercent: Int?
        var lastAppliedAppearance: MacPortalAppearance?
        var lastAppliedPDFLocalStorageEnabled: Bool?
        var lastAppliedPDFDocumentCount: Int?
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
        private var popupWebViews: [ObjectIdentifier: WKWebView] = [:]
        private var sharingPicker: NSSharingServicePicker?
        private weak var sharingPopupWebView: WKWebView?
        private var temporaryShareURLs: [URL] = []
        private var pdfCreationWebViews: Set<ObjectIdentifier> = []

        init(
            model: MacPortalBrowserModel,
            preferences: MacPortalPreferences,
            onFocus: @escaping () -> Void,
            onSidebarNavigate: @escaping (URL) -> Void,
            onFindCommand: @escaping () -> Void,
            onFindNextCommand: @escaping (Bool) -> Void
        ) {
            self.model = model
            self.preferences = preferences
            self.onFocus = onFocus
            self.onSidebarNavigate = onSidebarNavigate
            self.onFindCommand = onFindCommand
            self.onFindNextCommand = onFindNextCommand
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.connect(webView)
            webView.evaluateJavaScript("""
            try { localStorage.setItem('nfPortalMacPageZoom', '\(preferences.zoomPercent)'); } catch (_) {}
            window.dispatchEvent(new CustomEvent('nfPortalMacZoomState', { detail: { percent: \(preferences.zoomPercent) } }));
            if (window.__nfMacNotifyNavigation) {
                [0, 120, 350, 800].forEach(function(delay) {
                    setTimeout(function() { window.__nfMacNotifyNavigation(0); }, delay);
                });
            }
            if (window.__nfMacNotifyLinkedDocumentPanel) {
                window.__nfMacNotifyLinkedDocumentPanel(0);
            }
            """)
            deliverPDFState(to: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.updateLinkedDocumentPanel(widthFraction: 0)
            model.refreshNavigationState()
            model.applySidebarVisibility()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let normalizedURL = MacPortalConfig.normalizedPortalURL(url)
            if normalizedURL != url {
                var request = navigationAction.request
                request.url = normalizedURL
                webView.load(request)
                decisionHandler(.cancel)
                return
            }
            if url.scheme == MacPortalConfig.callbackScheme {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            if url == MacPortalConfig.googleLoginURL {
                model.onGoogleLogin?()
                decisionHandler(.cancel)
                return
            }
            if isAttachmentNavigationURL(url) {
                presentAttachmentPreview(url, from: webView)
                decisionHandler(.cancel)
                return
            }
            if navigationAction.shouldPerformDownload || isDownloadNavigationURL(url) {
                decisionHandler(.download)
                return
            }
            if let scheme = url.scheme, !["http", "https", "about", "blob", "data"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let responseURL = navigationResponse.response.url,
               isPDFResponse(navigationResponse.response) {
                presentAttachmentPreview(responseURL, from: webView)
                decisionHandler(.cancel)
                return
            }
            let disposition = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?
                .lowercased() ?? ""
            if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let requestedURL = navigationAction.request.url
            let isBlankPopup = requestedURL == nil
                || requestedURL?.absoluteString.isEmpty == true
                || requestedURL?.scheme?.lowercased() == "about"
            if navigationAction.targetFrame == nil,
               isBlankPopup {
                return makePDFSharePopup(configuration: configuration, sourceWebView: webView)
            }

            if let url = requestedURL {
                let normalizedURL = MacPortalConfig.normalizedPortalURL(url)
                if isAttachmentNavigationURL(normalizedURL) { presentAttachmentPreview(normalizedURL, from: webView) }
                else if MacPortalConfig.isPortalURL(normalizedURL) { webView.load(URLRequest(url: normalizedURL)) }
                else { NSWorkspace.shared.open(normalizedURL) }
            }
            return nil
        }

        func webViewDidClose(_ webView: WKWebView) {
            let identifier = ObjectIdentifier(webView)
            if let window = popupWindows.removeValue(forKey: identifier) {
                popupWebViews.removeValue(forKey: identifier)
                window.delegate = nil
                window.close()
                return
            }
            model.refreshNavigationState()
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  let entry = popupWindows.first(where: { $0.value === window }) else { return }
            popupWindows.removeValue(forKey: entry.key)
            if let webView = popupWebViews.removeValue(forKey: entry.key) {
                webView.uiDelegate = nil
            }
        }

        func closePopupWindows() {
            let windows = Array(popupWindows.values)
            popupWindows.removeAll()
            popupWebViews.values.forEach {
                $0.uiDelegate = nil
            }
            popupWebViews.removeAll()
            sharingPicker?.close()
            sharingPicker = nil
            sharingPopupWebView = nil
            pdfCreationWebViews.removeAll()
            temporaryShareURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            temporaryShareURLs.removeAll()
            windows.forEach {
                $0.delegate = nil
                $0.close()
            }
        }

        private func makePDFSharePopup(
            configuration: WKWebViewConfiguration,
            sourceWebView: WKWebView
        ) -> WKWebView {
            let sourceSize = sourceWebView.window?.contentLayoutRect.size ?? NSSize(width: 1200, height: 800)
            let width = min(max(sourceSize.width * 0.78, 720), 1280)
            let height = min(max(sourceSize.height * 0.82, 620), 960)
            let popupWebView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: width, height: height),
                configuration: configuration
            )
            popupWebView.uiDelegate = self
            popupWebView.setValue(false, forKey: "drawsBackground")
            popupWebView.appearance = preferences.appearance.webAppearance
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "PDF 공유"
            window.contentView = popupWebView
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.center()

            let identifier = ObjectIdentifier(popupWebView)
            popupWindows[identifier] = window
            popupWebViews[identifier] = popupWebView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return popupWebView
        }

        private func createPDFForSharing(from webView: WKWebView) {
            let identifier = ObjectIdentifier(webView)
            guard pdfCreationWebViews.insert(identifier).inserted else { return }
            webView.evaluateJavaScript("""
            ({
                title: document.title || '',
                width: Math.max(
                    document.documentElement.scrollWidth || 0,
                    document.body ? document.body.scrollWidth : 0,
                    window.innerWidth || 0
                ),
                height: Math.max(
                    document.documentElement.scrollHeight || 0,
                    document.body ? document.body.scrollHeight : 0,
                    window.innerHeight || 0
                )
            })
            """) { [weak self, weak webView] pageValue, _ in
                guard let self, let webView else { return }
                let page = pageValue as? [String: Any]
                let rawTitle = (page?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = Self.safeFileName((rawTitle?.isEmpty == false ? rawTitle : nil) ?? "차트")
                let captureWidth = max((page?["width"] as? NSNumber)?.doubleValue ?? webView.bounds.width, 1)
                let captureHeight = max((page?["height"] as? NSNumber)?.doubleValue ?? webView.bounds.height, 1)
                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)

                webView.createPDF(configuration: configuration) { [weak self, weak webView] result in
                    guard let self, let webView else { return }
                    pdfCreationWebViews.remove(identifier)
                    do {
                        let data = try result.get()
                        let fileURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(title)-\(UUID().uuidString)")
                            .appendingPathExtension("pdf")
                        try data.write(to: fileURL, options: .atomic)
                        temporaryShareURLs.append(fileURL)
                        presentPDFActions(fileURL: fileURL, title: title, from: webView)
                    } catch {
                        presentPDFShareError(error, from: webView)
                    }
                }
            }
        }

        private func presentPDFActions(fileURL: URL, title: String, from webView: WKWebView) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "PDF 공유"
            alert.informativeText = "PDF 파일을 외부 앱으로 공유하거나 Mac에 다운로드할 수 있습니다."
            alert.addButton(withTitle: "외부 공유")
            alert.addButton(withTitle: "PDF 다운로드")
            let cancelButton = alert.addButton(withTitle: "취소")
            cancelButton.keyEquivalent = "\u{1b}"

            let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak webView] response in
                guard let self, let webView else { return }
                switch response {
                case .alertFirstButtonReturn:
                    presentSharingPicker(fileURL: fileURL, from: webView)
                case .alertSecondButtonReturn:
                    presentPDFSavePanel(fileURL: fileURL, title: title, from: webView)
                default:
                    closePopup(for: webView)
                }
            }
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }

        private func presentSharingPicker(fileURL: URL, from webView: WKWebView) {
            let picker = NSSharingServicePicker(items: [fileURL])
            picker.delegate = self
            sharingPicker = picker
            sharingPopupWebView = webView
            let anchor = NSRect(x: webView.bounds.maxX - 1, y: webView.bounds.maxY - 1, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: webView, preferredEdge: .minY)
        }

        private func presentPDFSavePanel(fileURL: URL, title: String, from webView: WKWebView) {
            let panel = NSSavePanel()
            panel.title = "PDF 다운로드"
            panel.prompt = "다운로드"
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = title.lowercased().hasSuffix(".pdf") ? title : "\(title).pdf"

            let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak webView] response in
                guard let self, let webView else { return }
                guard response == .OK, let destination = panel.url else {
                    closePopup(for: webView)
                    return
                }
                do {
                    let data = try Data(contentsOf: fileURL)
                    try data.write(to: destination, options: .atomic)
                    closePopup(for: webView)
                } catch {
                    presentPDFShareError(error, from: webView)
                }
            }
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }

        private func closePopup(for webView: WKWebView) {
            let identifier = ObjectIdentifier(webView)
            guard let window = popupWindows.removeValue(forKey: identifier) else { return }
            popupWebViews.removeValue(forKey: identifier)
            webView.uiDelegate = nil
            window.delegate = nil
            window.close()
        }

        private func presentPDFShareError(_ error: Error, from webView: WKWebView) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "PDF를 공유할 수 없습니다."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "확인")
            if let window = webView.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            sharingPicker = nil
            guard let webView = sharingPopupWebView else { return }
            sharingPopupWebView = nil
            closePopup(for: webView)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "NF Portal"
            alert.informativeText = message
            alert.addButton(withTitle: "확인")

            if let window = webView.window {
                alert.beginSheetModal(for: window) { _ in completionHandler() }
            } else {
                alert.runModal()
                completionHandler()
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "작업을 진행하시겠습니까?"
            alert.informativeText = message
            alert.addButton(withTitle: "확인")
            let cancelButton = alert.addButton(withTitle: "취소")
            cancelButton.keyEquivalent = "\u{1b}"

            let finish: (NSApplication.ModalResponse) -> Void = { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "값을 입력해 주세요."
            alert.informativeText = prompt
            alert.addButton(withTitle: "확인")
            let cancelButton = alert.addButton(withTitle: "취소")
            cancelButton.keyEquivalent = "\u{1b}"

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            input.stringValue = defaultText ?? ""
            input.placeholderString = prompt
            alert.accessoryView = input

            let finish: (NSApplication.ModalResponse) -> Void = { response in
                completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
            if let window = webView.window {
                alert.beginSheetModal(for: window) { response in
                    finish(response)
                }
                window.makeFirstResponder(input)
            } else {
                finish(alert.runModal())
            }
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.title = "첨부할 파일 선택"
            panel.prompt = "선택"
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.resolvesAliases = true

            let finish: (NSApplication.ModalResponse) -> Void = { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let panel = NSSavePanel()
            panel.title = "첨부 파일 저장"
            panel.prompt = "저장"
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = Self.safeFileName(suggestedFilename)

            let finish: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else {
                    completionHandler(nil)
                    return
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        completionHandler(nil)
                        return
                    }
                }
                completionHandler(url)
            }
            if let window = model.webView?.window {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "첨부 파일을 저장하지 못했습니다."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "NFPortalMacNavigation":
                guard let record = message.body as? [String: Any],
                      let rawURL = record["url"] as? String,
                      let url = URL(string: rawURL) else { return }
                let title = record["title"] as? String
                let breadcrumbs = record["breadcrumbs"] as? [[String: Any]] ?? []
                model.record(url: url, title: title, breadcrumbRecords: breadcrumbs)
                model.updatePageTitles(from: record["navigationTitles"] as? [[String: Any]] ?? [])
                model.updateTheme(
                    background: record["background"] as? String,
                    foreground: record["foreground"] as? String
                )
            case "NFPortalIOSGoogleLogin":
                model.onGoogleLogin?()
            case "NFPortalIOSLogout":
                model.onLogout?()
            case "NFPortalIOSPDFLocalStorage":
                if let enabled = boolValue(from: message.body) {
                    preferences.pdfLocalStorageEnabled = enabled
                    deliverPDFState(to: model.webView)
                }
            case "NFPortalIOSPDFDocuments":
                model.onOpenPDFDocuments?()
            case "NFPortalMacPageZoom":
                if let value = message.body as? NSNumber {
                    preferences.zoomPercent = value.intValue
                } else if let record = message.body as? [String: Any], let value = record["percent"] as? NSNumber {
                    preferences.zoomPercent = value.intValue
                }
            case "NFPortalMacPaneFocus":
                onFocus()
            case "NFPortalMacSidebarNavigation":
                guard let record = message.body as? [String: Any],
                      let rawURL = record["url"] as? String,
                      let url = URL(string: rawURL) else { return }
                onSidebarNavigate(url)
            case "NFPortalMacSidebarHover":
                if let record = message.body as? [String: Any] {
                    if (record["dismissAfterSelection"] as? NSNumber)?.boolValue == true {
                        model.dismissTransientSidebarAfterSelection()
                        return
                    }
                    let hovering = (record["hovering"] as? NSNumber)?.boolValue ?? false
                    let width = (record["width"] as? NSNumber).map { CGFloat(truncating: $0) }
                    model.setWebSidebarHover(hovering, width: width)
                } else if let hovering = message.body as? Bool {
                    model.setWebSidebarHover(hovering)
                }
            case "NFPortalMacLinkedDocumentPanel":
                guard let record = message.body as? [String: Any],
                      let value = record["widthFraction"] as? NSNumber else { return }
                model.updateLinkedDocumentPanel(widthFraction: CGFloat(truncating: value))
            case "NFPortalMacPDFShare":
                guard let sourceWebView = message.webView else { return }
                createPDFForSharing(from: sourceWebView)
            default:
                break
            }
        }

        func deliverPDFState(to webView: WKWebView?) {
            guard let webView else { return }
            let enabled = preferences.pdfLocalStorageEnabled ? "true" : "false"
            let count = max(0, model.localPDFDocumentCount)
            lastAppliedPDFLocalStorageEnabled = preferences.pdfLocalStorageEnabled
            lastAppliedPDFDocumentCount = count
            webView.evaluateJavaScript("""
            (function() {
                var enabled = \(enabled);
                var count = \(count);
                window.__NF_PORTAL_PDF_LOCAL_STORAGE_ENABLED__ = enabled;
                window.__NF_PORTAL_LOCAL_PDF_DOCUMENT_COUNT__ = count;
                try {
                    localStorage.setItem('nfPortalPDFLocalStorageEnabled', String(enabled));
                    localStorage.setItem('nfPortalLocalPDFDocumentCount', String(count));
                } catch (_) {}
                window.dispatchEvent(new CustomEvent('nfPortalPDFLocalStorageState', {
                    detail: { platform: 'mac', enabled: enabled }
                }));
                window.dispatchEvent(new CustomEvent('nfPortalLocalPDFDocumentState', {
                    detail: { platform: 'mac', count: count }
                }));
            })();
            """)
        }

        private func boolValue(from body: Any) -> Bool? {
            if let value = body as? Bool { return value }
            if let value = body as? NSNumber { return value.boolValue }
            if let value = body as? String {
                if ["true", "1", "on"].contains(value.lowercased()) { return true }
                if ["false", "0", "off"].contains(value.lowercased()) { return false }
            }
            if let record = body as? [String: Any] {
                return record["enabled"].flatMap(boolValue(from:))
            }
            return nil
        }

        private func isAttachmentNavigationURL(_ url: URL) -> Bool {
            if url.path.hasPrefix("/api/artifacts/files") { return true }
            if url.pathExtension.lowercased() == "pdf" { return true }
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                $0.name.lowercased() == "download"
            }) == true { return true }
            return false
        }

        private func isPDFResponse(_ response: URLResponse) -> Bool {
            if response.mimeType?.lowercased() == "application/pdf" { return true }
            return response.suggestedFilename?.lowercased().hasSuffix(".pdf") == true
        }

        private func isDownloadNavigationURL(_ url: URL) -> Bool {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                $0.name.lowercased() == "download"
                    && ($0.value == nil || !["0", "false", "no"].contains($0.value?.lowercased() ?? ""))
            }) == true
        }

        private static func safeFileName(_ value: String) -> String {
            let cleaned = value
                .components(separatedBy: CharacterSet(charactersIn: "/:\0"))
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "첨부 파일" : cleaned
        }

        private func presentAttachmentPreview(_ url: URL, from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let host = url.host?.lowercased()
                let matching = cookies.filter { cookie in
                    guard let host else { return false }
                    let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    return host == domain || host.hasSuffix(".\(domain)")
                }
                let cookieHeader = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                Task { @MainActor in
                    self.model.onPreviewPDFAttachment?(MacPDFRemoteRequest(
                        url: url,
                        cookieHeader: cookieHeader.isEmpty ? nil : cookieHeader
                    ))
                }
            }
        }
    }

    private static let bootstrapScript = #"""
    (function() {
        window.print = function() {
            window.webkit.messageHandlers.NFPortalMacPDFShare.postMessage({ action: 'sharePDF' });
        };
        document.documentElement.lang = 'ko-KR';
        document.documentElement.style.setProperty('-webkit-locale', '"ko-KR"');
        document.documentElement.setAttribute('data-nf-desktop-host', 'true');
        window.NFPortalIOS = window.NFPortalIOS || {};
        window.NFPortalIOS.setPDFLocalStorageEnabled = function(enabled) {
            window.webkit.messageHandlers.NFPortalIOSPDFLocalStorage.postMessage({ enabled: !!enabled });
        };
        window.NFPortalIOS.openPDFDocuments = function() {
            window.webkit.messageHandlers.NFPortalIOSPDFDocuments.postMessage('open');
        };

        function installDesktopHostStyle() {
            if (document.getElementById('__nfMacDesktopHostStyle')) return;
            var style = document.createElement('style');
            style.id = '__nfMacDesktopHostStyle';
            style.textContent = `
                html[data-nf-desktop-host="true"] .portal-titlebar button[aria-controls="portal-navigation"],
                html[data-nf-desktop-host="true"] .portal-titlebar button[aria-label="탭바 열기"] {
                    display: none !important;
                }
                html[data-nf-desktop-host="true"] .mobile-navigation-overlay {
                    display: none !important;
                }
                html[data-nf-desktop-host="true"] .portal-titlebar {
                    height: 40px !important;
                    min-height: 40px !important;
                }
                html[data-nf-desktop-host="true"] .portal-titlebar > div:first-child {
                    height: 40px !important;
                    min-height: 40px !important;
                }
                html[data-nf-desktop-host="true"]:not([data-nf-mac-sidebar-collapsed="true"]) *:has(> #portal-navigation) {
                    display: grid !important;
                    grid-template-columns: 276px minmax(0, 1fr) !important;
                    width: 100% !important;
                    height: 100dvh !important;
                    min-height: 0 !important;
                    overflow: hidden !important;
                }
                html[data-nf-desktop-host="true"]:not([data-nf-mac-sidebar-collapsed="true"]) #portal-navigation {
                    display: block !important;
                    position: sticky !important;
                    inset: auto !important;
                    top: 0 !important;
                    width: 276px !important;
                    height: 100dvh !important;
                    padding-left: 0 !important;
                    align-self: start !important;
                    visibility: visible !important;
                    opacity: 1 !important;
                    translate: none !important;
                    transform: none !important;
                    -webkit-transform: none !important;
                    animation: none !important;
                    box-shadow: none !important;
                }
                html[data-nf-desktop-host="true"]:not([data-nf-mac-sidebar-collapsed="true"]) #portal-content {
                    width: 100% !important;
                    min-width: 0 !important;
                    height: 100dvh !important;
                    min-height: 0 !important;
                    overflow-y: auto !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] #portal-navigation {
                    --nf-mac-sidebar-overscan: 12px;
                    display: block !important;
                    position: fixed !important;
                    inset: 0 auto 0 0 !important;
                    top: 0 !important;
                    right: auto !important;
                    bottom: 0 !important;
                    left: calc(0px - var(--nf-mac-sidebar-overscan)) !important;
                    margin-left: 0 !important;
                    width: calc(var(--nf-mac-sidebar-preview-width, 276px) + var(--nf-mac-sidebar-overscan)) !important;
                    height: 100% !important;
                    box-sizing: border-box !important;
                    padding-left: var(--nf-mac-sidebar-overscan) !important;
                    overflow-x: hidden !important;
                    z-index: 90 !important;
                    visibility: visible !important;
                    opacity: 1 !important;
                    background-color: var(--sidebar-background) !important;
                    background-clip: border-box !important;
                    transform: translate3d(calc(-100% + var(--nf-mac-sidebar-overscan)), 0, 0) !important;
                    animation: none !important;
                    transition: transform 220ms ease-out !important;
                    will-change: transform;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"][data-nf-mac-sidebar-preview="true"] #portal-navigation {
                    transform: none !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] #portal-content {
                    /* A transformed scroll container re-bases fixed editor controls and makes
                       their pointer-relative position drift by the vertical scroll offset. */
                    position: relative !important;
                    left: 0 !important;
                    transform: none !important;
                    transition: left 220ms ease-out !important;
                    will-change: left;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"][data-nf-mac-sidebar-preview="true"] #portal-content {
                    left: calc(var(--nf-mac-sidebar-preview-width, 276px) - 1px) !important;
                }
                @media (prefers-reduced-motion: reduce) {
                    html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] #portal-navigation,
                    html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] #portal-content {
                        transition-duration: 1ms !important;
                    }
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] [data-linked-document-panel="true"] {
                    top: 0 !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] [data-linked-document-panel="true"][data-linked-document-fullscreen="true"] {
                    inset: 0 0 0 !important;
                    height: auto !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] [data-linked-document-panel="true"] > [data-linked-document-body="true"] {
                    height: calc(100% - 56px) !important;
                }
            `;
            (document.head || document.documentElement).appendChild(style);
        }
        installDesktopHostStyle();

        function clean(value) { return String(value || '').replace(/\s+/g, ' ').trim(); }
        function normalizedPath(value) {
            try {
                var path = new URL(value, location.href).pathname.replace(/\/+$/, '');
                return path || '/';
            } catch (_) {
                var fallback = String(value || '').replace(/\/+$/, '');
                return fallback || '/';
            }
        }
        function routeFallbackTitle() {
            var path = normalizedPath(location.href);
            var titles = {
                '/': 'NF Portal',
                '/dashboard': 'NF Portal',
                '/projects': '프로젝트',
                '/daily-reports': '일일보고',
                '/weekly-reports': '주간보고',
                '/artifacts': '산출물',
                '/releases': '배포',
                '/environment': '환경 정보',
                '/slack': 'Slack',
                '/logs': '로그',
                '/logs/history': '수정 히스토리',
                '/logs/errors': '오류',
                '/logs/trash': '휴지통',
                '/settings': '설정',
                '/settings/font-accessories': '폰트 액세서리',
                '/custom-tabs': '페이지 추가·관리'
            };
            return titles[path] || (path.indexOf('/custom/') === 0 ? '상세 페이지' : clean(path.split('/').pop())) || 'NF Portal';
        }
        function navigationLinks() {
            var navigation = document.getElementById('portal-navigation');
            return navigation ? Array.from(navigation.querySelectorAll('a[href]')) : [];
        }
        function currentNavigationLink() {
            var currentExact = normalizedPath(location.href) + location.search;
            var currentPath = normalizedPath(location.href);
            var links = navigationLinks();
            return links.find(function(link) {
                try {
                    var url = new URL(link.href, location.href);
                    return normalizedPath(url.href) + url.search === currentExact;
                } catch (_) { return false; }
            }) || links.find(function(link) {
                try { return normalizedPath(link.href) === currentPath; }
                catch (_) { return false; }
            });
        }
        function linkTitle(link) {
            if (!link) return '';
            var label = link.querySelector('span.truncate') || link.querySelector('span') || link;
            return clean(label.textContent);
        }
        function navigationTitles() {
            var seen = {};
            return navigationLinks().reduce(function(records, link) {
                try {
                    var url = new URL(link.href, location.href);
                    var path = normalizedPath(url.href);
                    var title = linkTitle(link);
                    if (url.origin !== location.origin || !title || title === 'NF Portal' || seen[path]) return records;
                    seen[path] = true;
                    records.push({ url: url.href, title: title });
                } catch (_) {}
                return records;
            }, []);
        }
        function currentTitle() {
            var active = currentNavigationLink();
            if (active) return linkTitle(active) || routeFallbackTitle();
            var titleControl = document.querySelector('.portal-titlebar [aria-label="두 번 선택하면 페이지 최상단으로 이동"]');
            var portalTitle = clean(titleControl && titleControl.textContent);
            if (portalTitle && portalTitle !== 'NF Portal') return portalTitle;
            var documentTitle = clean(document.title);
            if (documentTitle && documentTitle !== 'NF Portal') return documentTitle;
            return routeFallbackTitle();
        }
        function breadcrumbs() {
            var home = { title: 'NF Portal', url: location.origin + '/' };
            var active = currentNavigationLink();
            if (!active) return [home, { title: currentTitle(), url: location.href }];
            var labels = [];
            var row = active.closest('[data-navigation-key], li, [role="treeitem"]') || active;
            var key = clean(row.getAttribute && row.getAttribute('data-navigation-key'));
            if (/[>›/]/.test(key)) labels = key.split(/\s*[>›/]\s*/).map(clean).filter(Boolean);
            var page = linkTitle(active) || currentTitle();
            labels = labels.filter(function(label) { return label !== page; });
            labels.push(page);
            return [home].concat(labels.map(function(label, index) {
                return { title: label, url: index === labels.length - 1 ? active.href : null };
            }));
        }

        window.__nfMacSidebarHidden = false;
        window.__nfMacSetSidebarContentInset = function(reserved) {
            var requestToken = (window.__nfMacSidebarContentInsetToken || 0) + 1;
            window.__nfMacSidebarContentInsetToken = requestToken;
            function apply() {
                if (requestToken !== window.__nfMacSidebarContentInsetToken) return;
                var content = document.getElementById('portal-content');
                if (!content) return;
                if (reserved) {
                    content.dataset.nfMacSidebarContentInset = 'true';
                    content.style.setProperty('padding-top', '26px', 'important');
                    content.style.setProperty('box-sizing', 'border-box', 'important');
                } else {
                    delete content.dataset.nfMacSidebarContentInset;
                    content.style.removeProperty('padding-top');
                    content.style.removeProperty('box-sizing');
                }
            }
            [0, 80, 250, 700].forEach(function(delay) { setTimeout(apply, delay); });
        };
        window.__nfMacSetSidebarPreviewVisible = function(visible, width) {
            var root = document.documentElement;
            var resolvedWidth = Number(width);
            if (Number.isFinite(resolvedWidth) && resolvedWidth > 0) {
                root.style.setProperty('--nf-mac-sidebar-preview-width', resolvedWidth + 'px');
            }
            if (!window.__nfMacSidebarHidden) visible = false;
            if (visible) root.setAttribute('data-nf-mac-sidebar-preview', 'true');
            else root.removeAttribute('data-nf-mac-sidebar-preview');
            var openButton = document.querySelector('.portal-titlebar button[aria-controls="portal-navigation"]');
            if (visible && openButton && openButton.getAttribute('aria-expanded') !== 'true') {
                openButton.click();
            } else if (!visible) {
                var closeButton = document.querySelector('button[aria-label="탭바 닫기"]');
                if (closeButton) closeButton.click();
            }
        };
        window.__nfMacSetSidebarHidden = function(hidden) {
            window.__nfMacSidebarHidden = !!hidden;
            if (hidden) document.documentElement.setAttribute('data-nf-mac-sidebar-collapsed', 'true');
            else document.documentElement.removeAttribute('data-nf-mac-sidebar-collapsed');
            if (!hidden) window.__nfMacSetSidebarPreviewVisible(false);
            var requestToken = (window.__nfMacSidebarToken || 0) + 1;
            window.__nfMacSidebarToken = requestToken;
            function apply() {
                if (requestToken !== window.__nfMacSidebarToken) return;
                var navigation = document.getElementById('portal-navigation');
                var content = document.getElementById('portal-content');
                var root = navigation && navigation.parentElement;
                if (!navigation || !content || !root) return;
                if (hidden) {
                    navigation.dataset.nfMacHidden = 'true';
                    navigation.style.removeProperty('display');
                    root.style.setProperty('display', 'block', 'important');
                    root.style.setProperty('grid-template-columns', 'minmax(0, 1fr)', 'important');
                    content.style.setProperty('width', '100%', 'important');
                } else {
                    delete navigation.dataset.nfMacHidden;
                    document.documentElement.removeAttribute('data-nf-mac-sidebar-preview');
                    navigation.style.removeProperty('display');
                    root.style.removeProperty('display');
                    root.style.removeProperty('grid-template-columns');
                    content.style.removeProperty('width');
                    if (getComputedStyle(navigation).display === 'none') navigation.style.setProperty('display', 'block', 'important');
                }
            }
            [0, 80, 250, 700].forEach(function(delay) { setTimeout(apply, delay); });
            window.dispatchEvent(new CustomEvent('nfPortalDesktopSidebarToggle', {
                detail: { collapsed: !!hidden, platform: 'mac' }
            }));
        };

        var linkedDocumentPanelTimer = null;
        var lastLinkedDocumentPanelSignature = '';
        window.__nfMacNotifyLinkedDocumentPanel = function(delay) {
            clearTimeout(linkedDocumentPanelTimer);
            linkedDocumentPanelTimer = setTimeout(function() {
                var panel = document.querySelector('[data-linked-document-panel="true"]');
                var widthFraction = 0;
                if (panel) {
                    var panelStyle = getComputedStyle(panel);
                    var panelRect = panel.getBoundingClientRect();
                    var viewportWidth = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0, 1);
                    var visibleWidth = Math.max(
                        0,
                        Math.min(panelRect.right, viewportWidth) - Math.max(panelRect.left, 0)
                    );
                    var isVisible = panelStyle.display !== 'none'
                        && panelStyle.visibility !== 'hidden'
                        && Number(panelStyle.opacity || 1) > 0
                        && panelRect.height > 0;
                    if (isVisible) widthFraction = Math.min(1, visibleWidth / viewportWidth);
                }
                var signature = widthFraction.toFixed(4);
                if (signature === lastLinkedDocumentPanelSignature) return;
                lastLinkedDocumentPanelSignature = signature;
                window.webkit.messageHandlers.NFPortalMacLinkedDocumentPanel.postMessage({
                    widthFraction: widthFraction
                });
            }, typeof delay === 'number' ? delay : 40);
        };

        var linkedDocumentPanelObserver = new MutationObserver(function() {
            [0, 80, 220, 500].forEach(function(delay) {
                setTimeout(function() { window.__nfMacNotifyLinkedDocumentPanel(0); }, delay);
            });
        });
        linkedDocumentPanelObserver.observe(document.documentElement, {
            subtree: true,
            childList: true,
            attributes: true,
            attributeFilter: [
                'style',
                'class',
                'hidden',
                'aria-hidden',
                'data-linked-document-panel',
                'data-linked-document-fullscreen'
            ]
        });
        addEventListener('resize', function() { window.__nfMacNotifyLinkedDocumentPanel(40); });

        var timer = null;
        var lastSignature = '';
        window.__nfMacNotifyNavigation = function(delay) {
            clearTimeout(timer);
            timer = setTimeout(function() {
                document.documentElement.lang = 'ko-KR';
                document.querySelectorAll('input[type="date"]').forEach(function(input) { input.lang = 'ko-KR'; });
                if (window.__nfMacSidebarHidden) window.__nfMacSetSidebarHidden(true);
                var style = getComputedStyle(document.body || document.documentElement);
                var title = currentTitle();
                var resolvedNavigationTitles = navigationTitles();
                var signature = location.href + '|' + title + '|' + resolvedNavigationTitles.map(function(item) {
                    return item.url + '=' + item.title;
                }).join(';');
                if (signature === lastSignature && delay !== 0) return;
                lastSignature = signature;
                window.webkit.messageHandlers.NFPortalMacNavigation.postMessage({
                    url: location.href,
                    title: title,
                    breadcrumbs: breadcrumbs(),
                    navigationTitles: resolvedNavigationTitles,
                    background: style.backgroundColor,
                    foreground: style.color
                });
            }, typeof delay === 'number' ? delay : 100);
        };
        ['pushState', 'replaceState'].forEach(function(name) {
            var original = history[name];
            history[name] = function() {
                var result = original.apply(this, arguments);
                window.__nfMacNotifyNavigation(80);
                return result;
            };
        });
        addEventListener('popstate', function() { window.__nfMacNotifyNavigation(40); });
        addEventListener('pageshow', function() { window.__nfMacNotifyNavigation(0); });
        addEventListener('pageshow', function() { window.__nfMacNotifyLinkedDocumentPanel(0); });
        var navigationObserver = new MutationObserver(function(mutations) {
            var changed = mutations.some(function(mutation) {
                var target = mutation.target && mutation.target.nodeType === 1
                    ? mutation.target
                    : mutation.target && mutation.target.parentElement;
                if (target && target.closest && target.closest('#portal-navigation, .portal-titlebar')) return true;
                return Array.from(mutation.addedNodes || []).some(function(node) {
                    return node && node.nodeType === 1 && (
                        node.matches('#portal-navigation, .portal-titlebar') ||
                        node.querySelector('#portal-navigation, .portal-titlebar')
                    );
                });
            });
            if (changed) window.__nfMacNotifyNavigation(60);
        });
        navigationObserver.observe(document.documentElement, {
            subtree: true,
            childList: true,
            characterData: true,
            attributes: true,
            attributeFilter: ['href', 'aria-current']
        });
        document.addEventListener('pointerdown', function(event) {
            var target = event.target;
            if (!target || !target.closest || target.closest('#portal-navigation')) return;
            window.webkit.messageHandlers.NFPortalMacPaneFocus.postMessage('focus');
        }, true);
        document.addEventListener('pointerover', function(event) {
            var navigation = event.target && event.target.closest && event.target.closest('#portal-navigation');
            if (!navigation || (event.relatedTarget && navigation.contains(event.relatedTarget))) return;
            var overscan = parseFloat(getComputedStyle(navigation).getPropertyValue('--nf-mac-sidebar-overscan')) || 0;
            window.webkit.messageHandlers.NFPortalMacSidebarHover.postMessage({
                hovering: true,
                width: Math.max(0, navigation.getBoundingClientRect().width - overscan)
            });
        }, true);
        document.addEventListener('pointerout', function(event) {
            var navigation = event.target && event.target.closest && event.target.closest('#portal-navigation');
            if (!navigation || (event.relatedTarget && navigation.contains(event.relatedTarget))) return;
            window.webkit.messageHandlers.NFPortalMacSidebarHover.postMessage({ hovering: false });
        }, true);
        document.addEventListener('click', function(event) {
            var target = event.target;
            var link = target && target.closest && target.closest('a[href]');
            var navigation = target && target.closest && target.closest('#portal-navigation');
            var disclosureButton = navigation && target && target.closest && target.closest('button[aria-expanded]');
            var isDisclosureInteraction = !!(disclosureButton && navigation.contains(disclosureButton));
            if (navigation && window.__nfMacSidebarHidden && event.isTrusted && isDisclosureInteraction) {
                var overscan = parseFloat(getComputedStyle(navigation).getPropertyValue('--nf-mac-sidebar-overscan')) || 0;
                window.webkit.messageHandlers.NFPortalMacSidebarHover.postMessage({
                    hovering: true,
                    width: Math.max(0, navigation.getBoundingClientRect().width - overscan)
                });
            } else if (navigation && window.__nfMacSidebarHidden && event.isTrusted) {
                document.documentElement.removeAttribute('data-nf-mac-sidebar-preview');
                window.webkit.messageHandlers.NFPortalMacSidebarHover.postMessage({
                    hovering: false,
                    dismissAfterSelection: true
                });
            }
            if (link && navigation) {
                try {
                    var url = new URL(link.href, location.href);
                    if (url.origin === location.origin) {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.NFPortalMacSidebarNavigation.postMessage({ url: url.href });
                        return;
                    }
                } catch (_) {}
            }
            if (link) {
                window.__nfMacNotifyNavigation(160);
                setTimeout(function() { window.__nfMacNotifyNavigation(0); }, 450);
            }
        }, true);
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() { window.__nfMacNotifyNavigation(0); }, { once: true });
        } else {
            window.__nfMacNotifyNavigation(0);
        }
    })();
    """#
}
