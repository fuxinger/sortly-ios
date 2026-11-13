import SwiftUI
import SortlyCore
import SortlyEngine

/// Overview (direction A): organized share, analysis state, open proposals, areas.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                statusCard
                analysisCard
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
        .refreshable { await model.refreshDerived() }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: Theme.Spacing.l) {
                ProgressRing(fraction: model.progress.fullyShare)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("\(model.progress.fully.formatted()) von \(model.progress.total.formatted()) organisiert")
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
        let names = OrganizationArea.allCases.filter { model.settings.primaryAreas.contains($0) }.map { String(localized: $0.titleResource) }
        return String(localized: "Gezählt werden deine Hauptbereiche: \(names.formatted(.list(type: .and))).")
    }

    @ViewBuilder
    private var analysisCard: some View {
        Card {
            if model.analysis.isRunning {
                HStack {
                    Text(model.analysis.stage?.label ?? "Analyse läuft").font(.headline)
                    Spacer()
                    Button("Pause") { model.pauseAnalysis() }.font(.subheadline.weight(.semibold))
                }
                ProgressView(value: model.analysis.fraction)
                    .tint(Theme.accent)
                if model.analysis.total > 0 {
                    Text("\(model.analysis.completed.formatted()) von \(model.analysis.total.formatted())")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let reason = model.analysis.lastReport?.pausedBecause {
                Text(reason.label).font(.headline)
                Text("Die Analyse setzt genau dort fort, wo sie aufgehört hat.").font(.subheadline).foregroundStyle(.secondary)
                Button("Fortsetzen") { model.startAnalysis() }.buttonStyle(SecondaryButtonStyle())
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyse aktuell").font(.headline)
                        if let date = model.analysis.lastRun {
                            Text("Zuletzt \(date.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Neue Fotos werden beim nächsten Start erkannt.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Neu prüfen") { model.startAnalysis() }.font(.subheadline.weight(.semibold))
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
                let areas = OrganizationArea.allCases.filter { model.settings.enabledAreas.contains($0) }
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
        return HStack(spacing: Theme.Spacing.m) {
            IconTile(systemName: area.symbol, tint: area.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(area.title).font(.body.weight(.medium))
                Group {
                    if proposals.isEmpty {
                        Text("Noch keine Vorschläge")
                    } else {
                        Text("\(proposals.count) Vorschläge · \(existing) Alben gefunden")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if open > 0 { StatusBadge(text: "\(open) offen") }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
