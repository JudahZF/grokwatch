import SwiftUI

/// The look of the official Grok Bot apps: ink and grey surfaces, pills and circles. Colour belongs to the Bots.
/// The official dark palette is not in the desktop bundle, so these are its light tokens inverted for a black screen.
enum Theme {
    /// Your bubble and each primary button (`--sand-fill-bubble-user`, inverted).
    static let ink = Color(hex: 0xFCFCFC)
    /// Text on `ink`.
    static let onInk = Color(hex: 0x1C1C1C)
    /// Bot bubbles, cards and fields.
    static let surface = Color.white.opacity(0.12)
    /// Secondary buttons, one step above `surface`.
    static let control = Color.white.opacity(0.16)
    /// "Waiting for you" (`--sand-icon-warn-primary`).
    static let attention = Color(hex: 0xF59312)
    /// Unread counts (`--sand-icon-accent-primary`). The desktop keeps these blue for every Bot colour.
    static let unread = Color(hex: 0x1680F3)
    static let danger = Color(hex: 0xFF6B76)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A full-round button. Primary is ink; the others are grey.
struct PillButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .foregroundStyle(isPrimary ? Theme.onInk : Color.white)
            .background(isPrimary ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.control), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var primaryPill: PillButtonStyle { PillButtonStyle(isPrimary: true) }
}

/// How your own chat bubbles are coloured. The desktop has the same two choices (`black`, `bot-color`).
enum BubbleStyle: String, CaseIterable, Identifiable {
    case ink
    case botColor

    var id: Self { self }

    var label: String {
        switch self {
        case .ink: "White"
        case .botColor: "Bot colour"
        }
    }
}
