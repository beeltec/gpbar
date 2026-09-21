import SwiftUI

@main struct GPBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: ConnectionModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            ConnectionPanel(model: model)
        } label: {
            MenuBarLabel(model: model, appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Window("Edit Connection", id: "connection") {
            ConnectionSettings(model: model, updates: appDelegate.updates)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 480, height: 610)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ConnectionCommands(updates: appDelegate.updates)
        }

        Window("About GPBar", id: "about") {
            AboutView()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 560, height: 580)

        #if DEBUG
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 480, height: 340)
        #endif
    }
}

private struct MenuBarLabel: View {
    let model: ConnectionModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarStatusIcon(phase: model.phase, cleanupRequired: model.cleanupRequired, checkingHelper: model.checkingHelper)
            .accessibilityLabel("GPBar, \(model.phase.rawValue), \(model.preferences.title)")
            .task {
                appDelegate.openConnection = {
                    openWindow(id: "connection")
                    NSApp.activate()
                }
                if model.preferences.portal.isEmpty { appDelegate.openConnection?() }
            }
    }
}

private struct ConnectionCommands: Commands {
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About GPBar") {
                openWindow(id: "about")
                NSApp.activate()
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
        CommandGroup(after: .appSettings) {
            Button("Edit Connection…") {
                openWindow(id: "connection")
                NSApp.activate()
            }
            .keyboardShortcut(",")
        }
    }
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    var openConnection: (() -> Void)?
    let model = ConnectionModel()
    lazy var updates = UpdateController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startHelper()
        _ = updates
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !model.preferences.addressDraft.isEmpty { model.preferences.saveAddress() }
        guard model.settingsLocked else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Disconnect and quit GPBar?"
        alert.informativeText = "Your VPN session will stop before GPBar quits."
        alert.addButton(withTitle: "Disconnect and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.disconnectAndQuit()
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model.authentication.submitCallback(url.absoluteString) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openConnection?()
        return true
    }
}
