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
    @ObservationIgnored var onAddressChange: (() -> Void)?
    private let defaults = UserDefaults.standard
    private(set) var portal: String
    var addressDraft: String
    var addressError: String?
    var displayName: String {
        didSet { defaults.set(displayName, forKey: "connection.displayName") }
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

    init() {
        defaults.register(defaults: ["connection.reconnect": true])
        let savedPortal = defaults.string(forKey: "connection.portal").flatMap(PortalAddress.normalize) ?? ""
        portal = savedPortal
        addressDraft = savedPortal
        displayName = defaults.string(forKey: "connection.displayName") ?? ""
        browser = BrowserChoice(rawValue: defaults.string(forKey: "connection.browser") ?? "") ?? .inApp
        browserID = defaults.string(forKey: "connection.browserID") ?? ""
        reconnect = defaults.bool(forKey: "connection.reconnect")
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
        portal = normalized
        addressDraft = normalized
        addressError = nil
        defaults.set(normalized, forKey: "connection.portal")
        if changed { onAddressChange?() }
        return true
    }
}
