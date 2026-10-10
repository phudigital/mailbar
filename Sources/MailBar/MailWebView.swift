import AppKit
import SwiftUI
import WebKit

/// WKWebView hiển thị nội dung thư: tắt JavaScript, chặn tải tài nguyên từ xa (ảnh theo dõi...) trừ khi cho phép,
/// link được mở bằng trình duyệt mặc định.
struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let key = "\(allowRemote)|\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        let content = Self.injectFitStyle(html)
        webView.pageZoom = 1
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if allowRemote {
            webView.loadHTMLString(content, baseURL: nil)
        } else {
            RemoteContentBlocker.ruleList { list in
                if let list { controller.add(list) }
                webView.loadHTMLString(content, baseURL: nil)
            }
        }
    }

    /// Ảnh không vượt quá bề ngang bảng (bảng menubar khá hẹp).
    private static func injectFitStyle(_ html: String) -> String {
        let style = "<style>img{max-width:100%!important;height:auto!important}body{margin:10px}</style>"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: style, at: head.upperBound)
            return out
        }
        return style + html
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedKey: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        /// Thư HTML thiết kế rộng (thường 600px) được thu nhỏ cho vừa bề ngang bảng.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollWidth") { result, _ in
                guard let contentWidth = (result as? NSNumber)?.doubleValue, contentWidth > 0 else { return }
                let available = webView.bounds.width
                if contentWidth > available + 2 {
                    webView.pageZoom = max(0.5, available / contentWidth)
                }
            }
        }

        // Link target="_blank".
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

enum RemoteContentBlocker {
    private static var cached: WKContentRuleList?

    static func ruleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let cached { return completion(cached) }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "MailBarBlockRemote",
                                                                encodedContentRuleList: rules) { list, _ in
            cached = list
            completion(list)
        }
    }
}
