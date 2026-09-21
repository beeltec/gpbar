import AppKit
import Combine
import Sparkle

@MainActor final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var unavailableReason: String?
    private var updater: SPUUpdater?
    private let model: ConnectionModel
    private let driver: UpdateUserDriver

    init(model: ConnectionModel) {
        self.model = model
        driver = UpdateUserDriver(model: model)
        super.init()
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), Self.validFeedURL(url) else {
            unavailableReason = "Updates are not configured for this build."
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        do { try updater.start() }
        catch { unavailableReason = "The updater could not start. Reopen GPBar and try again." }
    }

    private static func validFeedURL(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil else { return false }
        #if DEBUG
        if url.scheme == "http", url.host == "127.0.0.1" { return true }
        #endif
        return url.scheme == "https"
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate()
        updater?.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if !driver.installationPending {
            model.finishUpdateAttempt()
        }
    }
}

@MainActor private final class UpdateUserDriver: SPUStandardUserDriver {
    private let model: ConnectionModel
    var installationPending = false

    init(model: ConnectionModel) {
        self.model = model
        super.init(hostBundle: .main, delegate: nil)
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if state.stage == .installing {
            installationPending = true
            if !model.updating {
                Task { @MainActor in
                    guard await model.prepareForUpdate() else {
                        model.holdForPendingUpdate()
                        reply(.skip)
                        let alert = NSAlert()
                        alert.messageText = "An earlier update could not resume safely"
                        alert.informativeText = "GPBar requested cancellation. Disconnect any VPN session, then restart GPBar before connecting again."
                        alert.runModal()
                        return
                    }
                    self.showUpdateFound(with: appcastItem, state: state, reply: reply)
                }
                return
            }
        }
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            guard let self, choice == .install else { reply(choice); return }
            Task { @MainActor in
                let prepared = self.model.updating ? true : await self.model.prepareForUpdate()
                guard prepared else {
                    reply(.dismiss)
                    let alert = NSAlert()
                    alert.messageText = "The VPN helper is not ready to update"
                    alert.informativeText = "Disconnect the VPN and resolve any helper or cleanup errors. Then check for updates again."
                    alert.runModal()
                    return
                }
                reply(.install)
            }
        }
    }

    override func showDownloadDidStartExtractingUpdate() {
        // An installer connection error does not prove that a prepared update was cancelled.
        installationPending = true
        super.showDownloadDidStartExtractingUpdate()
    }
}
