import SwiftUI

/// Design tokens for direction A "Klar" (chosen 2026-11-13): calm, light, close to iOS.
/// System font (SF Pro) with Dynamic Type everywhere; numbers use monospaced digits.
/// Liquid Glass is left to the system navigation (tab bar, toolbars); content stays plain.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 20
        static let tile: CGFloat = 10
        static let button: CGFloat = 16
    }

    /// Named asset instead of `Color.accentColor`, so off-screen renders (share image) keep the teal too.
    static let accent = Color("AccentColor")
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondaryText = Color.secondary

    /// Area colors: distinct in lightness, not only hue (accessibility).
    static func tint(for area: OrganizationAreaStyle) -> Color {
        switch area {
        case .trips: Color(red: 0.04, green: 0.43, blue: 0.48)
        case .places: Color(red: 0.18, green: 0.31, blue: 0.66)
        case .documents: Color(red: 0.54, green: 0.35, blue: 0.07)
        case .neutral: Color(uiColor: .secondaryLabel)
        }
    }
}

enum OrganizationAreaStyle { case trips, places, documents, neutral }

/// White rounded card on the grouped background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { content }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Progress ring for the organized share.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Color(uiColor: .systemFill), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Organisiert"))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// Full-width primary action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// Secondary full-width action.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.primary)
            .background(Theme.card.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button - 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button - 2, style: .continuous).stroke(Color(uiColor: .separator)))
    }
}

/// Small icon tile used in lists.
struct IconTile: View {
    var systemName: String
    var tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Capsule label for statuses ("Neu", "Album da", "Unsicher").
struct StatusBadge: View {
    var text: LocalizedStringKey
    var tint: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
