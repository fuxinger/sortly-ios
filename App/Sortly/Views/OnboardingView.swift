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
            .padding(Theme.Spacing.l)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .animation(.default, value: step)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            Spacer()
            Text("SORTLY").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("Deine Fotos, endlich sortiert.").font(.largeTitle.weight(.bold))
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                promise("iphone", "Alles bleibt auf deinem iPhone. Nichts wird hochgeladen.")
                promise("lock.shield", "Originale werden nie gelöscht, verändert oder kopiert.")
                promise("checklist", "Du siehst jeden Vorschlag, bevor etwas passiert, und kannst alles rückgängig machen.")
                promise("rectangle.stack", "Vorhandene Alben werden erkannt und ergänzt statt doppelt angelegt.")
            }
            Spacer()
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
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Was soll SORTLY sortieren?").font(.title.weight(.bold))
            Text("Die markierten Bereiche zählen als deine Hauptsortierung. Du kannst das später jederzeit ändern.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(OrganizationArea.available, id: \.self) { area in
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
                        .padding(Theme.Spacing.m)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card - 6, style: .continuous))
                    }
                }
            }
            Button("Weiter") {
                model.saveSettings()
                step = 2
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.settings.enabledAreas.isEmpty)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Spacer()
            IconTile(systemName: "photo.on.rectangle", tint: Theme.accent).scaleEffect(1.4).padding(.bottom, Theme.Spacing.s)
            Text("Zugriff auf deine Fotos").font(.title.weight(.bold))
            Text("SORTLY braucht vollen Zugriff, um deine Mediathek zu analysieren und Alben anzulegen. Die Analyse passiert nur auf diesem iPhone.")
                .foregroundStyle(.secondary)
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
                    Text("SORTLY sortiert dann nur die Fotos, die du freigegeben hast. Für die ganze Mediathek kannst du später vollen Zugriff erlauben.")
                }
            default:
                EmptyView()
            }
            Spacer()
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
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Spacer()
            Text("Erst ein Probelauf?").font(.title.weight(.bold))
            Text("Die Analyse läuft immer über die ganze Mediathek. Für den ersten Durchgang kann SORTLY die Vorschläge aber auf ein Jahr beschränken, damit du das Ergebnis in Ruhe prüfen kannst.")
                .foregroundStyle(.secondary)
            Picker("Vorschläge für", selection: $trialYear) {
                Text("Die ganze Mediathek").tag(Int?.none)
                ForEach((0..<6).map { currentYear - $0 }, id: \.self) { year in
                    Text(verbatim: "Nur \(year)").tag(Int?.some(year))
                }
            }
            .pickerStyle(.inline)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            Text("Die erste Analyse kann bei großen Mediatheken eine Weile dauern. Sie läuft weiter, während du die App benutzt, und setzt nach einer Pause genau dort fort.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Analyse starten") {
                model.finishOnboarding(scope: trialYear.map { .year($0) } ?? .all)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}
