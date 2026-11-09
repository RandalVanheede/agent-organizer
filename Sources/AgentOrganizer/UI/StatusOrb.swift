import SwiftUI

/// The one status palette, used by agent tabs and folder rows alike.
extension AgentStatus {
    var color: Color {
        switch self {
        case .running: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .gray
        case .exited: return .red
        case .unknown: return .gray.opacity(0.5)
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Needs your input"
        case .done: return "Finished"
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
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
