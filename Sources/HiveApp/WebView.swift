import AppKit
import HiveCore
import SwiftUI
import WebKit

/// The window's content: the Agent Hive pages in a web view, loaded from `hive://app/`.
struct WebView: NSViewRepresentable {
    let api: HiveAPI
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let handler = SchemeHandler(api: api)
        context.coordinator.handler = handler
        config.setURLSchemeHandler(handler, forURLScheme: SchemeHandler.scheme)
        config.websiteDataStore = .default()   // the pages keep their view settings in localStorage
        config.userContentController.add(context.coordinator, name: "copy")
        config.userContentController.addUserScript(WKUserScript(source: Coordinator.clipboardShim,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: Self.startURL()))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // A view chosen from the menu bar, such as a session that needs you.
        if let route = model.route, route.hasPrefix("#/") {
            let escaped = route.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "")
            view.evaluateJavaScript("location.hash = '\(escaped)'")
            DispatchQueue.main.async { model.route = nil }
        }
    }

    /// `hive://app/`, or a view given on the command line with `--open "#/classroom"`.
    static func startURL() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count, args[i + 1].hasPrefix("#/"),
           let url = URL(string: SchemeHandler.home.absoluteString + args[i + 1]) {
            return url
        }
        return SchemeHandler.home
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var handler: SchemeHandler?

        /// Pages from a custom scheme may not get `navigator.clipboard`; copy through the app instead.
        static let clipboardShim = """
        (function () {
          const copy = (text) => { window.webkit.messageHandlers.copy.postMessage(String(text)); return Promise.resolve(); };
          try {
            if (!navigator.clipboard || !navigator.clipboard.writeText) {
              Object.defineProperty(navigator, "clipboard", { value: { writeText: copy }, configurable: true });
            } else {
              navigator.clipboard.writeText = copy;
            }
          } catch (e) {}
        })();
        """

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "copy", let text = message.body as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// The pages stay inside the app; links to anything else open in the default app for them.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == SchemeHandler.scheme || url.scheme == "about" || url.scheme == "data" {
                return decisionHandler(.allow)
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
