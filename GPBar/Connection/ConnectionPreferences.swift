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

@MainActor @Observable final class ConnectionPreferences: Identifiable {
    let id: UUID
    let authenticationNamespace: UUID?
    private let prefix: String
    private let readOnly: Bool
    @ObservationIgnored var canChangeAddress: (() -> Bool)?
    @ObservationIgnored var onAddressChange: ((String) -> Void)?
    private let defaults: UserDefaults
    private(set) var portal: String
    var addressDraft: String
    var addressError: String?
    var displayName: String {
        didSet { save(displayName, "displayName") }
    }
    var authenticationMethod: AuthenticationMethod {
        didSet { save(authenticationMethod.rawValue, "authenticationMethod") }
    }
    var browser: BrowserChoice {
        didSet { save(browser.rawValue, "browser") }
    }
    var browserID: String {
        didSet { save(browserID, "browserID") }
    }
    var reconnect: Bool {
        didSet { save(reconnect, "reconnect") }
    }
    var rememberAuthentication: Bool {
        didSet { save(rememberAuthentication, "rememberAuthentication") }
    }
    var pendingAuthenticationRemovals: [String] {
        didSet { save(pendingAuthenticationRemovals, "pendingAuthenticationRemovals") }
    }
    var certificateReference: Data? {
        didSet { save(certificateReference, "certificateReference") }
    }
    var certificateName: String {
        didSet { save(certificateName, "certificateName") }
    }
    var certificateID: String {
        didSet { save(certificateID, "certificateID") }
    }
    var certificateTokenID: String? {
        didSet { save(certificateTokenID, "certificateTokenID") }
    }
    var certificateOnly: Bool {
        didSet { save(certificateOnly, "certificateOnly") }
    }
    var certificateUsername: String {
        didSet { save(certificateUsername, "certificateUsername") }
    }

    init(defaults: UserDefaults = .standard, id: UUID = UUID(), legacy: Bool = true, readOnly: Bool = false) {
        self.defaults = defaults
        self.id = id
        self.readOnly = readOnly
        authenticationNamespace = legacy ? nil : id
        prefix = legacy ? "connection." : "profile.\(id.uuidString)."
        defaults.register(defaults: [prefix + "reconnect": true])
        let savedPortal = defaults.string(forKey: prefix + "portal").flatMap(PortalAddress.normalize) ?? ""
        portal = savedPortal
        addressDraft = savedPortal
        displayName = defaults.string(forKey: prefix + "displayName") ?? ""
        browser = BrowserChoice(rawValue: defaults.string(forKey: prefix + "browser") ?? "") ?? .inApp
        browserID = defaults.string(forKey: prefix + "browserID") ?? ""
        reconnect = defaults.bool(forKey: prefix + "reconnect")
        rememberAuthentication = defaults.bool(forKey: prefix + "rememberAuthentication")
        pendingAuthenticationRemovals = defaults.stringArray(forKey: prefix + "pendingAuthenticationRemovals") ?? []
        let savedCertificate = defaults.data(forKey: prefix + "certificateReference")
        certificateReference = savedCertificate
        certificateName = defaults.string(forKey: prefix + "certificateName") ?? ""
        certificateID = defaults.string(forKey: prefix + "certificateID") ?? ""
        certificateTokenID = defaults.string(forKey: prefix + "certificateTokenID")
        certificateOnly = defaults.bool(forKey: prefix + "certificateOnly")
        certificateUsername = defaults.string(forKey: prefix + "certificateUsername") ?? ""
        authenticationMethod = AuthenticationMethod(rawValue: defaults.string(forKey: prefix + "authenticationMethod") ?? "")
            ?? (savedCertificate == nil ? .automatic : .certificate)
        save(authenticationMethod.rawValue, "authenticationMethod")
    }

    var kerberosFallbackUntil: UInt64 {
        let until = defaults.double(forKey: prefix + "kerberosFallbackUntil")
        let now = Date().timeIntervalSince1970
        guard until > now, until <= now + 86400,
              defaults.string(forKey: prefix + "kerberosPolicyPortal") == portal else { return 0 }
        return UInt64(until)
    }

    func saveKerberosPolicy(_ update: KerberosPolicyUpdate) {
        guard update.portal == portal else { return }
        save(portal, "kerberosPolicyPortal")
        save(Double(update.fallbackUntil), "kerberosFallbackUntil")
    }

    var title: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (URL(string: portal)?.host ?? "New connection") : name
    }

    @discardableResult func saveAddress() -> Bool {
        guard let normalized = PortalAddress.normalize(addressDraft) else {
            addressError = "Enter a hostname or HTTPS address without a path, password, or query."
            return false
        }
        guard !readOnly else { return false }
        let changed = portal != normalized
        guard !changed || canChangeAddress?() != false else {
            addressError = "Disconnect and disable macOS login SSO for this portal before changing its address."
            return false
        }
        let previousPortal = portal
        if changed && !previousPortal.isEmpty && !pendingAuthenticationRemovals.contains(previousPortal) {
            pendingAuthenticationRemovals.append(previousPortal)
        }
        portal = normalized
        addressDraft = normalized
        addressError = nil
        save(normalized, "portal")
        if changed {
            defaults.removeObject(forKey: prefix + "kerberosFallbackUntil")
            clearCertificate()
            onAddressChange?(previousPortal)
        }
        return true
    }

    private func save(_ value: Any?, _ key: String) {
        guard !readOnly else { return }
        defaults.set(value, forKey: prefix + key)
    }

    func removeStoredValues() {
        guard !readOnly else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
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
