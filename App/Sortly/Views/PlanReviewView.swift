import StoreKit
import SwiftUI
import SortlyCore
import SortlyEngine

/// Final preview before anything changes (prompt §7, Schritt 8–10): summary, guarantees,
/// conflicts, execution with progress, result and undo.
struct PlanReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    /// A plan built elsewhere (album merge); otherwise the accepted proposals are planned.
    var prebuilt: ChangePlan? = nil
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let result = model.execution.finished, !model.execution.isRunning {
                    ResultCard(plan: result)
                } else if model.execution.isRunning {
                    runningCard
                } else if loading {
                    ProgressView("Plan wird erstellt").frame(maxWidth: .infinity).padding(.top, 60)
                } else if let plan = model.plan {
                    planContent(plan)
                } else {
                    ContentUnavailableView("Nichts zu tun", systemImage: "checkmark.circle",
                                           description: Text("Es gibt gerade keine übernommenen Vorschläge."))
                }
                if let failure = model.execution.failure {
                    Card {
                        Label("Nicht alles hat geklappt", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(failure).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.background)
        .navigationTitle("Umsetzen")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ExecutionHaptics(execution: model.execution))
        .task {
            if !model.execution.isRunning {
                if let prebuilt { model.plan = prebuilt } else { await model.buildPlan() }
            }
            loading = false
        }
        .onDisappear {
            guard !model.execution.isRunning else { return }
            model.execution.finished = nil
            model.execution.failure = nil
        }
    }

    // MARK: Plan

    @ViewBuilder
    private func planContent(_ plan: ChangePlan) -> some View {
        let summary = plan.summary
        Text("Das passiert jetzt").font(.title2.weight(.bold))
        Card {
            row("folder.badge.plus", "Neue Ordner", summary.newFolders)
            row("rectangle.stack.badge.plus", "Neue Alben", summary.newAlbums)
            row("plus.rectangle.on.rectangle", "Ergänzte Alben", summary.extendedAlbums)
            row("photo", "Betroffene Fotos und Videos", summary.distinctAssets)
            if summary.totalAssignments != summary.distinctAssets {
                row("square.on.square", "Album-Zuordnungen", summary.totalAssignments)
            }
            if summary.renamedCollections > 0 { row("pencil", "Umbenannt", summary.renamedCollections) }
            if summary.movedCollections > 0 { row("arrow.right.square", "Verschoben", summary.movedCollections) }
            if summary.removedMemberships > 0 { row("minus.rectangle", "Aus Alben genommen", summary.removedMemberships) }
            if summary.deletedContainers > 0 { row("rectangle.stack.badge.minus", "Entfernte Alben", summary.deletedContainers) }
        }

        Card {
            Label {
                Text("\(summary.originalsDeleted) Originale gelöscht")
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent)
            }
            Label {
                Text("\(summary.originalCopiesCreated) Kopien angelegt")
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent)
            }
            Text("Fotos werden nur in Alben einsortiert. Die Originale bleiben, wo sie sind, und jede Änderung lässt sich rückgängig machen.")
                .font(.footnote).foregroundStyle(.secondary)
        }

        if !plan.conflicts.isEmpty {
            Card {
                Label("Bitte prüfen", systemImage: "exclamationmark.triangle").font(.headline)
                ForEach(Array(plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                    Text(ConflictText.text(conflict, inventory: model.inventory))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }

        let blocking = plan.conflicts.contains(where: \.isBlocking)
        let albums = summary.newAlbums + summary.extendedAlbums
        if !purchases.allows(albums: albums) {
            UnlockCard(albumsInPlan: albums)
        } else {
            Button {
                Task { await model.execute(plan) }
            } label: {
                Text("Jetzt umsetzen")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(blocking || plan.steps.isEmpty)
            if blocking {
                Text("Erst die markierten Punkte klären. Ändere dazu den Vorschlag unter „Anpassen“.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !purchases.isUnlocked && albums > 0 && purchases.allows(albums: albums) {
                Text("Noch \(purchases.remainingFreeAlbums) Alben kostenlos.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ value: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value.formatted()).monospacedDigit().font(.body.weight(.semibold))
        }
    }

    private var runningCard: some View {
        Card {
            Text("Alben werden angelegt").font(.headline)
            ProgressView(value: Double(model.execution.completedSteps), total: Double(max(1, model.execution.totalSteps)))
                .tint(Theme.accent)
            Text("\(model.execution.completedSteps.formatted()) von \(model.execution.totalSteps.formatted()) Schritten")
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            Text("Du kannst die App dabei offen lassen. Bricht etwas ab, setzt SORTLY beim nächsten Start sicher fort.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Result of an executed plan with undo.
/// Haptic feedback when the changes are done, or when something went wrong.
/// (A separate modifier keeps the screen's body quick to type-check.)
private struct ExecutionHaptics: ViewModifier {
    var execution: AppModel.ExecutionState

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: execution.finished?.id) { (old: SortlyID?, new: SortlyID?) in
                old == nil && new != nil
            }
            .sensoryFeedback(.error, trigger: execution.failure) { (old: String?, new: String?) in
                old == nil && new != nil
            }
    }
}

struct ResultCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.requestReview) private var requestReview
    var plan: ChangePlan
    @State private var confirmUndo = false
    private static let reviewKey = "review.askedAfterFirstAlbums"

    var body: some View {
        let summary = plan.summary
        let failed = plan.steps.filter { if case .failed = $0.state { true } else { false } }.count
        Card {
            Label {
                Text(failed == 0 ? "Fertig" : "Teilweise fertig").font(.title3.weight(.bold))
            } icon: {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(failed == 0 ? Theme.accent : Theme.tint(for: .documents))
            }
            Text(Counted.join([String(localized: "\(summary.newAlbums) neue Alben"), String(localized: "\(summary.extendedAlbums) ergänzt"),
                               String(localized: "\(summary.distinctAssets) Fotos einsortiert")], separator: ", ") + ".")
                .font(.subheadline)
            if failed > 0 {
                Text("\(failed) Schritte konnten nicht ausgeführt werden. Sie werden beim nächsten Durchgang erneut versucht.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Rückgängig machen") { confirmUndo = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .task {
            // Ask for a rating once, at the moment the first albums are done (never after errors).
            let summary = plan.summary
            guard !UITestSupport.isRunning, summary.newAlbums + summary.extendedAlbums > 0,
                  !plan.steps.contains(where: { if case .failed = $0.state { true } else { false } }),
                  !UserDefaults.standard.bool(forKey: Self.reviewKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.reviewKey)
            try? await Task.sleep(for: .seconds(2))
            requestReview()
        }
        .confirmationDialog("Änderungen rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Rückgängig machen", role: .destructive) {
                Task { await model.undo(plan) }
            }
        } message: {
            Text("SORTLY entfernt die angelegten Alben und Zuordnungen wieder. Deine Fotos bleiben unverändert.")
        }
    }
}

enum ConflictText {
    static func text(_ conflict: PlanConflict, inventory: CollectionInventory) -> String {
        func title(_ id: CollectionID) -> String { inventory[id]?.title ?? "?" }
        switch conflict {
        case .duplicatePlannedTitle(let title, _, _):
            return String(localized: "Zwei neue Alben heißen „\(title)“. Bitte benenne eines um.")
        case .titleExistsInFolder(let title, _):
            return String(localized: "Es gibt schon ein anderes Album „\(title)“. Das neue bekommt einen Zusatz.")
        case .albumMissing(let id):
            return String(localized: "Das Album „\(title(id))“ gibt es nicht mehr.")
        case .albumNotEditable(let id):
            return String(localized: "„\(title(id))“ kann nicht bearbeitet werden.")
        case .albumChangedSincePreview(let id):
            return String(localized: "„\(title(id))“ wurde inzwischen geändert. Bitte prüfe den Vorschlag erneut.")
        case .assetsUnavailable(let count):
            return String(localized: "\(count) Fotos sind nicht mehr in der Mediathek.")
        case .writeAccessMissing:
            return String(localized: "SORTLY hat keinen vollen Zugriff auf deine Fotos.")
        }
    }
}

/// Shown when a plan needs more albums than are still free.
struct UnlockCard: View {
    @Environment(Purchases.self) private var purchases
    var albumsInPlan: Int
    @State private var redeeming = false

    var body: some View {
        Card {
            Label("SORTLY freischalten", systemImage: "lock.open").font(.headline)
            Text("Dieser Plan ordnet \(albumsInPlan) Alben. Kostenlos sind noch \(purchases.remainingFreeAlbums). Mit einem einmaligen Kauf kannst du unbegrenzt sortieren, ohne Abo.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                Task { await purchases.purchase() }
            } label: {
                if purchases.isPurchasing {
                    ProgressView().tint(.white)
                } else if let product = purchases.product {
                    Text("Freischalten für \(product.displayPrice)")
                } else {
                    Text("Freischalten")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(purchases.isPurchasing)
            HStack {
                Button("Kauf wiederherstellen") { Task { await purchases.restore() } }
                Spacer()
                Button("Code einlösen") { redeeming = true }
            }
            .font(.subheadline)
            .offerCodeRedemption(isPresented: $redeeming) { _ in
                Task { await purchases.refreshEntitlements() }
            }
            Text("Tipp: Du kannst auch weniger Vorschläge auf einmal übernehmen.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error = purchases.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}
