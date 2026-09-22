import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor @Observable final class ResourceAuthenticationCoordinator: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private(set) var request: ResourceAuthenticationRequest?
    private(set) var error: String?
    private(set) var hostname = ""
    private(set) var opened = false
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var browser: BrowserChoice = .inApp
    @ObservationIgnored private var browserID = ""

    func begin(_ request: ResourceAuthenticationRequest, browser: BrowserChoice, browserID: String) {
        guard request.expiresAt > .now else { return }
        if self.request?.sessionID == request.sessionID && self.request?.challengeID == request.challengeID { return }
        finish()
        self.request = request
        self.browser = browser
        self.browserID = browserID
        hostname = request.url.host ?? ""
        let delay = request.expiresAt.timeIntervalSinceNow
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.finish()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sign in to a protected resource"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ResourceAuthenticationView(coordinator: self))
        window.center()
        self.window = window
        reopen()
    }

    func reopen() {
        guard request?.expiresAt ?? .distantPast > .now else { finish(); return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openSignIn() {
        guard let request, request.expiresAt > .now, !opened else { return }
        error = nil
        if browser == .inApp {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            self.webView = webView
            opened = true
            webView.load(URLRequest(url: request.url))
        } else {
            let application = browser == .specific
                ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID)
                : NSWorkspace.shared.urlForApplication(toOpen: request.url)
            guard let application else { error = "Your chosen browser is unavailable."; return }
            opened = true
            NSWorkspace.shared.open([request.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { @Sendable [weak self] _, failure in
                let failed = failure != nil
                Task { @MainActor in
                    guard let self, self.request?.sessionID == request.sessionID,
                          self.request?.challengeID == request.challengeID else { return }
                    if failed { self.opened = false; self.error = "Your browser could not open the sign-in page." }
                }
            }
        }
    }

    func finish() {
        expiryTask?.cancel()
        expiryTask = nil
        request = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        window?.delegate = nil
        window?.close()
        window = nil
        hostname = ""
        error = nil
        opened = false
    }

    func windowWillClose(_ notification: Notification) { finish() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard request?.expiresAt ?? .distantPast > .now, let url = action.request.url,
              url.scheme == "https", url.user == nil, url.password == nil else {
            error = "This sign-in page requested an unsupported address."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { hostname = webView.url?.host ?? "" }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = "The resource sign-in page could not load." }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard request?.expiresAt ?? .distantPast > .now, let url = action.request.url,
              url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        webView.load(action.request)
        return nil
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
