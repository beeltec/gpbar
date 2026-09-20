import SwiftUI

struct MenuBarStatusIcon: View {
    let phase: ConnectionPhase
    let cleanupRequired: Bool
    let checkingHelper: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationFrame = 0

    private var state: GlobeState {
        if cleanupRequired || phase == .failed { return .error }
        switch phase {
        case .connected: return .connected
        case .disconnected: return .disconnected
        case .unknown: return checkingHelper ? .working : .error
        default: return .working
        }
    }

    private var animates: Bool { state == .working && !reduceMotion }

    var body: some View {
        Image(nsImage: state.image(frame: reduceMotion ? -1 : animationFrame))
            .renderingMode(.original)
            .task(id: animates) {
                animationFrame = 0
                guard animates else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    animationFrame = (animationFrame + 1) % 3
                }
            }
    }
}

private enum GlobeState {
    case disconnected, working, error, connected

    func image(frame: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { bounds in
            let color = self == .connected ? NSColor.white : NSColor(white: 0.6, alpha: 1)
            let globe = NSRect(x: bounds.midX - 9.5, y: bounds.midY - 9.5, width: 19, height: 19)
            let lines = NSBezierPath(ovalIn: globe)
            lines.appendOval(in: NSRect(x: globe.midX - 4, y: globe.minY, width: 8, height: globe.height))
            lines.move(to: NSPoint(x: globe.minX, y: globe.midY))
            lines.line(to: NSPoint(x: globe.maxX, y: globe.midY))
            lines.move(to: NSPoint(x: globe.minX + 2, y: globe.midY - 5))
            lines.line(to: NSPoint(x: globe.maxX - 2, y: globe.midY - 5))
            lines.move(to: NSPoint(x: globe.minX + 2, y: globe.midY + 5))
            lines.line(to: NSPoint(x: globe.maxX - 2, y: globe.midY + 5))
            if self == .connected {
                NSColor(white: 0.15, alpha: 0.8).setStroke()
                lines.lineWidth = 2.4
                lines.stroke()
            }
            lines.lineWidth = 1.2
            color.setStroke()
            lines.stroke()

            guard self != .disconnected else { return true }
            let badge = self == .working
                ? NSRect(x: 13, y: 13, width: 15, height: 9)
                : NSRect(x: 15, y: 12, width: 12, height: 10)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            color.setStroke()
            color.setFill()
            let mark = NSBezierPath()
            mark.lineWidth = 1.6
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            switch self {
            case .working:
                mark.move(to: NSPoint(x: 16, y: 20))
                mark.line(to: NSPoint(x: 14, y: 17.5))
                mark.line(to: NSPoint(x: 16, y: 15))
                mark.move(to: NSPoint(x: 25, y: 20))
                mark.line(to: NSPoint(x: 27, y: 17.5))
                mark.line(to: NSPoint(x: 25, y: 15))
                mark.lineWidth = 1
                mark.stroke()
                for dot in 0..<3 {
                    color.withAlphaComponent(frame == -1 || dot == frame ? 1 : 0.3).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 18 + Double(dot) * 2, y: 17, width: 1.3, height: 1.3)).fill()
                }
            case .error:
                mark.move(to: NSPoint(x: 21, y: 20))
                mark.line(to: NSPoint(x: 21, y: 16.5))
                mark.stroke()
                NSBezierPath(ovalIn: NSRect(x: 20.15, y: 13.5, width: 1.7, height: 1.7)).fill()
            case .connected:
                mark.move(to: NSPoint(x: 17.5, y: 16.5))
                mark.line(to: NSPoint(x: 20, y: 14))
                mark.line(to: NSPoint(x: 25, y: 20))
                NSColor(white: 0.15, alpha: 0.8).setStroke()
                mark.lineWidth = 2.8
                mark.stroke()
                color.setStroke()
                mark.lineWidth = 1.6
                mark.stroke()
            case .disconnected: break
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
