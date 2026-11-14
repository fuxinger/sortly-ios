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
    /// Albums of the plan that is running, for the "photos fly into albums" show.
    @State private var show: [SortingShow.Album]?
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let show {
                    SortingShow(albums: show) {
                        withAnimation(.smooth(duration: 0.45)) { self.show = nil }
                    }
                    .transition(.opacity)
                } else if let result = model.execution.finished, !model.execution.isRunning {
                    ResultCard(plan: result)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
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
        .modifier(ExecutionHaptics(execution: model.execution, holdSuccess: show != nil))
        .task {
            await model.refreshAccess()
            if !model.execution.isRunning {
                if let prebuilt { model.plan = prebuilt } else { await model.buildPlan() }
            }
            loading = false
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Settings app: the full-access card disappears by itself.
            if phase == .active { Task { await model.refreshAccess() } }
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
            if summary.newFolders > 0 { row("folder.badge.plus", "Neue Ordner", summary.newFolders) }
            row("rectangle.stack.badge.plus", "Neue Alben", summary.newAlbums)
            if summary.extendedAlbums > 0 { row("plus.rectangle.on.rectangle", "Ergänzte Alben", summary.extendedAlbums) }
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
        if model.access == .limited && !UITestSupport.isRunning {
            FullAccessCard()
        } else if !purchases.allows(albums: albums) {
            UnlockCard(albumsInPlan: albums, onLimit: limitToFreeAlbums)
        } else {
            Button {
                let albums = SortingShow.albums(from: plan, inventory: model.inventory)
                if !albums.isEmpty { show = albums }
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

    /// "Die ersten N jetzt anlegen", only for plans built from accepted suggestions.
    private var limitToFreeAlbums: (() -> Void)? {
        guard prebuilt == nil, purchases.remainingFreeAlbums > 0 else { return nil }
        let free = purchases.remainingFreeAlbums
        return { Task { await model.keepFirstAccepted(free) } }
    }

    /// One line of the summary. Icons share one width so the titles line up.
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

    private var runningCard: some View {
        Card {
            Text("Alben werden angelegt").font(.headline)
            ProgressView(value: Double(model.execution.completedSteps), total: Double(max(1, model.execution.totalSteps)))
                .tint(Theme.accent)
            Text("\(model.execution.completedSteps.formatted()) von \(model.execution.totalSteps.formatted()) Schritten")
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            Text("Du kannst die App dabei offen lassen. Bricht etwas ab, setzt Albumist beim nächsten Start sicher fort.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Haptic feedback when the changes are done, or when something went wrong.
/// (A separate modifier keeps the screen's body quick to type-check.)
private struct ExecutionHaptics: ViewModifier {
    var execution: AppModel.ExecutionState
    /// While the sorting show plays, the success tap waits for its end.
    var holdSuccess: Bool

    func body(content: Content) -> some View {
        let finished: SortlyID? = holdSuccess ? nil : execution.finished?.id
        return content
            .sensoryFeedback(.success, trigger: finished) { (old: SortlyID?, new: SortlyID?) in
                old == nil && new != nil
            }
            .sensoryFeedback(.error, trigger: execution.failure) { (old: String?, new: String?) in
                old == nil && new != nil
            }
    }
}

/// Result of an executed plan: what happened, a way to see it in Photos, and undo.
struct ResultCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.requestReview) private var requestReview
    var plan: ChangePlan
    @State private var confirmUndo = false
    @State private var appeared = false
    @Environment(\.openURL) private var openURL
    private static let reviewKey = "review.askedAfterFirstAlbums"

    var body: some View {
        let summary = plan.summary
        let failed = plan.steps.filter { if case .failed = $0.state { true } else { false } }.count
        let isUndo = plan.reverts != nil
        Card {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : isUndo ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(failed == 0 ? Theme.accent : Theme.tint(for: .documents))
                    .symbolEffect(.bounce, value: appeared)
                    .accessibilityHidden(true)
                Text(isUndo ? (failed == 0 ? "Rückgängig gemacht" : "Teilweise rückgängig gemacht") : (failed == 0 ? "Fertig" : "Teilweise fertig"))
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if isUndo {
                        Text("Albumist hat seine Alben und Zuordnungen wieder entfernt. Deine Fotos sind unverändert.")
                    } else {
                        Text(Counted.join([String(localized: "\(summary.newAlbums) neue Alben"), String(localized: "\(summary.extendedAlbums) ergänzt"),
                                           String(localized: "\(summary.distinctAssets) Fotos einsortiert")], separator: ", ") + ".")
                    }
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
                if failed > 0 {
                    Text("\(failed) Schritte konnten nicht ausgeführt werden. Sie werden beim nächsten Durchgang erneut versucht.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            if let photos = URL(string: "photos-redirect://") {
                Button("In Fotos ansehen") { openURL(photos) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if !isUndo && !model.undonePlans.contains(plan.id) {
                Button("Rückgängig machen") { confirmUndo = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .onAppear { appeared = true }
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
            Text("Albumist entfernt die angelegten Alben und Zuordnungen wieder. Deine Fotos bleiben unverändert.")
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
            return String(localized: "Albumist hat keinen vollen Zugriff auf deine Fotos.")
        }
    }
}

/// Shown instead of "Jetzt umsetzen" when only selected photos are shared: Photos lets an
/// app create albums only with full access, so the plan would fail half way.
struct FullAccessCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            Label("Voller Zugriff nötig", systemImage: "photo.on.rectangle.angled").font(.headline)
            Text("Albumist kann Alben nur anlegen, wenn du alle Fotos freigibst. Gerade sind nur ausgewählte Fotos freigegeben.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Einstellungen › Apps › Albumist › Fotos › Voller Zugriff")
                .font(.footnote).foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Einstellungen öffnen") { openURL(url) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// Shown when a plan needs more albums than are still free.
struct UnlockCard: View {
    @Environment(Purchases.self) private var purchases
    var albumsInPlan: Int
    /// Shrinks the plan to the albums that are still free ("Die ersten N jetzt anlegen").
    var onLimit: (() -> Void)? = nil
    @State private var redeeming = false

    var body: some View {
        Card {
            Label("Albumist freischalten", systemImage: "lock.open").font(.headline)
            Text("Dieser Plan ordnet \(albumsInPlan) Alben. Kostenlos sind noch \(purchases.remainingFreeAlbums). Mit einem einmaligen Kauf kannst du unbegrenzt sortieren, ohne Abo.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                Task { await purchases.purchase() }
            } label: {
                if purchases.isPurchasing {
                    ProgressView().tint(Theme.onAccent)
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
            if let onLimit {
                Button("Die ersten \(purchases.remainingFreeAlbums) jetzt kostenlos anlegen", action: onLimit)
                    .buttonStyle(SecondaryButtonStyle())
                Text("Die übrigen Vorschläge bleiben offen und laufen dir nicht weg.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Tipp: Du kannst auch weniger Vorschläge auf einmal übernehmen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = purchases.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}
