import Foundation
import Observation

@MainActor @Observable final class ConnectionProfiles {
    private struct Manifest: Codable {
        var version = 1
        var ids: [UUID]
        var selectedID: UUID
        var legacyID: UUID?
        var retiredIDs: [UUID]
    }

    struct Session: Codable {
        let id: String
        let profileID: UUID
    }

    private let defaults: UserDefaults
    private var manifest: Manifest
    private(set) var profiles: [ConnectionPreferences]
    private(set) var retired: [ConnectionPreferences]
    private(set) var selected: ConnectionPreferences
    private(set) var storageError: String?
    var session: Session? {
        didSet {
            guard storageError == nil else { return }
            defaults.set(session.flatMap { try? JSONEncoder().encode($0) }, forKey: "profiles.session")
        }
    }
    var loginSSOPortal: String? {
        didSet { defaults.set(loginSSOPortal, forKey: "profiles.loginSSOPortal") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let manifestKey = "profiles.manifest"
        let initialID = UUID()
        var loaded = Manifest(ids: [initialID], selectedID: initialID, legacyID: initialID, retiredIDs: [])
        var invalid = false
        if let stored = defaults.object(forKey: manifestKey) {
            if let data = stored as? Data,
               let decoded = try? JSONDecoder().decode(Manifest.self, from: data), decoded.version == 1,
               !decoded.ids.isEmpty, decoded.ids.contains(decoded.selectedID),
               Set(decoded.ids + decoded.retiredIDs).count == decoded.ids.count + decoded.retiredIDs.count,
               decoded.legacyID.map({ (decoded.ids + decoded.retiredIDs).contains($0) }) != false {
                loaded = decoded
            } else { invalid = true }
        }
        manifest = loaded
        let active = loaded.ids.map { ConnectionPreferences(defaults: defaults, id: $0, legacy: $0 == loaded.legacyID, readOnly: invalid) }
        profiles = active
        retired = loaded.retiredIDs.map { ConnectionPreferences(defaults: defaults, id: $0, legacy: $0 == loaded.legacyID) }
        selected = active.first(where: { $0.id == loaded.selectedID }) ?? active[0]
        if let stored = defaults.object(forKey: "profiles.session") {
            if let data = stored as? Data,
               let decoded = try? JSONDecoder().decode(Session.self, from: data), UUID(uuidString: decoded.id) != nil {
                session = decoded
            } else { invalid = true }
        }
        loginSSOPortal = defaults.string(forKey: "profiles.loginSSOPortal")
        if invalid {
            storageError = "Saved profiles could not be read. Restore your preferences or open them with a compatible GPBar version."
        } else { persist() }
    }

    func label(for profile: ConnectionPreferences) -> String {
        guard profiles.filter({ $0.title == profile.title }).count > 1 else { return profile.title }
        let others = profiles.filter { $0.id != profile.id }
        var length = 8
        while others.contains(where: { $0.id.uuidString.prefix(length) == profile.id.uuidString.prefix(length) }) { length += 1 }
        return "\(profile.title) · \(profile.id.uuidString.prefix(length))"
    }

    @discardableResult func select(_ id: UUID) -> Bool {
        guard storageError == nil, let profile = profiles.first(where: { $0.id == id }) else { return false }
        selected = profile
        manifest.selectedID = id
        persist()
        return true
    }

    @discardableResult func add() -> ConnectionPreferences? {
        guard storageError == nil else { return nil }
        let profile = ConnectionPreferences(defaults: defaults, id: UUID(), legacy: false)
        profiles.append(profile)
        manifest.ids.append(profile.id)
        selected = profile
        manifest.selectedID = profile.id
        persist()
        return profile
    }

    @discardableResult func removeSelected() -> ConnectionPreferences? {
        guard storageError == nil, let index = profiles.firstIndex(where: { $0.id == selected.id }) else { return nil }
        let removed = selected
        if !removed.portal.isEmpty && !removed.pendingAuthenticationRemovals.contains(removed.portal) {
            removed.pendingAuthenticationRemovals.append(removed.portal)
        }
        retired.append(removed)
        manifest.retiredIDs.append(removed.id)
        profiles.remove(at: index)
        manifest.ids.removeAll { $0 == removed.id }
        if profiles.isEmpty {
            let replacement = ConnectionPreferences(defaults: defaults, id: UUID(), legacy: false)
            profiles.append(replacement)
            manifest.ids.append(replacement.id)
        }
        selected = profiles[min(index, profiles.count - 1)]
        manifest.selectedID = selected.id
        persist()
        return removed
    }

    func finishRemoval(_ profile: ConnectionPreferences) {
        guard storageError == nil, profile.pendingAuthenticationRemovals.isEmpty,
              retired.contains(where: { $0.id == profile.id }) else { return }
        profile.removeStoredValues()
        retired.removeAll { $0.id == profile.id }
        manifest.retiredIDs.removeAll { $0 == profile.id }
        if manifest.legacyID == profile.id { manifest.legacyID = nil }
        persist()
    }

    func saveKerberosPolicy(_ update: KerberosPolicyUpdate) {
        for profile in profiles where profile.portal == update.portal { profile.saveKerberosPolicy(update) }
    }

    private func persist() {
        guard storageError == nil, let data = try? JSONEncoder().encode(manifest) else { return }
        defaults.set(data, forKey: "profiles.manifest")
    }
}
