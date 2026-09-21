import SwiftUI

struct AboutView: View {
    @State private var selectedLicense = LibraryLicense.openConnect

    private var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPBar").font(.title2).bold()
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                    if let url = URL(string: "https://github.com/beeltec") {
                        Link("beeltec on GitHub", destination: url)
                    }
                }
            }
            Divider()
            Text("Third-party licenses").font(.headline)
            Text("OpenProtect is available under either MIT or Apache 2.0.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("License", selection: $selectedLicense) {
                ForEach(LibraryLicense.allCases) { license in
                    Text(license.rawValue).tag(license)
                }
            }
            ScrollView {
                Text(selectedLicense.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .id(selectedLicense)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 480)
    }
}

private enum LibraryLicense: String, CaseIterable, Identifiable {
    case openConnect = "OpenConnect — LGPL 2.1"
    case openProtectMIT = "OpenProtect — MIT"
    case openProtectApache = "OpenProtect — Apache 2.0"

    case sparkle = "Sparkle — MIT and bundled notices"
    case vpncScript = "vpnc-script — GPL 2.0 or later"

    var id: Self { self }

    private var filename: String {
        switch self {
        case .openConnect: "OpenConnect-LGPL-2.1"
        case .openProtectMIT: "OpenProtect-MIT"
        case .openProtectApache: "OpenProtect-Apache-2.0"
        case .sparkle: "Sparkle"
        case .vpncScript: "vpnc-script-GPL-2.0"
        }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "txt", subdirectory: "Licenses"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "The license text could not be loaded. Please reinstall GPBar.")
        }
        return text
    }
}
