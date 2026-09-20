import SwiftUI

struct ConnectionPath: View {
    var phase: ConnectionPhase
    private var connected: Bool { phase == .connected }
    private var busy: Bool { [.preparing, .authenticating, .connecting, .reconnecting, .disconnecting].contains(phase) }
    var body: some View {
        HStack(spacing: 12) {
            endpoint("This Mac", symbol: "laptopcomputer")
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 1))
                    }
                    .stroke(connected ? Color("Connected") : .secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: connected ? [] : [4, 5]))
                }
                .frame(height: 2)
                Text(connected ? "CONNECTED" : (busy ? "IN PROGRESS" : "OFFLINE"))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)
            endpoint("Gateway", symbol: "network")
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "This Mac is connected to the VPN gateway" : "VPN connection: \(phase.rawValue)")
    }

    private func endpoint(_ title: LocalizedStringKey, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 48, height: 40)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
