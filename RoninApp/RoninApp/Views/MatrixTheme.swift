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
    /// Muted green for secondary/dimmed text
    static let matrixDim = Color(red: 0.2, green: 0.6, blue: 0.2)
    /// Faint green for timestamps and tertiary labels
    static let matrixFaded = Color(red: 0.176, green: 0.42, blue: 0.176)

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

    // Semantic greens for tone differentiation
    /// Direct tone / follow-up questions: cyan-green
    static let matrixCyan = Color(red: 0, green: 1.0, blue: 0.6)
    /// Diplomatic tone / notes: standard neon
    static let matrixGreen = Color(red: 0, green: 1.0, blue: 0.255)
    /// Curious tone: yellow-green
    static let matrixLime = Color(red: 0.667, green: 1.0, blue: 0)
    /// Warnings with amber warmth
    static let matrixWarning = Color(red: 0.867, green: 0.667, blue: 0)

    // Glow
    static let matrixGlow = Color(red: 0, green: 1.0, blue: 0.255)
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
            .padding(10)
            .background(Color.matrixSurface.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.matrixBorder.opacity(0.4), lineWidth: 1)
            )
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
