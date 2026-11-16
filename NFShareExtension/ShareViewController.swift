import UIKit
import UniformTypeIdentifiers
import PDFKit

/// Uses public extension APIs: preview and save here; the app imports the durable inbox on activation.
final class ShareViewController: UIViewController {
    private let pdfView = PDFView()
    private let status = UILabel()
    private let retry = UIButton(type: .system)
    private let previous = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private var entries: [IncomingDocuments.Entry] = []
    private var selected = 0
    private var work: Task<Void, Never>?
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.numberOfLines = 0
        status.text = "공유 문서를 NF에 저장하고 있습니다…"
        status.accessibilityIdentifier = "nf-share-status"
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        let done = UIButton(type: .system)
        done.setTitle("완료", for: .normal)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        retry.setTitle("다시 변환", for: .normal)
        retry.isHidden = true
        retry.addTarget(self, action: #selector(retryConversion), for: .touchUpInside)
        previous.setTitle("이전", for: .normal); nextButton.setTitle("다음", for: .normal)
        previous.isEnabled = false; nextButton.isEnabled = false
        previous.addTarget(self, action: #selector(showPrevious), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(showNext), for: .touchUpInside)
        let bar = UIStackView(arrangedSubviews: [previous, nextButton, retry, done])
        bar.spacing = 20; bar.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [status, bar, pdfView])
        stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        work = Task {
            do {
                let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                guard !providers.isEmpty, providers.count <= 10 else { throw IncomingDocuments.Failure.message("문서 파일은 한 번에 10개까지 공유해 주세요.") }
                for provider in providers {
                    try Task.checkCancellation()
                    entries.append(try await receive(provider))
                }
                // Original files are durable before conversion starts. Failed conversions can resume in the app.
                for entry in entries { _ = try await IncomingDocuments.prepare(entry) }
                showSelected()
            } catch { showError(error) }
        }
    }
    private func receive(_ provider: NSItemProvider) async throws -> IncomingDocuments.Entry {
        guard let type = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .plainText) || IncomingDocuments.supported.contains(type.preferredFilenameExtension ?? "")
        }) else { throw IncomingDocuments.Failure.message("PDF, PPT/PPTX, 이미지, Markdown, TXT 파일을 지원합니다.") }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // NSItemProvider deletes this URL after the callback; copy it before returning.
                if let url {
                    do { continuation.resume(returning: try IncomingDocuments.enqueue(url, suggestedName: provider.suggestedName)) }
                    catch { continuation.resume(throwing: error) }
                } else if UTType(type)?.conforms(to: .plainText) == true {
                    provider.loadItem(forTypeIdentifier: type, options: nil) { value, loadError in
                        guard let text = value as? String else { continuation.resume(throwing: loadError ?? error ?? CocoaError(.fileReadUnknown)); return }
                        let data = Data(text.utf8)
                        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { continuation.resume(throwing: IncomingDocuments.Failure.message("공유 문서는 25MB까지 지원합니다.")); return }
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("NF-\(UUID().uuidString).txt")
                        defer { try? FileManager.default.removeItem(at: temp) }
                        do {
                            try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                            continuation.resume(returning: try IncomingDocuments.enqueue(temp, suggestedName: provider.suggestedName ?? "공유 텍스트.txt"))
                        } catch { continuation.resume(throwing: error) }
                    }
                } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
    private func showSelected() {
        guard entries.indices.contains(selected) else { return }
        let entry = entries[selected]
        pdfView.document = (try? entry.pdfURL).flatMap { PDFDocument(url: $0) }
        status.text = "\(selected + 1)/\(entries.count) · \(IncomingDocuments.pdfName(entry.name))\nNF 문서함에 저장했습니다. 본 앱을 열면 자동으로 표시됩니다."
        retry.isHidden = true
        previous.isEnabled = selected > 0; nextButton.isEnabled = selected + 1 < entries.count
    }
    private func showError(_ error: Error) {
        status.text = error.localizedDescription + (entries.isEmpty ? "" : "\n받은 원본은 보관했습니다. NF 앱에서도 다시 가져올 수 있습니다.")
        retry.isHidden = entries.isEmpty
    }
    @objc private func retryConversion() {
        work?.cancel()
        status.text = "PDF로 변환하고 있습니다…"; retry.isHidden = true
        work = Task {
            do { for entry in entries { _ = try await IncomingDocuments.prepare(entry) }; showSelected() }
            catch { showError(error) }
        }
    }
    @objc private func showPrevious() { selected = max(0, selected - 1); showSelected() }
    @objc private func showNext() { selected = min(entries.count - 1, selected + 1); showSelected() }
    @objc private func finish() { work?.cancel(); extensionContext?.completeRequest(returningItems: nil) }
}
