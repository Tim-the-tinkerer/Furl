import AppKit
import SwiftUI

enum Theme {
    static let navy = Color(red: 0.05, green: 0.12, blue: 0.20)
    static let copper = Color(red: 0.77, green: 0.47, blue: 0.23)
    static let teal = Color(red: 0.16, green: 0.61, blue: 0.56)
    static let canvas = Color(red: 0.91, green: 0.86, blue: 0.77)
    static let accent = teal

    static var headerGradient: LinearGradient {
        LinearGradient(colors: [navy, Color(red: 0.10, green: 0.22, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var primaryFill: LinearGradient {
        LinearGradient(colors: [teal, Color(red: 0.10, green: 0.45, blue: 0.48)], startPoint: .top, endPoint: .bottom)
    }
}

struct FurlButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, compact }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(kind == .primary ? .system(size: 14, weight: .semibold) : .system(size: 13, weight: .medium))
            .padding(.horizontal, kind == .compact ? 10 : 14)
            .padding(.vertical, kind == .compact ? 4 : 7)
            .foregroundStyle(kind == .secondary ? Theme.accent : .white)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(kind == .secondary ? Theme.accent.opacity(0.45) : Color.white.opacity(0.22), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.42)
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch kind {
        case .primary:
            Theme.primaryFill
        case .compact:
            Theme.copper
        case .secondary:
            Color(nsColor: .controlBackgroundColor).opacity(pressed ? 0.7 : 1)
        }
    }
}
