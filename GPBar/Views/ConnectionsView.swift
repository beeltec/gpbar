import SwiftUI

struct ConnectionsView: View {
    @Bindable var model: ConnectionModel
    @Environment(\.openWindow) private var openWindow
    @State private var removingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.profiles.storageError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            } else if model.profileControlsLocked {
                Label("Stop the connection and resolve any helper or recovery work before changing profiles.", systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: Binding<UUID?>(
                        get: { model.preferences.id },
                        set: { if let id = $0 { model.selectProfile(id) } }
                    )) {
                        ForEach(model.profiles.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.profiles.label(for: profile)).fontWeight(.medium)
                                    .lineLimit(2)
                                Text(profile.portal.isEmpty ? "Add a portal address" : profile.portal)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 5)
                            .tag(profile.id)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .listStyle(.sidebar)
                    .disabled(model.profileControlsLocked)
                    Divider()
                    HStack {
                        Button { model.addProfile() } label: { Image(systemName: "plus") }
                            .help("Add connection").accessibilityLabel("Add connection")
                        Button { removingID = model.preferences.id } label: { Image(systemName: "minus") }
                            .help("Remove connection").accessibilityLabel("Remove connection")
                            .disabled(model.portalEnrolledForLoginSSO)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                    .disabled(model.profileControlsLocked)
                }
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                ConnectionSettings(model: model)
                    .id(model.preferences.id)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .toolbar {
            Button { openWindow(id: "settings") } label: { Label("Settings", systemImage: "gearshape") }
                .help("General settings")
        }
        .confirmationDialog("Remove \(model.profiles.label(for: model.preferences))?",
                            isPresented: Binding(get: { removingID != nil }, set: { if !$0 { removingID = nil } }),
                            titleVisibility: .visible) {
            Button("Remove connection", role: .destructive) {
                if let id = removingID { model.removeProfile(id) }
                removingID = nil
            }
        } message: {
            Text("This removes the connection and its saved sign-in from this Mac. Keychain certificates and browser accounts stay in place.")
        }
        .onAppear { model.refresh() }
    }
}
