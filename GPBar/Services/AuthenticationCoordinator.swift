import AppKit
import AuthenticationServices
import Observation
import SwiftUI
import WebKit

@MainActor @Observable final class AuthenticationCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, ASWebAuthenticationPresentationContextProviding {
    var onCallback: ((String, String, String) -> Void)?
    var onOTP: ((String, String, String) -> Void)?
    var onCredentials: ((String, String, String, String) -> Void)?
    var onCancel: (() -> Void)?
    var onRetryExternally: (() -> Void)?
    private(set) var hostname = ""
    private(set) var message = "Finish signing in with your organization."
    private(set) var error: String?
    private(set) var isOTP = false
    private(set) var isCredentials = false
    private(set) var usernameLabel = "Username"
    private(set) var passwordLabel = "Password"
    var username = ""
    var password = ""
    private(set) var isEmbedded = true
    private(set) var callbackHandlerRequired = false
    private(set) var submitted = false
    var pastedCallback = ""
    var otp = ""
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var popupWindows: [NSWindow] = []
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var challengeID: String?
    @ObservationIgnored private var launchURL: URL?
    @ObservationIgnored private var browser: BrowserChoice = .inApp
    @ObservationIgnored private var browserID = ""
    @ObservationIgnored private var closing = false

    func begin(sessionID: String, event: EngineEvent, preferences: ConnectionPreferences, browserOverride: BrowserChoice? = nil) {
        guard let challengeID = event.challengeID else { return }
        if self.sessionID == sessionID && self.challengeID == challengeID { reopen(); return }
        closeOwnedWindows()
        launchURL = nil
        hostname = ""
        self.sessionID = sessionID
        self.challengeID = challengeID
        isOTP = event.type == .otpRequired
        isCredentials = event.type == .credentialsRequired
        usernameLabel = event.usernameLabel ?? "Username"
        passwordLabel = event.passwordLabel ?? "Password"
        username = ""
        password = ""
        submitted = false
        error = nil
        pastedCallback = ""
        otp = ""
        callbackHandlerRequired = false
        browser = browserOverride ?? preferences.browser
        browserID = preferences.browserID
        isEmbedded = browser == .inApp && !isOTP && !isCredentials
        message = isOTP ? "Enter the verification code requested by your organization." : "Finish signing in with your organization."
        if isOTP || isCredentials {
            hostname = event.server.flatMap { URL(string: $0)?.host } ?? ""
            message = event.message ?? "Enter the details requested by your organization."
        } else {
            guard let raw = event.launchURL, let url = URL(string: raw), url.scheme == "http",
                  url.host == "127.0.0.1", url.port != nil, url.query == nil, url.fragment == nil,
                  url.user == nil, url.password == nil, url.path.count == 49,
                  url.path.dropFirst().allSatisfy({ $0.isHexDigit }) else {
                error = "The sign-in page could not be verified. Cancel this attempt and try again."
                showWindow()
                return
            }
            launchURL = url
            if isEmbedded {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let webView = WKWebView(frame: .zero, configuration: configuration)
                configure(webView)
                self.webView = webView
                webView.load(URLRequest(url: url))
            }
        }
        showWindow()
        if !isEmbedded && !isOTP && !isCredentials { openExternal() }
    }

    func reopen() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func submitCallback(_ callback: String? = nil) {
        let value = callback ?? pastedCallback
        pastedCallback = ""
        guard let sessionID, let challengeID, !isOTP, !isCredentials, !submitted else { return }
        guard value.utf8.count < maximumMessageBytes - 4096, value.hasPrefix("globalprotectcallback:"), value.count > 22 else {
            error = "That link is not a valid GlobalProtect sign-in callback."
            return
        }
        submitted = true
        message = "Checking your sign-in…"
        onCallback?(sessionID, challengeID, value)
    }

    func submitOTP() {
        let value = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        otp = ""
        guard let sessionID, let challengeID, isOTP, !submitted else { return }
        guard !value.isEmpty, value.utf8.count <= 1024 else { error = "Enter a verification code."; return }
        submitted = true
        message = "Checking your code…"
        onOTP?(sessionID, challengeID, value)
    }

    func complete(challengeID: String?) {
        guard challengeID == self.challengeID else { return }
        finish()
    }

    func submitCredentials() {
        guard let sessionID, let challengeID, isCredentials, !submitted else { return }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, account.utf8.count <= 1024,
              !account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !password.isEmpty, password.utf8.count <= 4096 else {
            error = "Enter your username and password."
            return
        }
        let secret = password
        password = ""
        username = ""
        submitted = true
        message = "Checking your sign-in…"
        onCredentials?(sessionID, challengeID, account, secret)
    }

    func finish() {
        sessionID = nil
        challengeID = nil
        pastedCallback = ""
        otp = ""
        username = ""
        password = ""
        launchURL = nil
        closeOwnedWindows()
    }

    func cancel() { finish(); onCancel?() }

    func openExternal() {
        guard let url = launchURL, let sessionID, let challengeID, !submitted else { return }
        if browser == .systemDefault {
            guard webSession == nil else { return }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "globalprotectcallback") { @Sendable [weak self] url, _ in
                Task { @MainActor in
                    guard let self, self.sessionID == sessionID, self.challengeID == challengeID else { return }
                    self.webSession = nil
                    if let url { self.submitCallback(url.absoluteString) }
                    else { self.error = "Browser sign-in was closed. Reopen the page or cancel this attempt." }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            webSession = session
            if !session.start() { webSession = nil; error = "The browser could not start sign-in." }
            message = "Finish signing in through your default browser. macOS may use Safari if needed."
        } else {
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID) else {
                error = "Your chosen browser is unavailable. Cancel and choose an installed browser."
                return
            }
            guard let callback = URL(string: "globalprotectcallback:setup"),
                  let handler = NSWorkspace.shared.urlForApplication(toOpen: callback),
                  Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                callbackHandlerRequired = true
                error = "GPBar must handle sign-in links for this browser. This changes the callback handler used by other VPN clients."
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { @Sendable [weak self] _, error in
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.sessionID == sessionID, self.challengeID == challengeID else { return }
                    if failed { self.error = "Your browser could not open the sign-in page." }
                }
            }
            message = "Finish signing in in your chosen browser. You can close its sign-in tab after connecting."
        }
    }

    func useCallbackHandler() {
        let attempt = challengeID
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "globalprotectcallback") { @Sendable [weak self] error in
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.challengeID == attempt else { return }
                self.callbackHandlerRequired = failed
                if failed { self.error = "The sign-in link handler could not be changed." }
                else { self.error = nil; self.openExternal() }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? ASPresentationAnchor()
    }

    private func showWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: isEmbedded ? 700 : 360),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sign in to your VPN"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SignInView(coordinator: self))
        window.center()
        self.window = window
        reopen()
    }

    private func configure(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    private func closeOwnedWindows() {
        closing = true
        webSession?.cancel()
        webSession = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        for popup in popupWindows { popup.close() }
        popupWindows.removeAll()
        window?.close()
        window = nil
        closing = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing, let closed = notification.object as? NSWindow else { return }
        if closed === window { cancel() }
        else if let index = popupWindows.firstIndex(where: { $0 === closed }) {
            popupWindows.remove(at: index)
            if let webView = closed.contentView as? WKWebView {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
            }
            cancel()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard sessionID != nil, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme?.lowercased() == "globalprotectcallback" {
            decisionHandler(.cancel)
            submitCallback(url.absoluteString)
            return
        }
        if url.scheme == "https" || url == launchURL || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            error = "This sign-in page requested an unsupported address. Try an external browser."
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === self.webView { hostname = webView.url?.host ?? "" }
        if let popup = popupWindows.first(where: { $0.contentView === webView }) {
            popup.title = webView.url?.host ?? "VPN sign-in"
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        self.error = "The sign-in page could not load. Cancel and try again, or choose an external browser."
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url?.scheme?.lowercased() == "globalprotectcallback" {
            submitCallback(navigationAction.request.url?.absoluteString)
            return nil
        }
        guard sessionID != nil else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "VPN sign-in"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = popup
        window.center()
        popupWindows.append(window)
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = popupWindows.firstIndex(where: { $0.contentView === webView }) else { return }
        popupWindows.remove(at: index).close()
    }
}
