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

            Section("Verlauf") {
                if model.history.isEmpty {
                    Text("Noch keine Änderungen").foregroundStyle(.secondary)
                }
                ForEach(model.history) { plan in
                    HistoryRow(plan: plan)
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

            Section("Über") {
                NavigationLink("Datenschutz") { PrivacyView() }
                LabeledContent("Version", value: AppInfo.version)
                Text("Kartendaten: Natural Earth (gemeinfrei). Ortsnamen online: Apple.")
                    .font(.footnote).foregroundStyle(.secondary)
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

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var confirmUndo = false

    var body: some View {
        let summary = plan.summary
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text((plan.confirmedAt ?? plan.createdAt).formatted(date: .abbreviated, time: .shortened))
                Text(Counted.join([String(localized: "\(summary.newAlbums) neu"), String(localized: "\(summary.extendedAlbums) ergänzt"),
                                   String(localized: "\(summary.distinctAssets) Fotos")], separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if model.undonePlans.contains(plan.id) {
                Text("Rückgängig gemacht")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if plan.status == .completed || plan.status == .completedWithErrors {
                Button("Rückgängig") { confirmUndo = true }
                    .font(.subheadline)
                    .disabled(model.execution.isRunning)
            }
        }
        .confirmationDialog("Diese Änderungen rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Rückgängig machen", role: .destructive) {
                Task {
                    await model.undo(plan)
                    await model.refreshDerived()
                }
            }
        } message: {
            Text("Alben und Zuordnungen von Albumist werden entfernt. Deine Fotos bleiben unverändert.")
        }
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
                Text("Eine kleine Datenbank auf deinem Gerät: Datum, Ort und Analyseergebnisse deiner Fotos sowie deine Entscheidungen. Keine Bildkopien. Sie ist verschlüsselt und nicht im iCloud-Backup.")
                Text("Ausweise und medizinische Dokumente werden nicht als Text gespeichert. IBANs und Kartennummern werden unkenntlich gemacht.")
            }
            Section("Was dein Gerät verlässt") {
                Text("Nur wenn „Orte online genauer bestimmen“ eingeschaltet ist, schickt iOS Koordinaten an Apple, um Ortsnamen zu finden. Fotos verlassen dein Gerät nie.")
                Text("Käufe laufen über Apple. Albumist sieht keine Zahlungsdaten.")
            }
            Section("Löschen") {
                Text("„Analyse neu aufbauen“ löscht alle Analysedaten. Wenn du die App löschst, ist alles weg. Deine Alben in Fotos bleiben.")
            }
            Section {
                Link("Vollständige Datenschutzerklärung", destination: AppInfo.privacyPolicyURL)
            }
        }
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }
}
