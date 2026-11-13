import SwiftUI

/// One flat surface for sidebar, tab bar, status bar *and* the terminal
/// (`AOTerminalView` paints the same colour), so the window reads as one
/// piece. Soft grey in dark mode rather than SwiftTerm's pure-black default.
extension AppAppearance {
    /// Applied app-wide; terminals re-theme via `viewDidChangeEffectiveAppearance`.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

enum Chrome {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    /// Terminal + card. The chrome around it is a step darker (dark mode) or grey (light), as Herdr.
    static func terminalBackground(for appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(srgbRed: 0.114, green: 0.118, blue: 0.125, alpha: 1) : .white
    }
    static let background = Color(nsColor: NSColor(name: nil) {
        isDark($0) ? NSColor(srgbRed: 0.082, green: 0.086, blue: 0.094, alpha: 1)
                   : NSColor(srgbRed: 0.953, green: 0.953, blue: 0.957, alpha: 1)
    })
    static let cardBackground = Color(nsColor: NSColor(name: nil) { terminalBackground(for: $0) })
    static let hairline = Color.primary.opacity(0.10)
    static let cardBorder = Color.primary.opacity(0.16)

    /// Stable per-name avatar colour (String.hashValue is seeded per launch, so hash by hand).
    static func avatarColor(for name: String) -> Color {
        let palette: [Color] = [.orange, .teal, .blue, .purple, .pink, .green, .indigo, .brown]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

/// Coloured rounded square with the folder's initial, like a workspace icon.
struct FolderAvatar: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Chrome.avatarColor(for: name).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
