import SwiftUI
import SortlyCore
import SortlyEngine

/// First start (prompt §7, Schritt 1–3): promise, areas, photo access, first analysis.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var trialYear: Int?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0: welcome
                case 1: areas
                case 2: access
                default: start
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .animation(.default, value: step)
        }
    }

    /// One onboarding step: the content scrolls when it does not fit (large text, small
    /// iPhones) and is centered when it does; the button stays at the bottom.
    private func page<Content: View, Footer: View>(
        centered: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) { content() }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(centered ? .center : .top, for: .alignment)
        .safeAreaInset(edge: .bottom) {
            footer()
                .frame(maxWidth: 560)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        page {
            Text("Albumist").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("Deine Fotos, endlich sortiert.").font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Theme.Spacing.s)
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                promise("iphone", "Alles bleibt auf deinem Gerät. Nichts wird hochgeladen.")
                promise("lock.shield", "Originale werden nie gelöscht, verändert oder kopiert.")
                promise("checklist", "Du siehst jeden Vorschlag, bevor etwas passiert, und kannst alles rückgängig machen.")
                promise("rectangle.stack", "Vorhandene Alben werden erkannt und ergänzt statt doppelt angelegt.")
            }
        } footer: {
            Button("Los geht’s") { step = 1 }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func promise(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            IconTile(systemName: symbol, tint: Theme.accent)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var areas: some View {
        page(centered: false) {
            Text("Was soll Albumist sortieren?").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Die markierten Bereiche zählen als deine Hauptsortierung. Du kannst das später jederzeit ändern.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Spacing.s) {
                ForEach(OrganizationArea.available, id: \.self) { area in
                    areaCard(area)
                }
            }
        } footer: {
            Button("Weiter") {
                model.saveSettings()
                step = 2
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.settings.enabledAreas.isEmpty)
        }
    }

    private func areaCard(_ area: OrganizationArea) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle(isOn: Binding(
                get: { model.settings.enabledAreas.contains(area) },
                set: { on in
                    if on { model.settings.enabledAreas.insert(area) } else { model.settings.enabledAreas.remove(area) }
                }
            )) {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemName: area.symbol, tint: area.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(area.title).font(.body.weight(.medium))
                        Text(area.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if area == .places && model.settings.enabledAreas.contains(.places) {
                citiesToggle
            }
        }
        .padding(Theme.Spacing.m)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card - 6, style: .continuous))
        .animation(.default, value: model.settings.enabledAreas.contains(.places))
    }

    /// Right at the start (Fuchs, 14.11.): cities are off by default, but whoever wants
    /// Rom and Florenz next to Italien can say so here, not only later in Settings.
    @ViewBuilder
    private var citiesToggle: some View {
        @Bindable var model = model
        Divider()
        Toggle(isOn: $model.settings.places.includesCities) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Städte als eigene Alben").font(.subheadline.weight(.medium))
                Text("Zum Beispiel Rom und Florenz zusätzlich zu Italien.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var access: some View {
        page {
            IconTile(systemName: "photo.on.rectangle", tint: Theme.accent).scaleEffect(1.4).padding(.bottom, Theme.Spacing.s)
            Text("Zugriff auf deine Fotos").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Albumist braucht vollen Zugriff, um deine Mediathek zu analysieren und Alben anzulegen. Die Analyse passiert nur auf diesem Gerät.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Testers asked exactly here whether "full access" means the app may delete.
            Label("Albumist löscht und verändert nie ein Foto. Es legt nur Alben an, und jeder Schritt lässt sich rückgängig machen.", systemImage: "checkmark.shield")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            switch model.access {
            case .denied, .restricted:
                Card {
                    Label("Der Zugriff wurde abgelehnt.", systemImage: "exclamationmark.triangle").font(.headline)
                    Text("Du kannst ihn in den Einstellungen unter Datenschutz › Fotos erlauben.")
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Einstellungen öffnen", destination: url).font(.headline)
                    }
                }
            case .limited:
                Card {
                    Label("Nur ausgewählte Fotos", systemImage: "photo.badge.checkmark").font(.headline)
                    Text("Albumist sortiert dann nur die Fotos, die du freigegeben hast. Für die ganze Mediathek kannst du später vollen Zugriff erlauben.")
                }
            default:
                EmptyView()
            }
        } footer: {
            if model.access.canRead {
                Button("Weiter") { step = 3 }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Zugriff erlauben") {
                    Task {
                        await model.requestAccess()
                        if model.access.canRead { step = 3 }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var start: some View {
        let currentYear = Calendar.current.component(.year, from: Date())
        return page {
            Text("Womit soll Albumist anfangen?").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Die Analyse läuft immer über die ganze Mediathek. Für den ersten Durchgang kann Albumist die Vorschläge aber auf ein Jahr beschränken, damit du das Ergebnis in Ruhe prüfen kannst.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A settings-style row with a menu instead of a wheel (HIG: menus for short lists).
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Vorschläge für")
                    Spacer(minLength: Theme.Spacing.m)
                    trialPicker(currentYear)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Vorschläge für")
                    trialPicker(currentYear)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: 52)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            Text("Die erste Analyse kann bei großen Mediatheken eine Weile dauern. Sie läuft weiter, auch wenn du die App verlässt, und zeigt den Fortschritt auf dem Sperrbildschirm. Wenn du magst, sagt Albumist dir Bescheid, sobald sie fertig ist.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Analyse starten") {
                model.finishOnboarding(scope: trialYear.map { .year($0) } ?? .all)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

extension OnboardingView {
    fileprivate func trialPicker(_ currentYear: Int) -> some View {
        Picker("Vorschläge für", selection: $trialYear) {
            Text("Die ganze Mediathek").tag(Int?.none)
            ForEach((0..<6).map { currentYear - $0 }, id: \.self) { year in
                Text("Nur \(String(year))").tag(Int?.some(year))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.accent)
    }
}
