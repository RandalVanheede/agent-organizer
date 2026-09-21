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

struct StatusOrb: View {
    let status: AgentStatus
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay {
                if status == .waiting {
                    Circle().stroke(status.color.opacity(0.5), lineWidth: 2).frame(width: size + 4, height: size + 4)
                }
            }
            .help(status.label)
    }
}
