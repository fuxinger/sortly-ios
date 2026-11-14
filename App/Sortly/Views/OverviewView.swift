import SwiftUI
import SortlyCore
import SortlyEngine

/// Overview (direction A): organized share, analysis state, open proposals, areas.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The ring grows with the text size, so "100 %" still fits inside at the largest sizes.
    @ScaledMetric(relativeTo: .title3) private var ringSide: CGFloat = 84
    @State private var showSettings = false
    /// Lives here, not in the starter card: the card disappears once its albums are accepted.
    @State private var showStarterPlan = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                if let interrupted = model.interruptedPlan {
                    InterruptedPlanCard(plan: interrupted)
                }
                statusCard
                analysisCard
                if model.history.isEmpty && model.acceptedProposals.isEmpty {
                    StarterSetCard { showStarterPlan = true }
                }
                if !model.openProposals.isEmpty {
                    NavigationLink {
                        ProposalListView(area: nil)
                    } label: {
                        Text("\(model.openProposals.count) Vorschläge prüfen")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if !model.acceptedProposals.isEmpty {
                    NavigationLink {
                        PlanReviewView()
                    } label: {
                        Text("\(model.acceptedProposals.count) übernommene Vorschläge umsetzen")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                #if targetEnvironment(simulator)
                if !DemoLibrary.shared.isDone { DemoLibraryCard() }
                #endif
                AtlasTeaser()
                areasSection
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .navigationTitle("Übersicht")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Einstellungen")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .navigationDestination(isPresented: $showStarterPlan) { PlanReviewView() }
        .refreshable { await model.refreshDerived() }
    }

    private var statusCard: some View {
        // Largest text sizes stack the ring above the text instead of squeezing it.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.m))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.l))
        return Card {
            layout {
                ProgressRing(fraction: model.progress.fullyShare)
                    .frame(width: min(ringSide, 150), height: min(ringSide, 150))
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("\(model.progress.fully.formatted()) von \(model.progress.total.formatted()) sortiert")
                        .font(.headline)
                        .monospacedDigit()
                    Text(primaryAreasText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var primaryAreasText: String {
        // Quoted, so "Länder und Orte" and "Reisen" do not read as one list of three.
        let open = Locale.current.quotationBeginDelimiter ?? "\"", close = Locale.current.quotationEndDelimiter ?? "\""
        let names = OrganizationArea.available.filter { model.settings.primaryAreas.contains($0) }
            .map { open + String(localized: $0.titleResource) + close }
        return String(localized: "Gezählt werden deine Hauptbereiche: \(names.formatted(.list(type: .and))).")
    }

    @ViewBuilder
    private var analysisCard: some View {
        Card {
            if model.analysis.isRunning {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(model.analysis.stage?.label ?? "Analyse läuft").font(.headline)
                        Spacer()
                        Button { model.pauseAnalysis() } label: { TapTarget("Pause") }
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(model.analysis.stage?.label ?? "Analyse läuft").font(.headline)
                        Button { model.pauseAnalysis() } label: { TapTarget("Pause") }
                    }
                }
                if model.history.isEmpty && model.managedAlbums.isEmpty {
                    ScanShow()
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ProgressView(value: model.analysis.overall)
                        .tint(Theme.accent)
                        .animation(.smooth, value: model.analysis.overall)
                    if let stage = model.analysis.stage {
                        let steps = AnalysisPipeline.Stage.allCases.count
                        Group {
                            if model.analysis.total > 0 {
                                Text("Schritt \(stage.number) von \(steps) · \(model.analysis.completed.formatted()) von \(model.analysis.total.formatted())")
                            } else {
                                Text("Schritt \(stage.number) von \(steps)")
                            }
                        }
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine) // one element: bar plus "150 von 240"
            } else if let reason = model.analysis.lastReport?.pausedBecause {
                Text(reason.label).font(.headline)
                Text("Die Analyse setzt genau dort fort, wo sie aufgehört hat.").font(.subheadline).foregroundStyle(.secondary)
                Button("Fortsetzen") { model.startAnalysis(userInitiated: true) }.buttonStyle(SecondaryButtonStyle())
            } else {
                let stack = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
                    : AnyLayout(HStackLayout())
                stack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyse aktuell").font(.headline)
                        if let date = model.analysis.lastRun {
                            Text("Zuletzt \(date.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Neue Fotos werden beim nächsten Start erkannt.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button { model.startAnalysis() } label: { TapTarget("Neu prüfen") }
                }
                if let pending = model.analysis.lastReport?.placesPendingOnline, pending > 0 {
                    Label("\(pending) Orte werden später genauer bestimmt.", systemImage: "moon.zzz")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let waiting = model.analysis.lastReport?.textWaitingForOriginal, waiting > 0 {
                    Label("\(waiting) Dokumente liegen nur in iCloud und werden später gelesen.", systemImage: "icloud")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var areasSection: some View {
        let byArea = Dictionary(grouping: model.proposals, by: \.kind.area)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("BEREICHE")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Spacing.s)
                .padding(.leading, Theme.Spacing.xs)
            VStack(spacing: 0) {
                let areas = OrganizationArea.available.filter { model.settings.enabledAreas.contains($0) }
                ForEach(Array(areas.enumerated()), id: \.element) { index, area in
                    NavigationLink {
                        ProposalListView(area: area)
                    } label: {
                        areaRow(area, proposals: byArea[area] ?? [])
                    }
                    .buttonStyle(.plain)
                    if index < areas.count - 1 { Divider().padding(.leading, 66) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func areaRow(_ area: OrganizationArea, proposals: [AlbumProposal]) -> some View {
        let open = proposals.filter { model.decisions[$0.id] == nil && model.match(for: $0)?.status != .alreadyComplete }.count
        let existing = proposals.filter { p in
            model.match(for: p).map { [MatchStatus.alreadyComplete, .extendable, .possibleMatch].contains($0.status) } ?? false
        }.count
        // "0 Alben gefunden" read like an error: only mention albums that exist.
        var parts = [String(localized: "\(proposals.count) Vorschläge")]
        if existing > 0 { parts.append(String(localized: "\(existing) davon in deinen Alben")) }
        let summary = Counted.join(parts)
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(area.title).font(.body.weight(.medium))
            Group {
                if proposals.isEmpty {
                    Text("Noch keine Vorschläge")
                } else {
                    Text(summary)
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        let chevron = Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        return Group {
            if typeSize.isAccessibilitySize {
                // Largest text sizes: icon and badge on top, the text gets the full width.
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        IconTile(systemName: area.symbol, tint: area.tint)
                        Spacer()
                        if open > 0 { StatusBadge(text: "\(open) offen") }
                        chevron
                    }
                    text
                }
            } else {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemName: area.symbol, tint: area.tint)
                    text
                    Spacer()
                    if open > 0 { StatusBadge(text: "\(open) offen") }
                    chevron
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .contentShape(Rectangle())
    }
}

extension OrganizationArea {
    /// Same texts as `title`, as a resource for string interpolation.
    var titleResource: LocalizedStringResource {
        switch self {
        case .places: "Länder und Orte"
        case .trips: "Reisen"
        case .frequentPlaces: "Häufige Orte"
        case .peopleAndPets: "Personen und Tiere"
        case .messenger: "Messenger"
        case .screenshots: "Screenshots"
        case .imageCategories: "Themen"
        case .documents: "Dokumente"
        case .chronology: "Jahre und Monate"
        case .mediaTypes: "Medientypen"
        }
    }
}

/// A short text action with Apple's minimum tap area of 44 pt (the label alone is ~18 pt tall).
private struct TapTarget: View {
    var title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Shown after the app was closed while a plan ran: the rest can be done now, or what
/// already happened can be taken back.
struct InterruptedPlanCard: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var confirmUndo = false

    var body: some View {
        let done = plan.steps.filter { if case .succeeded = $0.state { true } else { false } }.count
        Card {
            Label("Umsetzen wurde unterbrochen", systemImage: "pause.circle").font(.headline)
            Text("\(done) von \(plan.steps.count) Schritten sind erledigt. Albumist kann den Rest jetzt anlegen oder alles wieder zurücknehmen. Nichts wird doppelt angelegt.")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.execution.isRunning {
                ProgressView(value: Double(model.execution.completedSteps), total: Double(max(1, model.execution.totalSteps)))
                    .tint(Theme.accent)
            } else {
                Button("Fortsetzen") { Task { await model.resumeInterruptedPlan() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Rückgängig machen") { confirmUndo = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let failure = model.execution.failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Bisherige Änderungen rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Rückgängig machen", role: .destructive) {
                Task { await model.undoInterruptedPlan() }
            }
        } message: {
            Text("Albumist entfernt die schon angelegten Alben und Zuordnungen. Deine Fotos bleiben unverändert.")
        }
    }
}

/// First use: the best albums of the library, ready to be created with one tap.
struct StarterSetCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    var onStart: () -> Void

    var body: some View {
        let limit = purchases.isUnlocked || Purchases.unlockedForUITests ? 10 : min(10, purchases.remainingFreeAlbums)
        let set = model.starterSet(limit: limit)
        if set.count >= 3 {
            Card {
                Text("Dein Startpaket").font(.headline)
                Text("Die \(set.count) besten Alben aus deiner Mediathek, fertig zum Anlegen. Du siehst vorher genau, was passiert.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: -14) {
                    ForEach(Array(set.prefix(5).enumerated()), id: \.element.id) { index, proposal in
                        AssetThumbnail(id: proposal.coverAssetID ?? AssetID(""), side: 64)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.background, lineWidth: 2))
                            .zIndex(Double(5 - index))
                    }
                }
                .accessibilityHidden(true)
                Text(ListFormatter.localizedString(byJoining: set.prefix(3).map { model.userTitles[$0.id] ?? $0.title })
                     + (set.count > 3 ? " …" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2)
                Button {
                    model.accept(set)
                    onStart()
                } label: {
                    if purchases.isUnlocked {
                        Text("\(set.count) Alben anlegen")
                    } else {
                        Text("\(set.count) Alben kostenlos anlegen")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
