import SwiftUI

@main struct GPClientApp: App {
    @State private var model = ConnectionModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ConnectionPanel(model: model)
        } label: {
            MenuBarLabel(model: model, appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Window("GPClient", id: "connection") {
            ConnectionSettings(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 480, height: 610)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ConnectionCommands()
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 480, height: 340)
    }
}

private struct MenuBarLabel: View {
    let model: ConnectionModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("GPClient, \(model.phase.rawValue), \(model.preferences.title)")
            .task {
                appDelegate.model = model
                model.refresh()
                appDelegate.openConnection = {
                    openWindow(id: "connection")
                    NSApp.activate()
                }
                if model.preferences.portal.isEmpty { appDelegate.openConnection?() }
            }
    }

    private var symbol: String {
        if model.cleanupRequired || model.phase == .failed || model.phase == .unknown { return "exclamationmark.triangle" }
        if model.phase == .connected { return "checkmark.circle" }
        if model.phase.isActive { return "arrow.triangle.2.circlepath" }
        return "network"
    }
}

private struct ConnectionCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Connection settings…") {
                openWindow(id: "connection")
                NSApp.activate()
            }
            .keyboardShortcut(",")
        }
    }
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    var openConnection: (() -> Void)?
    var model: ConnectionModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !model.preferences.addressDraft.isEmpty { model.preferences.saveAddress() }
        guard model.settingsLocked else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Disconnect and quit GPClient?"
        alert.informativeText = "Your VPN session will stop before GPClient quits."
        alert.addButton(withTitle: "Disconnect and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.disconnectAndQuit()
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model?.authentication.submitCallback(url.absoluteString) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openConnection?()
        return true
    }
}
