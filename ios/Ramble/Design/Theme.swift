import SwiftUI

/// Ramble's visual language: soft green paper, dark green ink, an editorial
/// serif for anything the person actually reads, and small amounts of muted
/// colour to say what a thing is.
///
/// Every colour is defined once, for both appearances, so light and dark can
/// never drift apart. Nothing in a feature file should name a hex value.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// The page itself. Warm off-white with a green cast, not pure white,
        /// because long transcripts are read on it.
        static let paper = Color(light: 0xFCFDF8, dark: 0x1D2C22)
        /// Primary text. Dark green rather than black — ink on paper.
        static let ink = Color(light: 0x2D4436, dark: 0xE5EFDC)
        /// Secondary text: timestamps, supporting lines, metadata.
        static let secondary = Color(light: 0x6F806E, dark: 0xACBDA3)
        /// Hairline dividers. Structure comes from space; these only whisper.
        static let divider = Color(light: 0xDDE6D5, dark: 0x3B503B)
        /// A tinted surface for chips and inset panels.
        static let subtle = Color(light: 0xEDF3E6, dark: 0x2C4030)
        /// Raised surface, one step off the paper. Used sparingly.
        static let raised = Color(light: 0xFFFFFF, dark: 0x263A2C)

        /// The one action colour: the record button, primary buttons, and the
        /// live waveform. Spending it anywhere else weakens the only signal
        /// that matters on the home screen.
        static let action = Color(light: 0x477B53, dark: 0xB8DCA4)
        static let onAction = Color(light: 0xF8FFF2, dark: 0x233E24)
        /// The halo behind the record button.
        static let recordHalo = Color(light: 0xE9F1E2, dark: 0x2B422E)

        /// Approval surfaces. Pale honey, deliberately unlike everything else:
        /// a decision that reaches the outside world should not look like the
        /// rest of the page.
        static let approvalSurface = Color(light: 0xFBF7E9, dark: 0x33301F)
        static let approvalBorder = Color(light: 0xE7DBB4, dark: 0x55502F)
        static let approvalAccent = Color(light: 0xC9B47A, dark: 0xD6C288)

        /// The capture screen. Pale green in light, deeper green in dark —
        /// deliberately not the paper, so it is obvious the app is listening.
        static let captureSurface = Color(light: 0xEDF3E6, dark: 0x18261C)

        /// Failure. Muted rather than alarming: a failed upload is recoverable.
        static let warning = Color(light: 0x9C4B3C, dark: 0xE0997F)

        // MARK: Semantic accents

        /// The small muted tones that say what an extracted item is.
        struct Accent {
            let surface: Color
            let text: Color
        }

        static let decisionAccent = Accent(
            surface: Color(light: 0xE8F1DF, dark: 0x2F3E2B),
            text: Color(light: 0x4B6942, dark: 0xBFD6AF)
        )
        static let taskAccent = Accent(
            surface: Color(light: 0xE6EEF4, dark: 0x2A3742),
            text: Color(light: 0x536E84, dark: 0xAFC8DC)
        )
        static let ideaAccent = Accent(
            surface: Color(light: 0xEEE8F3, dark: 0x37303E),
            text: Color(light: 0x796587, dark: 0xC9B7D6)
        )
        static let questionAccent = Accent(
            surface: Color(light: 0xF7EFD9, dark: 0x3D3626),
            text: Color(light: 0x877144, dark: 0xDCC894)
        )
        static let peopleAccent = Accent(
            surface: Color(light: 0xF7E9DE, dark: 0x3D3128),
            text: Color(light: 0x916B50, dark: 0xD9B79A)
        )
        static let neutralAccent = Accent(surface: subtle, text: secondary)

        /// Which tone an item kind wears. Commitments and follow-ups borrow the
        /// people tone because both are promises that involve someone else.
        static func accent(for kind: ItemKind) -> Accent {
            switch kind {
            case .decision: decisionAccent
            case .task, .reminder: taskAccent
            case .idea: ideaAccent
            case .question: questionAccent
            case .commitment, .followUp: peopleAccent
            case .note, .journal, .reference, .summary: neutralAccent
            }
        }

        /// Entity avatars, tinted by what the entity is.
        static func accent(forEntityKind kind: String) -> Accent {
            switch kind {
            case "organization", "company": decisionAccent
            case "project": ideaAccent
            case "place": questionAccent
            default: peopleAccent
            }
        }
    }

    // MARK: - Typography

    /// One type token. Held as data rather than a `Font` so the scaling
    /// modifier can rebuild the font at the reader's chosen text size — a
    /// fixed `Font.system(size:)` ignores Dynamic Type entirely.
    struct TypeStyle {
        var size: CGFloat
        var weight: Font.Weight = .regular
        var design: Font.Design = .default
        var relativeTo: Font.TextStyle = .body
        /// Extra leading. Set to reach the 1.7–1.8 line height reading text needs.
        var lineSpacing: CGFloat = 0
        var tracking: CGFloat = 0
        var uppercase: Bool = false
    }

    enum Text {
        // Editorial serif — screen headings, titles, answers, transcripts.
        static let screenTitle = TypeStyle(
            size: 32, design: .serif, relativeTo: .largeTitle, lineSpacing: 2, tracking: -0.6
        )
        static let pageTitle = TypeStyle(
            size: 29, design: .serif, relativeTo: .title, lineSpacing: 1, tracking: -0.5
        )
        static let recordingTitle = TypeStyle(
            size: 22, design: .serif, relativeTo: .title2, lineSpacing: 1, tracking: -0.3
        )
        static let sectionSerif = TypeStyle(
            size: 18, design: .serif, relativeTo: .title3, tracking: -0.2
        )
        /// Long-form reading: transcripts and answers, at a comfortable 1.75.
        static let reading = TypeStyle(
            size: 17, design: .serif, relativeTo: .body, lineSpacing: 9
        )
        static let answer = TypeStyle(
            size: 17, design: .serif, relativeTo: .body, lineSpacing: 6
        )
        static let quote = TypeStyle(
            size: 15, design: .serif, relativeTo: .callout, lineSpacing: 4
        )

        // Neutral sans — controls, labels, timestamps, supporting information.
        static let body = TypeStyle(size: 16, relativeTo: .body, lineSpacing: 3)
        static let bodyStrong = TypeStyle(size: 16, weight: .medium, relativeTo: .body, lineSpacing: 3)
        static let supporting = TypeStyle(size: 14, relativeTo: .subheadline, lineSpacing: 3)
        static let meta = TypeStyle(size: 12, relativeTo: .caption)
        static let control = TypeStyle(size: 15, weight: .medium, relativeTo: .callout)
        /// Small all-caps section markers.
        static let eyebrow = TypeStyle(
            size: 11, weight: .semibold, relativeTo: .caption2, tracking: 1.2, uppercase: true
        )
        static let chip = TypeStyle(size: 12, weight: .medium, relativeTo: .caption2)
        /// The recording timer. Tabular so it cannot jitter as digits change.
        static let timer = TypeStyle(size: 52, design: .serif, relativeTo: .largeTitle, tracking: -2)
    }

    // MARK: - Metrics

    enum Metrics {
        static let screenPadding: CGFloat = 24
        /// Small labels sit at 5pt; inputs and inset surfaces at 10.
        static let labelRadius: CGFloat = 5
        static let inputRadius: CGFloat = 10
        static let surfaceRadius: CGFloat = 12
        static let recordButton: CGFloat = 70
        static let minimumTouchTarget: CGFloat = 44

        // The 4 / 8 / 12 / 16 / 24 / 32 rhythm, named so spacing is chosen
        // rather than typed.
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}

// MARK: - Applying type

private struct ScaledTypeModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var leading: CGFloat
    private let style: Theme.TypeStyle

    init(_ style: Theme.TypeStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
        _leading = ScaledMetric(wrappedValue: style.lineSpacing, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: style.weight, design: style.design))
            .tracking(style.tracking)
            .lineSpacing(leading)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a type token, scaled to the reader's text size.
    func rambleType(_ style: Theme.TypeStyle) -> some View {
        modifier(ScaledTypeModifier(style))
    }
}

extension Font {
    /// An unscaled font for the few places that need a `Font` value rather
    /// than a modifier — concatenated `Text`, mainly.
    static func ramble(_ style: Theme.TypeStyle) -> Font {
        .system(size: style.size, weight: style.weight, design: style.design)
    }
}

// MARK: - Colour construction

extension Color {
    /// Builds a colour that resolves per appearance, so every token defines
    /// both modes in one place and neither can be forgotten.
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

// MARK: - Motion

extension Animation {
    /// The house transition: short and restrained. Returns nil when the reader
    /// has asked for reduced motion, so callers can pass it straight to
    /// `withAnimation` or `.animation(_:value:)`.
    static func ramble(_ duration: TimeInterval = 0.22) -> Animation {
        .easeOut(duration: duration)
    }
}

extension View {
    /// A gentle fade-in for content that arrives after the screen is already
    /// on-screen — a processed ramble, a newly captured row. Starts visible so
    /// a still frame of the page is never blank.
    func arriving(_ isNew: Bool, reduceMotion: Bool) -> some View {
        transition(
            reduceMotion || !isNew
                ? .identity
                : .opacity.combined(with: .move(edge: .top))
        )
    }
}
