import WebKit

/// Export popups share the site's data store, not its navigation chrome or
/// observers. A copied sidebar-collapsed attribute must never add a breadcrumb
/// over the first line of the document being exported.
enum MacPortalPDFSharing {
    @MainActor static func preparePopup(
        configuration: WKWebViewConfiguration,
        handler: WKScriptMessageHandler
    ) {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: """
            window.print = function() {
                window.webkit.messageHandlers.NFPortalMacPDFShare.postMessage({ action: 'sharePDF' });
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(handler, name: "NFPortalMacPDFShare")
        // Replace, rather than clearing the inherited/shared controller: the
        // source pane still needs all of its normal portal scripts and bridges.
        configuration.userContentController = controller
    }

    static let measurementScript = """
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
    """
}
