import SwiftUI

/// The one status palette, used by agent tabs and folder rows alike.
extension AgentStatus {
    var color: Color {
        switch self {
        case .running: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .exited: return .red
        case .unknown: return .gray.opacity(0.5)
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting for input"
        case .idle: return "Idle shell"
        case .exited: return "Session exited"
        case .unknown: return "Status unknown"
        }
    }
}

/// Status as colour *and* shape, so it reads without colour vision:
/// running = solid dot, waiting = dot with a halo, idle = hollow ring,
/// exited = ×, unknown = dashed ring.
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
            Circle().fill(status.color)
        case .waiting:
            Circle().fill(status.color)
                .overlay { Circle().stroke(status.color.opacity(0.5), lineWidth: 2).frame(width: size + 4, height: size + 4) }
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
