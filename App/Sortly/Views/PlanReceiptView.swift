import SwiftUI
import SortlyCore

/// The change receipt of one executed plan (I01): what Albumist really changed, album by
/// album, read from the execution journal, and what it did not touch. Opened from
/// Einstellungen › Verlauf and from the result after "Jetzt umsetzen".
struct PlanReceiptView: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var receipt: PlanReceipt?
    @State private var undo: PlanReceipt?
    @State private var showAllAlbums = false
    @State private var confirmUndo = false
    /// "Erneut versuchen": the plan with what is missing, opened in the normal review.
    @State private var retry: ChangePlan?
    @State private var showRetry = false
    @State private var nothingToRetry = false
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    private let collapsedCount = 12

    var body: some View {
        List {
            if let receipt {
                header(receipt)
                changes(receipt)
                originals(receipt)
                if !receipt.isComplete { problems(receipt) }
                if !receipt.albums.isEmpty { albums(receipt) }
                undoSection(receipt)
            }
        }
        .navigationTitle("Änderungsbeleg")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let receipt {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: ReceiptText.text(receipt, undo: undo, inventory: model.inventory)) {
                        Label("Beleg teilen", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: model.undonePlans.contains(plan.id)) {
            let loaded = await model.receipt(for: plan)
            receipt = loaded.plan
            undo = loaded.undo
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
        // On the list, not inside it: a destination inside a lazy list is ignored.
        .navigationDestination(isPresented: $showRetry) {
            if let retry { PlanReviewView(prebuilt: retry) }
        }
        .alert("Nichts mehr zu tun", isPresented: $nothingToRetry) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Was gefehlt hat, ist inzwischen erledigt oder das Album gibt es nicht mehr.")
        }
    }

    // MARK: Sections

    private func header(_ receipt: PlanReceipt) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Group {
                    if receipt.isComplete {
                        Label("Vollständig umgesetzt", systemImage: "checkmark.seal.fill")
                    } else {
                        Label("Teilweise umgesetzt", systemImage: "exclamationmark.circle.fill")
                    }
                }
                .font(.headline)
                .foregroundStyle(receipt.isComplete ? Theme.accent : Theme.tint(for: .documents))
                Text(receipt.startedAt.formatted(date: .long, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Gezählt wird nur, was Albumist danach in deiner Mediathek nachgeprüft hat.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    private func changes(_ receipt: PlanReceipt) -> some View {
        Section {
            if receipt.albumsCreated > 0 { row("rectangle.stack.badge.plus", "Neue Alben", receipt.albumsCreated) }
            if receipt.albumsExtended > 0 { row("plus.rectangle.on.rectangle", "Ergänzte Alben", receipt.albumsExtended) }
            if !receipt.createdFolders.isEmpty { row("folder.badge.plus", "Neue Ordner", receipt.createdFolders.count) }
            row("photo", "Fotos einsortiert", receipt.photosAdded)
            if receipt.assignmentsAdded != receipt.photosAdded { row("square.on.square", "Album-Zuordnungen", receipt.assignmentsAdded) }
            if receipt.renamed > 0 { row("pencil", "Umbenannt", receipt.renamed) }
            if receipt.moved > 0 { row("arrow.right.square", "Verschoben", receipt.moved) }
            if receipt.membershipsRemoved > 0 { row("minus.rectangle", "Aus Alben genommen", receipt.membershipsRemoved) }
            if receipt.containersDeleted > 0 { row("rectangle.stack.badge.minus", "Entfernte Alben und Ordner", receipt.containersDeleted) }
        } header: {
            Text("Das hat Albumist geändert")
        } footer: {
            if receipt.unavailablePhotos > 0 {
                Text("\(receipt.unavailablePhotos) Fotos waren beim Umsetzen nicht mehr in deiner Mediathek und wurden nicht einsortiert.")
            }
        }
    }

    private func originals(_ receipt: PlanReceipt) -> some View {
        Section {
            guarantee(Text("\(receipt.originalsDeleted) Originale gelöscht"))
            guarantee(Text("\(receipt.originalsEdited) Originale bearbeitet"))
            guarantee(Text("\(receipt.originalCopiesCreated) Kopien angelegt"))
        } header: {
            Text("Deine Originale")
        } footer: {
            Text("Albumist ordnet Fotos nur Alben zu. Löschen, Bearbeiten oder Kopieren von Fotos gibt es in Albumist nicht. Ein Album verweist nur auf deine Fotos.")
        }
    }

    /// Guided repair (I16): what is missing and why, in plain words, and the ways out:
    /// try the missing part again, take everything back (below), or leave it as it is.
    private func problems(_ receipt: PlanReceipt) -> some View {
        Section {
            if receipt.failedSteps > 0 {
                Text("\(receipt.failedSteps) Schritte konnten nicht ausgeführt werden.")
            }
            ForEach(StepProblemText.texts(receipt.problems), id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if receipt.unconfirmedSteps > 0 {
                Text("\(receipt.unconfirmedSteps) Schritte konnte Albumist in der Mediathek nicht nachprüfen. Sie zählen hier nicht mit.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if canRepair(receipt) {
                Button {
                    Task {
                        if let missing = await model.retryPlan(for: plan) {
                            retry = missing
                            showRetry = true
                        } else {
                            nothingToRetry = true
                        }
                    }
                } label: {
                    Label("Fehlendes erneut versuchen", systemImage: "arrow.clockwise")
                }
                .disabled(model.execution.isRunning)
                .accessibilityIdentifier("receipt.retry")
            }
            DiagnosticShareRow()
        } header: {
            Text("Nicht erledigt")
        } footer: {
            if canRepair(receipt) {
                Text("Erneut versuchen legt nur an, was fehlt; nichts wird doppelt angelegt, und du siehst vorher, was passiert. Du kannst es auch so lassen: Das Erledigte bleibt, und die fehlenden Fotos schlägt Albumist bei der nächsten Analyse wieder vor.")
            }
        }
    }

    /// Only plans that changed the library and were not taken back can be completed.
    private func canRepair(_ receipt: PlanReceipt) -> Bool {
        !receipt.isUndo && receipt.failedSteps > 0 && !model.undonePlans.contains(plan.id)
            && plan.steps.contains { $0.state.canBeRetried }
    }

    private func albums(_ receipt: PlanReceipt) -> some View {
        let visible = showAllAlbums ? receipt.albums : Array(receipt.albums.prefix(collapsedCount))
        return Section {
            ForEach(visible) { album in
                ReceiptAlbumRow(album: album, title: title(album))
            }
            if receipt.albums.count > collapsedCount {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { showAllAlbums.toggle() }
                } label: {
                    if showAllAlbums {
                        Text("Weniger anzeigen")
                    } else {
                        Text("Alle \(receipt.albums.count) Alben anzeigen")
                    }
                }
            }
        } header: {
            Text("Alben")
        } footer: {
            Text("Namen wie beim Umsetzen. Was du danach in Fotos geändert hast, respektiert Albumist.")
        }
    }

    @ViewBuilder
    private func undoSection(_ receipt: PlanReceipt) -> some View {
        if let undo {
            Section("Rückgängig gemacht") {
                Text(undo.startedAt.formatted(date: .long, time: .shortened))
                if undo.containersDeleted > 0 { row("rectangle.stack.badge.minus", "Entfernte Alben und Ordner", undo.containersDeleted) }
                if undo.membershipsRemoved > 0 { row("minus.rectangle", "Aus Alben genommen", undo.membershipsRemoved) }
                if !undo.isComplete {
                    Text("Was Albumist nicht zurücknehmen konnte, bleibt, wie es ist.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else if !receipt.isUndo && !model.undonePlans.contains(plan.id)
                    && (plan.status == .completed || plan.status == .completedWithErrors) {
            Section {
                Button("Rückgängig machen", role: .destructive) { confirmUndo = true }
                    .disabled(model.execution.isRunning)
                    .accessibilityIdentifier("receipt.undo")
            } footer: {
                Text("Entfernt nur die neuen Alben und Zuordnungen dieses Umsetzens. Deine Fotos bleiben.")
            }
        }
    }

    // MARK: Parts

    /// An album that is no longer in the library keeps the name it had when the plan ran.
    private func title(_ album: PlanReceipt.Album) -> String {
        if !album.title.isEmpty { return album.title }
        return String(localized: "Album")
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ value: Int) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: Theme.Spacing.s)
            Text(value.formatted()).monospacedDigit().font(.body.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func guarantee(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent)
        }
    }
}

private struct ReceiptAlbumRow: View {
    let album: PlanReceipt.Album
    let title: String
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            cover
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                if !album.folderPath.isEmpty {
                    Text(album.folderPath.joined(separator: " › "))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if album.failed {
                    Text("Nicht vollständig umgesetzt").font(.footnote).foregroundStyle(Theme.tint(for: .documents))
                } else if album.unconfirmed {
                    Text("Nicht nachgeprüft").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                badge
                if album.added > 0 {
                    Text("+\(album.added) Fotos").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                if album.removed > 0 {
                    Text("−\(album.removed) Fotos").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        if let id = album.coverAssetID {
            AssetThumbnail(id: id, side: side)
        } else {
            ZStack {
                Theme.accent.opacity(0.15)
                Image(systemName: album.change == .deleted ? "rectangle.stack.badge.minus" : "rectangle.stack")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch album.change {
        case .created:
            Text("Neu").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
        case .adopted:
            Text("Übernommen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case .extended:
            Text("Ergänzt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case .reduced:
            Text("Fotos herausgenommen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case .deleted:
            Text("Entfernt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

/// The receipt as plain text for "Beleg teilen": numbers and album names, no photos.
enum ReceiptText {
    static func text(_ receipt: PlanReceipt, undo: PlanReceipt?, inventory: CollectionInventory) -> String {
        var lines: [String] = []
        lines.append(String(localized: "Albumist – Änderungsbeleg"))
        lines.append(receipt.startedAt.formatted(date: .long, time: .shortened))
        lines.append("")
        func add(_ label: String.LocalizationValue, _ value: Int, always: Bool = false) {
            if always || value > 0 { lines.append("\(String(localized: label)): \(value.formatted())") }
        }
        add("Neue Alben", receipt.albumsCreated)
        add("Ergänzte Alben", receipt.albumsExtended)
        add("Neue Ordner", receipt.createdFolders.count)
        add("Fotos einsortiert", receipt.photosAdded, always: true)
        add("Aus Alben genommen", receipt.membershipsRemoved)
        add("Entfernte Alben und Ordner", receipt.containersDeleted)
        add("Originale gelöscht", receipt.originalsDeleted, always: true)
        add("Originale bearbeitet", receipt.originalsEdited, always: true)
        add("Kopien angelegt", receipt.originalCopiesCreated, always: true)
        if !receipt.albums.isEmpty {
            lines.append("")
            lines.append(String(localized: "Alben"))
            for album in receipt.albums {
                let path = (album.folderPath + [album.title.isEmpty ? String(localized: "Album") : album.title]).joined(separator: " › ")
                var detail: [String] = []
                if album.added > 0 { detail.append("+\(album.added)") }
                if album.removed > 0 { detail.append("−\(album.removed)") }
                lines.append("• \(path)" + (detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))"))
            }
        }
        if let undo {
            lines.append("")
            lines.append(String(localized: "Rückgängig gemacht: \(undo.startedAt.formatted(date: .long, time: .shortened))"))
        }
        return lines.joined(separator: "\n")
    }
}
