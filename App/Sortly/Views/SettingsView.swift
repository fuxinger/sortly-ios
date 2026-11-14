import SwiftUI
import SortlyCore
import SortlyEngine

/// Settings (prompt §17): areas, naming, privacy, history and undo, about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var redeeming = false
    @State private var rejectedCount = 0

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(OrganizationArea.available) { area in
                    Toggle(isOn: areaBinding(area, \.enabledAreas)) {
                        Label { Text(area.title) } icon: { Image(systemName: area.symbol).foregroundStyle(area.tint) }
                    }
                }
            } header: {
                Text("Bereiche")
            } footer: {
                Text("Nur eingeschaltete Bereiche bekommen Vorschläge.")
            }

            Section {
                ForEach(OrganizationArea.available.filter { model.settings.enabledAreas.contains($0) }) { area in
                    Toggle(isOn: areaBinding(area, \.primaryAreas)) { Text(area.title) }
                }
            } header: {
                Text("Hauptbereiche")
            } footer: {
                Text("Ein Foto gilt als sortiert, wenn es in einem dieser Bereiche ein Album hat.")
            }

            Section("Alben") {
                Picker("Sprache der Albumnamen", selection: $model.settings.titleLanguage) {
                    Text("Deutsch").tag(TitleLanguage.german)
                    Text("Englisch").tag(TitleLanguage.english)
                }
                LabeledContent("Hauptordner") {
                    TextField("Albumist", text: $model.settings.rootFolderTitle)
                        .multilineTextAlignment(.trailing)
                }
                if model.settings.enabledAreas.contains(.places) {
                    // Off by default: a trip would otherwise bring a country, two cities and
                    // itself as four albums (usability test 14.11.2026).
                    Toggle(isOn: $model.settings.places.includesCities) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Städte als eigene Alben")
                            Text("Zum Beispiel Rom und Florenz zusätzlich zu Italien.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Foto in mehreren Alben erlauben", isOn: $model.settings.allowMultipleAssignments)
                NavigationLink {
                    ManagedAlbumsView()
                } label: {
                    LabeledContent("Von Albumist angelegt", value: model.managedAlbums.count.formatted())
                }
            }

            Section {
                Toggle("Ausgeblendete Fotos einbeziehen", isOn: $model.settings.privacy.includeHiddenAssets)
                Toggle("Orte online genauer bestimmen", isOn: $model.settings.privacy.allowOnlineGeocoding)
                Toggle("Screenshots aus iCloud laden", isOn: $model.settings.privacy.allowNetworkForAnalysis)
                if model.settings.privacy.allowNetworkForAnalysis {
                    Toggle("Auch über Mobilfunk", isOn: $model.settings.privacy.allowCellularDownloads)
                }
            } header: {
                Text("Datenschutz")
            } footer: {
                Text("Die Analyse läuft immer auf deinem Gerät. Für genauere Orte sendet iOS nur Koordinaten an Apple, keine Fotos. Aus iCloud werden nur Screenshots und Dokumente geladen, nie Videos, und nur im WLAN, wenn du nichts anderes einstellst.")
            }

            if rejectedCount > 0 {
                Section {
                    Button("Abgelehnte Vorschläge wieder zeigen") {
                        Task {
                            await model.restoreRejectedProposals()
                            rejectedCount = 0
                        }
                    }
                } footer: {
                    Text("\(rejectedCount) Vorschläge hast du mit „Nicht jetzt“ beiseitegelegt. Sie erscheinen nach der nächsten Analyse wieder.")
                }
            }

            Section {
                if let interrupted = model.interruptedPlan {
                    InterruptedHistoryRow(plan: interrupted)
                }
                if model.history.isEmpty && model.interruptedPlan == nil {
                    Text("Noch keine Änderungen").foregroundStyle(.secondary)
                }
                ForEach(model.history) { plan in
                    HistoryRow(plan: plan)
                }
                if model.historyHasMore {
                    Button("Ältere anzeigen") { Task { await model.loadMoreHistory() } }
                }
            } header: {
                Text("Verlauf")
            } footer: {
                // The analysis can be rebuilt, the decisions cannot: they are copied into the
                // device backup (I12), so a new iPhone or a rebuilt database gets them back.
                if let saved = model.lastSafetyBackup {
                    Text("Deine Entscheidungen, Alben und der Verlauf liegen als kleine Kopie im Backup deines Geräts. Zuletzt gesichert: \(saved.formatted(date: .abbreviated, time: .shortened)).")
                }
            }

            Section {
                Button("Analyse neu aufbauen", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Löscht nur Albumists eigene Analyse. Deine Fotos und Alben bleiben, wie sie sind.")
            }

            Section("Vollversion") {
                if purchases.isUnlocked {
                    Label("Freigeschaltet", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                } else {
                    LabeledContent("Noch kostenlos", value: "\(purchases.remainingFreeAlbums) Alben")
                    Button {
                        Task { await purchases.purchase() }
                    } label: {
                        if let product = purchases.product {
                            Text("Freischalten für \(product.displayPrice)")
                        } else {
                            Text("Freischalten")
                        }
                    }
                    .disabled(purchases.isPurchasing)
                    Button("Kauf wiederherstellen") { Task { await purchases.restore() } }
                    Button("Code einlösen") { redeeming = true }
                    if let error = purchases.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .offerCodeRedemption(isPresented: $redeeming) { _ in
                Task { await purchases.refreshEntitlements() }
            }

            #if targetEnvironment(simulator)
            Section {
                DemoLibraryCard().listRowInsets(EdgeInsets())
            }
            #endif

            Section {
                NavigationLink("Datenschutz") { PrivacyView() }
                LabeledContent("Version", value: AppInfo.version)
                DiagnosticShareRow()
                Text("Kartendaten: Natural Earth (gemeinfrei). Ortsnamen online: Apple.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Über")
            } footer: {
                Text("Die Diagnose hilft bei Problemen. Sie enthält nur Zustände und Zahlen, keine Fotos, Albumnamen oder Orte, und du siehst sie vor dem Senden.")
            }
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
        }
        .onChange(of: model.settings) { model.saveSettings() }
        .task { rejectedCount = await model.rejectedProposalCount() }
        .confirmationDialog("Analyse neu aufbauen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Neu aufbauen", role: .destructive) {
                Task {
                    await model.resetAnalysis()
                    model.startAnalysis(userInitiated: true)
                }
            }
        } message: {
            Text("Die Analyse läuft danach noch einmal über die ganze Mediathek.")
        }
    }

    private func areaBinding(_ area: OrganizationArea, _ keyPath: WritableKeyPath<OrganizationSettings, Set<OrganizationArea>>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath].contains(area) },
            set: { on in
                if on { model.settings[keyPath: keyPath].insert(area) } else { model.settings[keyPath: keyPath].remove(area) }
                if keyPath == \OrganizationSettings.enabledAreas && !on { model.settings.primaryAreas.remove(area) }
            }
        )
    }
}

/// One executed plan; opens its change receipt (with "Rückgängig machen" there).
struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan

    var body: some View {
        NavigationLink {
            PlanReceiptView(plan: plan)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((plan.confirmedAt ?? plan.createdAt).formatted(date: .abbreviated, time: .shortened))
                    Text(Counted.historyLine(plan.appliedSummary))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if model.undonePlans.contains(plan.id) {
                    Text("Rückgängig gemacht")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("history.row")
    }
}

/// An apply that was cut off (app closed). It can be finished or taken back here as well
/// as on the overview.
struct InterruptedHistoryRow: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var confirmUndo = false

    var body: some View {
        let done = plan.steps.filter { if case .succeeded = $0.state { true } else { false } }.count
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text((plan.confirmedAt ?? plan.createdAt).formatted(date: .abbreviated, time: .shortened))
                Text("Unterbrochen: \(done) von \(plan.steps.count) Schritten erledigt")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.l) { buttons }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) { buttons }
            }
            .buttonStyle(.borderless) // several buttons in one list row, each tappable on its own
            .font(.subheadline)
            .disabled(model.execution.isRunning)
        }
        .confirmationDialog("Bisherige Änderungen rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Rückgängig machen", role: .destructive) {
                Task { await model.undoInterruptedPlan() }
            }
        } message: {
            Text("Albumist entfernt die schon angelegten Alben und Zuordnungen. Deine Fotos bleiben unverändert.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Fortsetzen") {
            Task {
                await model.resumeInterruptedPlan()
                await model.refreshDerived()
            }
        }
        Button("Rückgängig") { confirmUndo = true }
        Button("So lassen") { Task { await model.keepInterruptedPlanAsIs() } }
    }
}

/// The privacy policy in plain words, readable without a network connection.
struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Deine Fotos bleiben auf deinem Gerät. Albumist hat keinen Server, kein Konto, keine Werbung und kein Tracking.")
            }
            Section("Was Albumist speichert") {
                Text("Eine kleine Datenbank auf deinem Gerät: Datum, Ort und Analyseergebnisse deiner Fotos sowie deine Entscheidungen. Keine Bildkopien. Sie ist verschlüsselt und nicht im Backup.")
                Text("Nur deine Entscheidungen, Regeln, Einstellungen, die Alben von Albumist und der Verlauf liegen zusätzlich als kleine, verschlüsselte Kopie im Backup deines Geräts, damit sie einen Gerätewechsel überstehen. Erkannter Text und Analyseergebnisse gehören nicht dazu.")
                Text("Ausweise und medizinische Dokumente werden nicht als Text gespeichert. IBANs und Kartennummern werden unkenntlich gemacht.")
            }
            Section("Was dein Gerät verlässt") {
                Text("Nur wenn „Orte online genauer bestimmen“ eingeschaltet ist, schickt iOS Koordinaten an Apple, um Ortsnamen zu finden. Fotos verlassen dein Gerät nie.")
                Text("Käufe laufen über Apple. Albumist sieht keine Zahlungsdaten.")
                Text("Die Diagnose nur, wenn du sie selbst teilst: Zustände und Zahlen, keine Fotos, Namen oder Orte.")
            }
            Section("Löschen") {
                Text("„Analyse neu aufbauen“ löscht alle Analysedaten, deine Entscheidungen bleiben. Wenn du die App löschst, ist alles weg, auch die Kopie. Deine Alben in Fotos bleiben.")
            }
            Section {
                Link("Vollständige Datenschutzerklärung", destination: AppInfo.privacyPolicyURL)
            }
        }
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }
}
