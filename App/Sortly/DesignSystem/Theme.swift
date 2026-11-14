import SwiftUI

/// Design tokens for direction A "Klar" (chosen 2026-11-13): calm, light, close to iOS.
/// System font (SF Pro) with Dynamic Type everywhere; numbers use monospaced digits.
/// Liquid Glass comes from the system: tab bar, toolbars and the two button styles below;
/// content stays plain.
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
    /// Text and symbols on an accent fill: white on the dark teal of light mode, near-black
    /// on the lighter teal of dark mode (white there would fall below 3:1 contrast).
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : .white
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondaryText = Color.secondary

    /// Area colors: distinct in lightness, not only hue (accessibility). Dark mode uses
    /// lighter variants so text in these colors keeps at least 4.5:1 contrast there too.
    static func tint(for area: OrganizationAreaStyle) -> Color {
        switch area {
        case .trips: adaptive(light: (0.04, 0.43, 0.48), dark: (0.32, 0.77, 0.79))
        case .places: adaptive(light: (0.18, 0.31, 0.66), dark: (0.55, 0.67, 1.00))
        case .documents: adaptive(light: (0.54, 0.35, 0.07), dark: (0.93, 0.70, 0.36))
        case .neutral: Color(uiColor: .secondaryLabel)
        }
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
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
                // Large text sizes shrink the number to fit inside the ring instead of "6…".
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(lineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sortiert"))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// Full-width primary action in the iOS 26 Liquid Glass style (system `glassProminent`
/// button: Apple's own contrast, press and disabled states, tinted with the app color).
struct PrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Theme.accent)
    }
}

/// Secondary full-width action: the system `glass` button.
struct SecondaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.primary)
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
