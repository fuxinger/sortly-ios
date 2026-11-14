import SwiftUI
import SortlyCore
import SortlyEngine

/// List of proposals, optionally for one area.
struct ProposalListView: View {
    @Environment(AppModel.self) private var model
    var area: OrganizationArea?

    private var proposals: [AlbumProposal] {
        model.proposals
            .filter { area == nil || $0.kind.area == area }
            .sorted { lhs, rhs in
                let l = model.decisions[lhs.id] == nil ? 0 : 1, r = model.decisions[rhs.id] == nil ? 0 : 1
                return (l, -lhs.assetIDs.count, lhs.title) < (r, -rhs.assetIDs.count, rhs.title)
            }
    }

    var body: some View {
        List {
            if proposals.isEmpty {
                ContentUnavailableView("Keine Vorschläge", systemImage: "checkmark.circle",
                                       description: Text("Für diesen Bereich gibt es gerade nichts zu tun."))
            }
            ForEach(proposals) { proposal in
                // Destination-based link: this list is itself pushed by a destination-based
                // link, and a value-based link here found no destination (row did nothing,
                // a yellow warning triangle appeared on the way back).
                NavigationLink {
                    ProposalDetailView(proposal: proposal)
                } label: {
                    ProposalRow(proposal: proposal)
                }
            }
        }
        .navigationTitle(area?.title ?? "Vorschläge")
        .toolbar {
            if !proposals.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Alle sicheren übernehmen") { acceptAllSafe() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Weitere Aktionen")
                }
            }
        }
    }

    /// Accepts only proposals that are at least "likely", need no name and have a clear
    /// recommended action – never sensitive ones (prompt §8).
    private func acceptAllSafe() {
        for p in proposals where model.decisions[p.id] == nil && p.reliability >= .likely && !p.isSensitive && !p.requiresUserName {
            let decision = model.recommendedDecision(for: p)
            if decision.isAccepted { model.setDecision(decision, for: p) }
        }
    }
}

struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    var proposal: AlbumProposal

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AssetThumbnail(id: proposal.coverAssetID ?? AssetID(""), side: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.userTitles[proposal.id] ?? proposal.title).font(.body.weight(.medium)).lineLimit(2)
                Text("\(proposal.assetIDs.count) Aufnahmen").font(.footnote).foregroundStyle(.secondary)
                if let status = model.match(for: proposal)?.status {
                    StatusBadge(text: status.label, tint: status.tint)
                }
            }
            Spacer(minLength: 0)
            decisionMark
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var decisionMark: some View {
        switch model.decisions[proposal.id] {
        case .reject:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).accessibilityLabel("Abgelehnt")
        case .some(let d) where d.isAccepted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Übernommen")
        default:
            EmptyView()
        }
    }
}

/// One proposal with its evidence and the existing-album comparison (prompt §5).
struct ProposalDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var proposal: AlbumProposal
    @State private var name = ""
    @State private var showAdjust = false
    @State private var suggesting = false

    /// Only trips get a creative name; places and dates keep their exact titles.
    private var canSuggestTitle: Bool {
        if case .trip = proposal.kind { return SmartAssistant.isAvailable && recommended.isCreatingNew }
        return false
    }

    private func suggestTitle() async {
        suggesting = true
        defer { suggesting = false }
        let details = proposal.reasons.map { ReasonText.text($0) }
        guard let title = await SmartAssistant.tripTitle(currentTitle: proposal.title, details: details) else { return }
        let year = proposal.dateRange.map { String(Calendar.current.component(.year, from: $0.start)) }
        model.setUserTitle([title, year].compactMap { $0 }.joined(separator: " "), for: proposal)
    }

    private var match: MatchResult? { model.match(for: proposal) }
    private var recommended: ProposalDecision {
        ProposalDecision.recommended(for: proposal, match: match, userTitle: name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ThumbnailGrid(ids: proposal.assetIDs.sorted(), columns: 4, limit: 12)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("\(Text(proposal.kind.area.title)) · \(Text(proposal.reliability.label))")
                        .textCase(.uppercase)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    if proposal.requiresUserName {
                        TextField(proposal.title, text: $name)
                            .font(.title2.weight(.bold))
                            .textFieldStyle(.roundedBorder)
                        Text("Gib diesem Ort oder dieser Gruppe einen Namen. SORTLY benennt persönliche Orte nie selbst.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(model.userTitles[proposal.id] ?? proposal.title).font(.title2.weight(.bold))
                        if canSuggestTitle {
                            Button {
                                Task { await suggestTitle() }
                            } label: {
                                if suggesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Namen vorschlagen", systemImage: "apple.intelligence")
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .disabled(suggesting)
                        }
                    }
                    ForEach(Array(proposal.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(ReasonText.text(reason)).font(.body).foregroundStyle(.secondary)
                    }
                }

                matchCard

                Card {
                    LabeledContent("Ordner", value: ([model.settings.rootFolderTitle] + proposal.folderPath).joined(separator: " › "))
                    if !proposal.optionalAssetIDs.isEmpty {
                        LabeledContent("Nur vorgeschlagen", value: "\(proposal.optionalAssetIDs.count)")
                    }
                    if proposal.isSensitive {
                        Label("Persönlicher Inhalt: wird nie automatisch übernommen.", systemImage: "lock")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                actions
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.background)
        .navigationTitle("Vorschlag")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = model.userTitles[proposal.id] ?? "" }
        .sheet(isPresented: $showAdjust) {
            NavigationStack { AdjustProposalView(proposal: proposal) }
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var matchCard: some View {
        if let match {
            Card {
                Label {
                    Text(match.status.label).font(.headline)
                } icon: {
                    Image(systemName: match.status == .newAlbumRequired ? "plus.rectangle.on.folder" : "checkmark.circle.fill")
                        .foregroundStyle(match.status.tint)
                }
                ForEach(Array(match.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(ReasonText.text(reason)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button(primaryTitle) {
                if proposal.requiresUserName { model.setUserTitle(name, for: proposal) }
                model.setDecision(recommended, for: proposal)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!recommended.isAccepted)

            HStack(spacing: Theme.Spacing.s) {
                Button("Anpassen") { showAdjust = true }.buttonStyle(SecondaryButtonStyle())
                Button("Nicht jetzt") {
                    model.setDecision(.reject, for: proposal)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.top, Theme.Spacing.s)
    }

    private var primaryTitle: LocalizedStringKey {
        switch recommended {
        case .keepExisting: "Album so lassen"
        case .extendExisting:
            if let missing = match?.best.map({ proposal.assetIDs.count - $0.metrics.intersection }), missing > 0 {
                "\(missing) Fotos ergänzen"
            } else {
                "Album ergänzen"
            }
        case .createNew: "Album anlegen"
        case .undecided: proposal.requiresUserName ? "Erst einen Namen eingeben" : "Bitte unter „Anpassen“ wählen"
        default: "Übernehmen"
        }
    }
}

/// Choose between creating a new album and using one of the matching albums.
struct AdjustProposalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var proposal: AlbumProposal
    @State private var title = ""

    private var candidates: [MatchCandidate] {
        guard let match = model.match(for: proposal) else { return [] }
        return ([match.best].compactMap { $0 } + match.alternatives).filter(\.isEditable)
    }

    var body: some View {
        Form {
            Section("Neues Album") {
                TextField("Titel", text: $title)
                Button("Als neues Album anlegen") {
                    let trimmed = title.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { model.setUserTitle(trimmed, for: proposal) }
                    model.setDecision(.createNew(title: trimmed.isEmpty ? nil : trimmed, folderPath: nil), for: proposal)
                    dismiss()
                }
                .disabled(proposal.requiresUserName && title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !candidates.isEmpty {
                Section("Vorhandenes Album ergänzen") {
                    ForEach(candidates, id: \.albumID) { candidate in
                        Button {
                            model.setDecision(.extendExisting(candidate.albumID), for: proposal)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(candidate.albumTitle)
                                Text("\(candidate.metrics.intersection) gemeinsame Aufnahmen").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Anpassen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
        }
        .onAppear { title = model.userTitles[proposal.id] ?? (proposal.requiresUserName ? "" : proposal.title) }
    }
}
