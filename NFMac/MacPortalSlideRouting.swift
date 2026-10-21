import Foundation
import WebKit

enum MacPortalPaneSelection: String, Hashable { case primary, secondary }

enum MacPortalSlideDestination: String, CaseIterable, Identifiable {
    case current, right, left
    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: "현 페이지"
        case .right: "오른쪽 분할 페이지"
        case .left: "왼쪽 분할 페이지"
        }
    }
    func pane(source: MacPortalPaneSelection, isSplit: Bool) -> MacPortalPaneSelection {
        guard isSplit else { return .primary }
        switch self {
        case .current: return source
        case .right: return .secondary
        case .left: return .primary
        }
    }
}

/// Relays semantic open/close requests, never a page navigation or copied editor DOM.
/// The receiving web controller performs the same permission checks and saves as a local slide.
@MainActor final class MacPortalSlideRouter {
    private weak var primary: MacPortalBrowserModel?
    private weak var secondary: MacPortalBrowserModel?
    private var destination: MacPortalSlideDestination = .current
    private var isSplit = false
    private var pending: [String: (source: String, target: String, record: [String: Any], delivered: Bool)] = [:]
    private var localSlides: [String: Set<String>] = [:]
    var onFailure: ((String) -> Void)?
    var hasOpenSlides: Bool { !pending.isEmpty || localSlides.values.contains { !$0.isEmpty } }
    var hasRoutedSlides: Bool { !pending.isEmpty }

    func configure(primary: MacPortalBrowserModel, secondary: MacPortalBrowserModel,
                   destination: MacPortalSlideDestination, isSplit: Bool) {
        self.primary = primary; self.secondary = secondary
        self.destination = destination; self.isSplit = isSplit
        for model in [primary, secondary] {
            let source: MacPortalPaneSelection = model.identifier == secondary.identifier ? .secondary : .primary
            let target = destination.pane(source: source, isSplit: isSplit)
            model.slideRoutingConfiguration = ["pane": source.rawValue, "target": target.rawValue, "split": isSplit]
            model.onSlideRoutingMessage = { [weak self, weak model] record in
                guard let model else { return }
                self?.receive(record, from: model.identifier)
            }
        }
    }

    private func model(_ pane: String) -> MacPortalBrowserModel? {
        pane == primary?.identifier ? primary : pane == secondary?.identifier ? secondary : nil
    }

    func receive(_ record: [String: Any], from source: String) {
        guard let action = record["action"] as? String, let sender = model(source) else { return }
        if action == "reset" {
            localSlides[source] = nil
            for (id, entry) in pending {
                if entry.target == source {
                    model(entry.source)?.webView?.callAsyncJavaScript(
                        "window.dispatchEvent(new CustomEvent('nfMacSlideClosed', {detail: {id}}));",
                        arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
                    pending.removeValue(forKey: id)
                } else if entry.source == source {
                    receive(["action": "released", "id": id], from: source)
                }
            }
            return
        }
        if action == "ready" {
            for (id, entry) in pending where entry.target == source && !entry.delivered { deliver(id: id, attempt: 0) }
            return
        }
        guard let id = record["id"] as? String, UUID(uuidString: id) != nil else { return }
        if action == "localOpen" { localSlides[source, default: []].insert(id); return }
        if action == "localClosed" { localSlides[source]?.remove(id); return }
        if action == "update", var entry = pending[id], entry.source == source,
           let snapshot = record["snapshot"] as? [String: Any] {
            entry.record["payload"] = ["kind": "linked", "snapshot": snapshot]
            pending[id] = entry
            model(entry.target)?.webView?.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('nfMacSlideUpdated', {detail: record}));",
                arguments: ["record": record], in: nil, in: .page, completionHandler: nil)
            return
        }
        if action == "released", let entry = pending[id], entry.source == source {
            if !entry.delivered { pending.removeValue(forKey: id); return }
            model(entry.target)?.webView?.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('nfMacSlideReleased', {detail: {id}}));",
                arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
            // Keep the destination/session until the user closes the retained draft.
            return
        }
        if action == "invoke", let entry = pending[id], entry.target == source,
           let token = record["token"] as? String, UUID(uuidString: token) != nil,
           let operation = record["operation"] as? String, operation.count < 200,
           let args = record["args"] as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: record), data.count <= 16_000_000 {
            guard let webView = model(entry.source)?.webView else {
                mutationResult(id: id, token: token, target: entry.target, result: ["ok": false, "error": "원본 페이지가 닫혔습니다. 입력 내용을 복사해 보관해 주세요."])
                return
            }
            webView.callAsyncJavaScript(
                "return typeof window.__nfMacApplySlideMutation === 'function' ? await window.__nfMacApplySlideMutation(record) : {ok:false,error:'원본 페이지가 닫혔습니다.'};",
                arguments: ["record": ["id": id, "operation": operation, "args": args]], in: nil, in: .page
            ) { [weak self] result in
                let response: [String: Any]
                if case .success(let value) = result, let value = value as? [String: Any] { response = value }
                else { response = ["ok": false, "error": "원본 문서의 저장 응답을 확인하지 못했습니다. 입력 내용은 유지됩니다."] }
                self?.mutationResult(id: id, token: token, target: entry.target, result: response)
            }
            return
        }
        if action == "closed" {
            guard let entry = pending[id], entry.target == source else { return }
            model(entry.source)?.webView?.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('nfMacSlideClosed', {detail: {id}}));",
                arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
            pending.removeValue(forKey: id)
            return
        }
        guard action == "open", record["payload"] is [String: Any],
              JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record), data.count <= 16_000_000 else { return }
        let pane: MacPortalPaneSelection = sender === secondary ? .secondary : .primary
        let target = destination.pane(source: pane, isSplit: isSplit).rawValue
        guard target != source else { return }
        guard pending[id] == nil else { return }
        pending[id] = (source, target, record, false)
        deliver(id: id, attempt: 0)
    }

    private func mutationResult(id: String, token: String, target: String, result: [String: Any]) {
        model(target)?.webView?.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('nfMacSlideMutationResult', {detail: record}));",
            arguments: ["record": ["id": id, "token": token, "result": result]], in: nil, in: .page, completionHandler: nil)
    }

    private func deliver(id: String, attempt: Int) {
        guard let entry = pending[id], !entry.delivered else { return }
        guard let webView = model(entry.target)?.webView else { retry(id: id, attempt: attempt); return }
        webView.callAsyncJavaScript(
            "return typeof window.__nfMacReceiveSlide === 'function' && window.__nfMacReceiveSlide(record);",
            arguments: ["record": entry.record], in: nil, in: .page
        ) { [weak self] result in
            guard let self, self.pending[id] != nil else { return }
            if case .success(let value) = result, (value as? Bool) == true {
                self.pending[id]?.delivered = true
            } else {
                self.retry(id: id, attempt: attempt)
            }
        }
    }

    private func retry(id: String, attempt: Int) {
        guard let entry = pending[id], !entry.delivered else { return }
        guard attempt < 40 else {
            pending.removeValue(forKey: id)
            model(entry.source)?.webView?.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('nfMacSlideFailed', {detail: {id}}));",
                arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
            onFailure?("선택한 페이지에서 슬라이드를 열지 못했습니다. 페이지 로딩과 웹 버전을 확인해 주세요.")
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.deliver(id: id, attempt: attempt + 1)
        }
    }
}
