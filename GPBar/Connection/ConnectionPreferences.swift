import Foundation
import Observation
import Darwin

enum BrowserChoice: String, CaseIterable, Identifiable {
    case inApp, systemDefault, specific
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inApp: "In-app browser"
        case .systemDefault: "Default browser"
        case .specific: "Choose browser…"
        }
    }
}

@MainActor @Observable final class ConnectionPreferences {
    @ObservationIgnored var onAddressChange: ((String) -> Void)?
    private let defaults = UserDefaults.standard
    private(set) var portal: String
    var addressDraft: String
    var addressError: String?
    var displayName: String {
        didSet { defaults.set(displayName, forKey: "connection.displayName") }
    }
    var authenticationMethod: AuthenticationMethod {
        didSet { defaults.set(authenticationMethod.rawValue, forKey: "connection.authenticationMethod") }
    }
    var browser: BrowserChoice {
        didSet { defaults.set(browser.rawValue, forKey: "connection.browser") }
    }
    var browserID: String {
        didSet { defaults.set(browserID, forKey: "connection.browserID") }
    }
    var reconnect: Bool {
        didSet { defaults.set(reconnect, forKey: "connection.reconnect") }
    }
    var rememberAuthentication: Bool {
        didSet { defaults.set(rememberAuthentication, forKey: "connection.rememberAuthentication") }
    }
    var pendingAuthenticationRemovals: [String] {
        didSet { defaults.set(pendingAuthenticationRemovals, forKey: "connection.pendingAuthenticationRemovals") }
    }
    var certificateReference: Data? {
        didSet { defaults.set(certificateReference, forKey: "connection.certificateReference") }
    }
    var certificateName: String {
        didSet { defaults.set(certificateName, forKey: "connection.certificateName") }
    }
    var certificateID: String {
        didSet { defaults.set(certificateID, forKey: "connection.certificateID") }
    }
    var certificateTokenID: String? {
        didSet { defaults.set(certificateTokenID, forKey: "connection.certificateTokenID") }
    }
    var certificateOnly: Bool {
        didSet { defaults.set(certificateOnly, forKey: "connection.certificateOnly") }
    }
    var certificateUsername: String {
        didSet { defaults.set(certificateUsername, forKey: "connection.certificateUsername") }
    }

    init() {
        defaults.register(defaults: ["connection.reconnect": true])
        let savedPortal = defaults.string(forKey: "connection.portal").flatMap(PortalAddress.normalize) ?? ""
        portal = savedPortal
        addressDraft = savedPortal
        displayName = defaults.string(forKey: "connection.displayName") ?? ""
        browser = BrowserChoice(rawValue: defaults.string(forKey: "connection.browser") ?? "") ?? .inApp
        browserID = defaults.string(forKey: "connection.browserID") ?? ""
        reconnect = defaults.bool(forKey: "connection.reconnect")
        rememberAuthentication = defaults.bool(forKey: "connection.rememberAuthentication")
        pendingAuthenticationRemovals = defaults.stringArray(forKey: "connection.pendingAuthenticationRemovals") ?? []
        let savedCertificate = defaults.data(forKey: "connection.certificateReference")
        certificateReference = savedCertificate
        certificateName = defaults.string(forKey: "connection.certificateName") ?? ""
        certificateID = defaults.string(forKey: "connection.certificateID") ?? ""
        certificateTokenID = defaults.string(forKey: "connection.certificateTokenID")
        certificateOnly = defaults.bool(forKey: "connection.certificateOnly")
        certificateUsername = defaults.string(forKey: "connection.certificateUsername") ?? ""
        authenticationMethod = AuthenticationMethod(rawValue: defaults.string(forKey: "connection.authenticationMethod") ?? "")
            ?? (savedCertificate == nil ? .automatic : .certificate)
        defaults.set(authenticationMethod.rawValue, forKey: "connection.authenticationMethod")
    }

    var kerberosFallbackUntil: UInt64 {
        let received = defaults.double(forKey: "connection.kerberosPolicyReceived")
        let age = Date().timeIntervalSince1970 - received
        guard age >= 0 && age < 86400 && defaults.string(forKey: "connection.kerberosPolicyPortal") == portal,
              defaults.bool(forKey: "connection.kerberosFallback") else { return 0 }
        return UInt64(received + 86400)
    }

    func saveKerberosPolicy(_ allowed: Bool) {
        defaults.set(portal, forKey: "connection.kerberosPolicyPortal")
        defaults.set(allowed, forKey: "connection.kerberosFallback")
        defaults.set(Date().timeIntervalSince1970, forKey: "connection.kerberosPolicyReceived")
    }

    var title: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (URL(string: portal)?.host ?? "GPBar") : name
    }

    @discardableResult func saveAddress() -> Bool {
        guard let normalized = PortalAddress.normalize(addressDraft) else {
            addressError = "Enter a hostname or HTTPS address without a path, password, or query."
            return false
        }
        let changed = portal != normalized
        let previousPortal = portal
        portal = normalized
        addressDraft = normalized
        addressError = nil
        defaults.set(normalized, forKey: "connection.portal")
        if changed { saveKerberosPolicy(false); clearCertificate(); onAddressChange?(previousPortal) }
        return true
    }

    func clearCertificate() {
        certificateReference = nil
        certificateName = ""
        certificateID = ""
        certificateTokenID = nil
        certificateOnly = false
        certificateUsername = ""
    }
}
