import SwiftUI

/// The visual language: near-black on warm off-white, one accent reserved for
/// recording and confirmation. Everything else is type and space.
///
/// Colors are defined once here rather than inline so light and dark stay in
/// step, and so the single accent cannot quietly spread across the UI.
enum Theme {
    enum Palette {
        /// Page background. Warm rather than pure white, so long transcripts
        /// are comfortable to read.
        static let background = Color(light: 0xFAF9F7, dark: 0x0E0E10)
        /// Cards and raised surfaces, one step from the background.
        static let surface = Color(light: 0xFFFFFF, dark: 0x17171A)
        static let text = Color(light: 0x16161A, dark: 0xF2F1EE)
        static let muted = Color(light: 0x6B6B73, dark: 0x8A8A93)
        /// Dividers. Deliberately faint: structure comes from spacing.
        static let hairline = Color(light: 0xE5E3DE, dark: 0x232327)

        /// Reserved for the record button and destructive confirmation.
        /// Using it anywhere else weakens the one signal that matters.
        static let accent = Color(light: 0xC8452F, dark: 0xE4573F)

        /// Item-kind tints, used at low opacity behind chip labels.
        static func kind(_ kind: ItemKind) -> Color {
            switch kind {
            case .task, .reminder:      Color(light: 0x2F6F4E, dark: 0x5FAE86)
            case .idea:                 Color(light: 0x8A5A2B, dark: 0xC08A4E)
            case .decision:             Color(light: 0x3A5A8A, dark: 0x7BA3DC)
            case .commitment, .followUp: Color(light: 0x6B4A8A, dark: 0xA98BD0)
            case .question:             Color(light: 0x8A6A2B, dark: 0xCBA55A)
            default:                    Color(light: 0x6B6B73, dark: 0x8A8A93)
            }
        }
    }

    enum Typography {
        static let title = Font.system(size: 20, weight: .semibold)
        static let cardTitle = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15, weight: .regular)
        static let secondary = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 12, weight: .medium)
        /// Monospaced digits so a running timer does not jitter.
        static let timer = Font.system(size: 56, weight: .light, design: .rounded)
            .monospacedDigit()
    }

    enum Metrics {
        static let cornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 16
        static let screenPadding: CGFloat = 20
        static let recordButtonSize: CGFloat = 72
    }
}

extension Color {
    /// Builds a color that resolves per appearance, so every token defines
    /// both modes in one place.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    /// The standard card treatment: surface, hairline border, no shadow.
    func rambleCard() -> some View {
        self
            .padding(Theme.Metrics.cardPadding)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            )
    }
}
