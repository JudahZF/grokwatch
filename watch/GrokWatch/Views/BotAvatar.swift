import SwiftUI

/// A Bot's face: its own picture when it has one, else its shape in its colour with two eyes, as in the official apps.
struct BotAvatar: View {
    let bot: Bot

    var body: some View {
        if let url = URL(string: bot.avatarURL), !bot.avatarURL.isEmpty {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill().clipShape(Circle())
            } placeholder: {
                figure
            }
        } else {
            figure
        }
    }

    private var figure: some View {
        let shape = bot.shape
        let color = bot.color
        return Canvas { context, size in
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            context.fill(shape.outline(in: rect), with: .color(color.body))
            context.fill(shape.eyes(in: rect), with: .color(color == .black ? Theme.onInk : .white))
        }
        .accessibilityHidden(true)
    }
}

/// `GrokBotAgent.avatar_color` values, with the desktop's colours for a dark screen.
enum BotColor: String, CaseIterable {
    case black, brown, red, orange, yellow, green, cyan, blue, violet, magenta, gray

    /// The avatar fill (desktop avatar palette, dark values). A black Bot is white on a dark screen.
    var body: Color {
        switch self {
        case .black: Color(hex: 0xFFFFFF)
        case .brown: Color(hex: 0x855C36)
        case .red: Color(hex: 0xE02135)
        case .orange: Color(hex: 0xFF6700)
        case .yellow: Color(hex: 0xFF9800)
        case .green: Color(hex: 0x009957)
        case .cyan: Color(hex: 0x00A592)
        case .blue: Color(hex: 0x0E74E0)
        case .violet: Color(hex: 0x804EE0)
        case .magenta: Color(hex: 0xE02A88)
        case .gray: Color(hex: 0x777777)
        }
    }

    /// Your bubble in this Bot's colour (`--sand-fill-<colour>-bubble-user`). Nil for black and grey Bots, which keep the ink bubble.
    var bubble: Color? {
        switch self {
        case .black, .gray: nil
        case .brown: Color(hex: 0x86592E)
        case .red: Color(hex: 0xC82532)
        case .orange: Color(hex: 0xD2550A)
        case .yellow: Color(hex: 0xC2730B)
        case .green: Color(hex: 0x0D9655)
        case .cyan: Color(hex: 0x0D9381)
        case .blue: Color(hex: 0x126FD4)
        case .violet: Color(hex: 0x7442D1)
        case .magenta: Color(hex: 0xC82779)
        }
    }
}

extension Bot {
    var shape: BotShape {
        let name = avatarShape.isEmpty ? Self.pick(from: Self.defaultShapes, for: agentID) : avatarShape
        return BotShape.named[name] ?? .blob
    }

    var color: BotColor { BotColor(rawValue: avatarColor) ?? Self.pick(from: Self.defaultColors, for: agentID) }

    /// The shapes the desktop offers first. A Bot with no saved shape or colour gets a stable one from its id;
    /// the desktop's own choice for such a Bot can differ.
    private static let defaultShapes = ["blob", "pebble", "squircle", "tablet", "wedge", "hex", "cloud", "teardrop"]
    private static let defaultColors = BotColor.allCases.filter { $0 != .black }

    /// FNV-1a over the id, so the choice is the same on every launch (`hashValue` is not).
    private static func pick<Element>(from choices: [Element], for id: String) -> Element {
        let hash = id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return choices[Int(hash % UInt32(choices.count))]
    }
}

extension BotShape {
    /// The outline, scaled so its widest point touches `rect`.
    func outline(in rect: CGRect) -> Path {
        guard let longest = radii.max(), longest > 0 else { return Path(ellipseIn: rect) }
        let unit = rect.width / 2 / longest
        let points = radii.enumerated().map { index, radius in
            let angle = CGFloat(index) / CGFloat(radii.count) * 2 * .pi
            return CGPoint(x: rect.midX + cos(angle) * radius * unit, y: rect.midY + sin(angle) * radius * unit)
        }
        // Curves through the midpoints, with each sample as a control point, keep the outline smooth at any size.
        func midpoint(_ index: Int) -> CGPoint {
            let a = points[index % points.count], b = points[(index + 1) % points.count]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        var path = Path()
        path.move(to: midpoint(0))
        for index in 1...points.count {
            path.addQuadCurve(to: midpoint(index), control: points[index % points.count])
        }
        path.closeSubpath()
        return path
    }

    /// Two leaning capsules. The official apps pose the face in 3D; this is the flat front view.
    func eyes(in rect: CGRect) -> Path {
        let unit = rect.width / 2 / max(radii.max() ?? 1, 1)
        let size = CGSize(width: eye.width * unit, height: eye.height * unit)
        var path = Path()
        for side: CGFloat in [-1, 1] {
            let capsule = Path(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                               cornerRadius: size.width / 2)
            let centre = CGAffineTransform(translationX: rect.midX + side * eye.gap * unit / 2, y: rect.midY - eye.lift * unit)
            path.addPath(capsule, transform: CGAffineTransform(rotationAngle: -.pi / 9).concatenating(centre))
        }
        return path
    }
}
