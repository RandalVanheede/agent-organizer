import SwiftUI

/// The one status palette, used by agent tabs and folder rows alike.
extension AgentStatus {
    var color: Color {
        switch self {
        // Not blue: that's the system accent, i.e. selection / focus.
        case .running: return .teal
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .gray
        case .exited: return .red
        case .unknown: return .gray.opacity(0.5)
        }
    }

    var label: String {
        switch self {
        // Same words as the Agents panel groups.
        case .running: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle shell"
        case .exited: return "Session exited"
        case .unknown: return "Status unknown"
        }
    }
}

/// Status as colour *and* shape, so it reads without colour vision:
/// running = spinning arc, needs you = !, finished = ✓,
/// idle = hollow ring, exited = ×, unknown = dashed ring.
struct StatusOrb: View {
    let status: AgentStatus
    var size: CGFloat = 7

    var body: some View {
        shape
            .frame(width: size, height: size)
            .help(status.label)
            .accessibilityElement()
            .accessibilityLabel(status.label)
    }

    @ViewBuilder private var shape: some View {
        switch status {
        case .running:
            Spinner(color: status.color, size: size)
        case .waiting:
            Image(systemName: "exclamationmark")
                .font(.system(size: size + 2, weight: .heavy))
                .foregroundStyle(status.color)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: size + 1, weight: .heavy))
                .foregroundStyle(status.color)
        case .idle:
            Circle().strokeBorder(status.color, lineWidth: 1.5)
        case .exited:
            Image(systemName: "xmark")
                .font(.system(size: size + 1, weight: .heavy))
                .foregroundStyle(status.color)
        case .unknown:
            Circle().strokeBorder(status.color, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
        }
    }
}

/// Small rotating arc. Slow (1.2 s/turn) so it reads as "working" without
/// pulling the eye; static with Reduce Motion.
private struct Spinner: View {
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size + 2, height: size + 2)
            // Scoped to the rotation: a plain `.animation(value:)` also repeats the first layout move forever.
            .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false)) {
                $0.rotationEffect(.degrees(spinning ? 360 : 0))
            }
            .onAppear { spinning = true }
    }
}

extension View {
    /// Faint status fill behind a sidebar row (Colours / Both style). Done is
    /// left plain here: it's where most agents rest, and a list full of green
    /// drowns out "needs you" (the Agents panel still tints it). Idle, unknown
    /// and nil stay plain; the native selection draws over it.
    func statusTint(_ status: AgentStatus?, style: SidebarStatusStyle) -> some View {
        let tinted: AgentStatus? = switch status {
        case .running, .waiting, .exited: status
        default: nil
        }
        return listRowBackground(
            (style.showsColor ? tinted : nil).map {
                RoundedRectangle(cornerRadius: 5).fill($0.color.opacity(0.15)).padding(.horizontal, 10)
            }
        )
    }
}
