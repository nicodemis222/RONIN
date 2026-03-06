import SwiftUI

// MARK: - Matrix Color Palette

extension Color {
    // Core palette
    /// Pure neon green — the iconic Matrix color
    static let matrixNeon = Color(red: 0, green: 1.0, blue: 0.255)
    /// Bright green for headings and active elements
    static let matrixBright = Color(red: 0, green: 0.9, blue: 0.224)
    /// Standard readable green for body text
    static let matrixText = Color(red: 0.2, green: 0.8, blue: 0.2)
    /// Muted green for secondary/dimmed text (WCAG AA ≥ 4.5:1 on black)
    static let matrixDim = Color(red: 0.22, green: 0.72, blue: 0.22)
    /// Faint green for timestamps and tertiary labels (WCAG AA ≥ 4.5:1 on black)
    static let matrixFaded = Color(red: 0.2, green: 0.56, blue: 0.2)

    // Backgrounds
    /// True black
    static let matrixBlack = Color(red: 0, green: 0, blue: 0)
    /// Dark green-tinted surface for cards
    static let matrixSurface = Color(red: 0, green: 0.1, blue: 0)
    /// Slightly lighter dark green for grouped sections
    static let matrixElevated = Color(red: 0, green: 0.133, blue: 0)
    /// Bar/toolbar background
    static let matrixBar = Color(red: 0, green: 0.082, blue: 0)

    // Borders & dividers
    static let matrixBorder = Color(red: 0, green: 0.3, blue: 0)
    static let matrixDivider = Color(red: 0, green: 0.25, blue: 0).opacity(0.6)

    // Status
    static let matrixStatusActive = Color(red: 0, green: 1.0, blue: 0.255)
    static let matrixStatusPaused = Color(red: 0.8, green: 0.667, blue: 0)
    static let matrixStatusError = Color(red: 0.8, green: 0.133, blue: 0.133)

    // Semantic colors for tone differentiation
    /// Direct tone: cyan-green — assertive, action-oriented
    static let matrixCyan = Color(red: 0, green: 1.0, blue: 0.6)
    /// Diplomatic tone: standard neon — collaborative, bridging
    static let matrixGreen = Color(red: 0, green: 1.0, blue: 0.255)
    /// Analytical tone: yellow-green — data-driven, logical
    static let matrixLime = Color(red: 0.667, green: 1.0, blue: 0)
    /// Empathetic tone: warm amber — validates concerns, builds rapport
    static let matrixAmber = Color(red: 1.0, green: 0.76, blue: 0.28)
    /// Warnings
    static let matrixWarning = Color(red: 0.867, green: 0.667, blue: 0)

    // Glow
    static let matrixGlow = Color(red: 0, green: 1.0, blue: 0.255)

    // Reading-optimized colors (research: reduce saturation for sustained reading)
    /// Softened green for body text — less saturated to reduce eye fatigue
    /// ~8:1 contrast on dark bg, HSL(120°, 35%, 62%) vs standard matrixText HSL(120°, 60%, 50%)
    static let matrixReadable = Color(red: 0.45, green: 0.78, blue: 0.45)
    /// Panel reading background — slight green tint off pure black to reduce halation
    /// Research: never use pure #000000 for sustained reading areas
    static let matrixPanel = Color(red: 0.01, green: 0.035, blue: 0.01)
}

// MARK: - Matrix Fonts

extension Font {
    static let matrixLargeTitle = Font.system(size: 28, weight: .bold, design: .monospaced)
    static let matrixTitle = Font.system(size: 20, weight: .semibold, design: .monospaced)
    static let matrixHeadline = Font.system(size: 15, weight: .bold, design: .monospaced)
    static let matrixBody = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let matrixBodyBold = Font.system(size: 13, weight: .bold, design: .monospaced)
    static let matrixCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let matrixCaption2 = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let matrixBadge = Font.system(size: 9, weight: .bold, design: .monospaced)

    // Reading-optimized variants (research: 14-15px min for sustained screen reading)
    /// Transcript body — 14pt for scanning real-time speech
    static let matrixTranscript = Font.system(size: 14, weight: .regular, design: .monospaced)
    /// Response/suggestion text — 15pt for deep comprehension reading
    static let matrixResponse = Font.system(size: 15, weight: .regular, design: .monospaced)
    /// Bold response text for emphasis
    static let matrixResponseBold = Font.system(size: 15, weight: .semibold, design: .monospaced)
    /// Guidance body — 14pt matching transcript
    static let matrixGuidance = Font.system(size: 14, weight: .regular, design: .monospaced)
    static let matrixGuidanceBold = Font.system(size: 14, weight: .semibold, design: .monospaced)
}

// MARK: - Matrix ViewModifiers

/// Green phosphor glow effect
struct MatrixGlowText: ViewModifier {
    var color: Color = .matrixGlow
    var radius: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.5), radius: radius, x: 0, y: 0)
            .shadow(color: color.opacity(0.2), radius: radius * 2, x: 0, y: 0)
    }
}

/// Dark card with green border
struct MatrixCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(MatrixSpacing.cardPadding)
            .background(Color.matrixSurface.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.matrixBorder.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Resizable Panel Divider

/// Draggable divider between resizable panels. Shows grip dots and changes cursor on hover.
struct PanelDivider: View {
    /// true = vertical bar separating horizontal panels; false = horizontal bar separating vertical panels
    let isVertical: Bool
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Invisible hit target (wider than visual)
            Rectangle()
                .fill(Color.clear)
                .frame(
                    width: isVertical ? MatrixSpacing.dividerGrabWidth : nil,
                    height: isVertical ? nil : MatrixSpacing.dividerGrabWidth
                )
                .contentShape(Rectangle())

            // Visual line
            Rectangle()
                .fill(isHovered ? Color.matrixBright.opacity(0.5) : Color.matrixBorder.opacity(0.4))
                .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)

            // Grip dots
            if isVertical {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(isHovered ? Color.matrixBright.opacity(0.8) : Color.matrixDim.opacity(0.5))
                            .frame(width: 3, height: 3)
                    }
                }
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(isHovered ? Color.matrixBright.opacity(0.8) : Color.matrixDim.opacity(0.5))
                            .frame(width: 3, height: 3)
                    }
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                if isVertical {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.resizeUpDown.push()
                }
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Terminal-style panel replacing GroupBox
struct MatrixGroupBox: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("> \(title)")
                .font(.matrixHeadline)
                .foregroundColor(.matrixBright)
                .modifier(MatrixGlowText(radius: 4))

            Divider().overlay(Color.matrixDivider)

            content
        }
        .padding(12)
        .background(Color.matrixElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.matrixBorder.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Cosmetic scanline overlay
struct MatrixScanlines: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ForEach(0..<Int(geo.size.height / 3), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.black.opacity(0.05))
                            .frame(height: 1)
                        Spacer().frame(height: 2)
                    }
                }
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
        )
    }
}

/// Pulsing cyan glow highlight for panels when a question is detected.
/// Two-layer phosphor shadow (matches MatrixGlowText pattern) + subtle background tint.
/// Pulse oscillates border opacity 0.4–0.8 with a 1s period while active.
struct QuestionHighlightModifier: ViewModifier {
    let isActive: Bool

    @State private var pulsePhase: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: MatrixSpacing.cornerRadius)
                    .stroke(Color.matrixCyan.opacity(isActive ? (pulsePhase ? 0.8 : 0.4) : 0), lineWidth: 1.5)
                    .shadow(color: Color.matrixCyan.opacity(isActive ? (pulsePhase ? 0.5 : 0.25) : 0), radius: 5, x: 0, y: 0)
                    .shadow(color: Color.matrixCyan.opacity(isActive ? (pulsePhase ? 0.2 : 0.1) : 0), radius: 10, x: 0, y: 0)
                    .animation(isActive ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .easeOut(duration: 0.8), value: pulsePhase)
            )
            .background(
                RoundedRectangle(cornerRadius: MatrixSpacing.cornerRadius)
                    .fill(Color.matrixCyan.opacity(isActive ? 0.03 : 0))
            )
            .onChange(of: isActive) { _, newValue in
                if newValue {
                    pulsePhase = true
                } else {
                    pulsePhase = false
                }
            }
    }
}

// MARK: - View Extensions

extension View {
    func matrixGlow(color: Color = .matrixGlow, radius: CGFloat = 6) -> some View {
        modifier(MatrixGlowText(color: color, radius: radius))
    }

    func matrixCard() -> some View {
        modifier(MatrixCard())
    }

    func matrixScanlines() -> some View {
        modifier(MatrixScanlines())
    }

    func matrixGroupBox(title: String) -> some View {
        modifier(MatrixGroupBox(title: title))
    }

    /// Apply pulsing cyan glow when a question is detected in the transcript
    func questionHighlight(isActive: Bool) -> some View {
        modifier(QuestionHighlightModifier(isActive: isActive))
    }
}

// MARK: - Matrix Button Styles

struct MatrixPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.matrixBody)
            .foregroundColor(isEnabled ? .matrixBlack : .matrixDim)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEnabled
                        ? (configuration.isPressed ? Color.matrixDim : Color.matrixBright)
                        : Color.matrixFaded.opacity(0.3)
                    )
            )
            .shadow(color: isEnabled ? Color.matrixGlow.opacity(0.4) : .clear, radius: 8)
    }
}

struct MatrixSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.matrixBody)
            .foregroundColor(configuration.isPressed ? .matrixDim : .matrixText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.matrixBorder, lineWidth: 1)
            )
    }
}

struct MatrixDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.matrixBody)
            .foregroundColor(configuration.isPressed ? Color.matrixStatusError.opacity(0.7) : .matrixStatusError)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.matrixStatusError.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Spacing Constants

enum MatrixSpacing {
    /// Horizontal padding for panel content (12pt)
    static let panelPaddingH: CGFloat = 12
    /// Horizontal padding for bars and headers (16pt)
    static let barPaddingH: CGFloat = 16
    /// Vertical padding for bars and headers (8pt)
    static let barPaddingV: CGFloat = 8
    /// Card internal padding (10pt → 12pt for breathing room)
    static let cardPadding: CGFloat = 12
    /// Outer padding for settings/overlay pages (24pt)
    static let outerPadding: CGFloat = 24
    /// Standard corner radius (6pt)
    static let cornerRadius: CGFloat = 6

    // Reading-optimized spacing (evidence-based)
    /// Line spacing for transcript text (~1.4x at 14pt ≈ 6pt leading)
    static let transcriptLineSpacing: CGFloat = 6
    /// Line spacing for response/suggestion text (~1.5x at 15pt ≈ 8pt leading)
    static let responseLineSpacing: CGFloat = 8
    /// Line spacing for guidance body text (~1.45x at 14pt ≈ 6pt leading)
    static let guidanceLineSpacing: CGFloat = 6
    /// Visual gap between different speaker turns (research: 12-16pt)
    static let speakerTurnGap: CGFloat = 14
    /// Max text width for optimal reading (~60 CPL at 15pt mono ≈ 580pt)
    static let maxReadingWidth: CGFloat = 580
    /// Draggable divider hit-target width
    static let dividerGrabWidth: CGFloat = 8
    /// Spacing between suggestion cards
    static let cardGap: CGFloat = 14
}

// MARK: - Matrix TextField Style

struct MatrixTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.matrixBody)
            .foregroundColor(.matrixBright)
            .padding(8)
            .background(Color.matrixBlack)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.matrixBorder, lineWidth: 1)
            )
    }
}
