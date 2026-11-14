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
            // A stable order: rows never jump when one is accepted. Trips newest first,
            // everything else by size.
            .sorted { lhs, rhs in
                if area == .trips, let l = lhs.dateRange?.start, let r = rhs.dateRange?.start, l != r { return l > r }
                return (-lhs.assetIDs.count, lhs.title) < (-rhs.assetIDs.count, rhs.title)
            }
    }

    /// Open suggestions that may be accepted in one go: at least "likely", no name needed,
    /// a clear recommended action, never sensitive ones (prompt §8).
    private var recommendable: [AlbumProposal] {
        proposals.filter { p in
            model.decisions[p.id] == nil && p.reliability >= .likely && !p.isSensitive && !p.requiresUserName
                && model.recommendedDecision(for: p).isAccepted
        }
    }

    var body: some View {
        List {
            if proposals.isEmpty {
                ContentUnavailableView("Keine Vorschläge", systemImage: "checkmark.circle",
                                       description: Text("Für diesen Bereich gibt es gerade nichts zu tun."))
            }
            if !recommendable.isEmpty {
                Section {
                    Button { acceptRecommended() } label: { Text("\(recommendable.count) empfohlene übernehmen") }
                        .buttonStyle(PrimaryButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Empfohlen sind sichere und wahrscheinliche Vorschläge ohne persönliche Themen. Angelegt wird erst beim Umsetzen, vorher siehst du alles noch einmal.")
                }
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
        // Accepted suggestions are created together: the way there is always in reach.
        .safeAreaInset(edge: .bottom) {
            if !model.acceptedProposals.isEmpty {
                NavigationLink {
                    PlanReviewView()
                } label: {
                    Text("\(model.acceptedProposals.count) übernommene Vorschläge umsetzen")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.s)
            }
        }
    }

    private func acceptRecommended() {
        let accepted = recommendable
        for p in accepted { model.setDecision(model.recommendedDecision(for: p), for: p) }
        AccessibilityNotification.Announcement(String(localized: "\(accepted.count) Vorschläge übernommen")).post()
    }
}

struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var proposal: AlbumProposal

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AssetThumbnail(id: proposal.coverAssetID ?? AssetID(""), side: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.userTitles[proposal.id] ?? proposal.title).font(.body.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                Text("\(proposal.assetIDs.count - (model.removedFromProposals[proposal.id]?.count ?? 0)) Aufnahmen").font(.footnote).foregroundStyle(.secondary)
                if let status = model.match(for: proposal)?.status {
                    StatusBadge(text: status.label, tint: status.tint)
                }
                decisionLabel
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// The decision in words, not only as a small symbol (testers missed the check mark).
    @ViewBuilder
    private var decisionLabel: some View {
        switch model.decisions[proposal.id] {
        case .reject:
            Label("Nicht jetzt", systemImage: "xmark.circle")
                .labelStyle(CompactLabelStyle())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        case .some(let d) where d.isAccepted:
            Label("Übernommen", systemImage: "checkmark.circle.fill")
                .labelStyle(CompactLabelStyle())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
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
    @State private var directPlan: ChangePlan?
    @State private var showDirect = false
    @State private var preparing = false
    @State private var applied = false
    @State private var rejectingMatch = false
    @State private var explainReliability = false

    /// Only trips get a creative name; places and dates keep their exact titles.
    private var canSuggestTitle: Bool {
        if case .trip = proposal.kind { return SmartAssistant.isAvailable && recommended.isCreatingNew }
        return false
    }

    private func suggestTitle() async {
        suggesting = true
        defer { suggesting = false }
        let details = proposal.reasons.map { ReasonText.text($0) }
        guard let title = await SmartAssistant.tripTitle(currentTitle: proposal.title, details: details, language: model.settings.titleLanguage) else { return }
        let year = proposal.dateRange.map { String(Calendar.current.component(.year, from: $0.start)) }
        model.setUserTitle([title, year].compactMap { $0 }.joined(separator: " "), for: proposal)
    }

    private var match: MatchResult? { model.match(for: proposal) }
    /// What the primary button does: the user's choice from "Anpassen" wins over Albumist's
    /// recommendation (it must never be overwritten by accepting the suggestion).
    private var recommended: ProposalDecision {
        let chosen = model.decision(for: proposal)
        if chosen.isAccepted { return chosen }
        return ProposalDecision.recommended(for: proposal, match: match, userTitle: name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                // Two rows: with more, the actions fell below the tab bar on a 6.1" iPhone.
                // Spread over the whole time span, oldest first; a tap shows all photos.
                NavigationLink {
                    ProposalPhotosView(proposal: proposal)
                } label: {
                    ThumbnailGrid(ids: model.previewIDs(for: proposal), total: model.members(of: proposal).count, columns: 4, limit: 8,
                                  portrait: [.screenshots, .documents, .messenger].contains(proposal.kind.area))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Alle \(model.members(of: proposal).count) Fotos ansehen"))

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    // Tapping the label explains what "Sicher" or "Wahrscheinlich" means.
                    Button { explainReliability = true } label: {
                        HStack(spacing: 4) {
                            Text("\(Text(proposal.kind.area.title)) · \(Text(proposal.reliability.label))")
                                .textCase(.uppercase)
                            Image(systemName: "info.circle")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(proposal.reliability.explanation))
                    .popover(isPresented: $explainReliability) {
                        Text(proposal.reliability.explanation)
                            .font(.subheadline)
                            .padding()
                            .frame(idealWidth: 300)
                            .fixedSize(horizontal: false, vertical: true)
                            .presentationCompactAdaptation(.popover)
                    }
                    if proposal.requiresUserName {
                        TextField(proposal.title, text: $name)
                            .font(.title2.weight(.bold))
                            .textFieldStyle(.roundedBorder)
                        Text("Gib diesem Ort oder dieser Gruppe einen Namen. Albumist benennt persönliche Orte nie selbst.")
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
                        Text(ReasonText.text(reason)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                // Album status and destination folder in one card.
                Card {
                    matchContent
                    if match != nil { Divider() }
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
        .background(alignment: .top) {
            // Each suggestion gets its own soft colours from its cover photo.
            ZStack(alignment: .top) {
                Theme.background
                PhotoGlow(id: model.previewIDs(for: proposal, count: 1).first ?? proposal.coverAssetID)
                    .frame(height: 440)
            }
            .ignoresSafeArea()
        }
        .navigationTitle("Vorschlag")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = model.userTitles[proposal.id] ?? "" }
        .sheet(isPresented: $showAdjust) {
            NavigationStack { AdjustProposalView(proposal: proposal) }
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: $showDirect) {
            PlanReviewView(prebuilt: directPlan)
        }
        .onChange(of: model.execution.finished) { _, finished in
            if showDirect && finished != nil { applied = true }
        }
        .onChange(of: showDirect) { _, showing in
            // Back from the finished preview: the suggestion is done, return to the list.
            if !showing && applied { dismiss() }
        }
    }

    @ViewBuilder
    private var matchContent: some View {
        if let match {
            Group {
                Label {
                    Text(match.status.label).font(.headline)
                } icon: {
                    Image(systemName: match.status == .newAlbumRequired ? "plus.rectangle.on.folder" : "checkmark.circle.fill")
                        .foregroundStyle(match.status.tint)
                }
                ForEach(Array(match.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(ReasonText.text(reason)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let choice = chosenAlbumText {
                    Label(choice, systemImage: "hand.point.up.left")
                        .font(.subheadline.weight(.semibold))
                }
                // "Passt nicht" names one album; with several albums the choice happens under "Album auswählen".
                if let best = match.best, best.isEditable, ![.newAlbumRequired, .multipleMatches].contains(match.status) {
                    Button("„\(best.albumTitle)“ passt nicht") { rejectingMatch = true }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .confirmationDialog("Dieses Album passt nicht?", isPresented: $rejectingMatch, titleVisibility: .visible) {
                            Button("Nicht mehr für diesen Vorschlag anbieten") {
                                Task { await model.rejectMatch(best.albumID, for: proposal) }
                            }
                        } message: {
                            Text("Albumist merkt sich das und schlägt stattdessen ein neues oder ein anderes passendes Album vor. Am Album selbst ändert sich nichts.")
                        }
                }
            }
        }
    }

    /// Several albums fit (or none clearly): the user picks one, Albumist does not guess.
    private var needsChoice: Bool {
        if case .undecided = recommended { return !proposal.requiresUserName }
        return false
    }

    /// The user's pick from "Anpassen", shown where Albumist could not decide alone.
    private var chosenAlbumText: String? {
        guard let match, [.multipleMatches, .ambiguous].contains(match.status) else { return nil }
        switch model.decision(for: proposal) {
        case .extendExisting(let id):
            let title = model.inventory[id]?.title ?? ""
            return String(localized: "Deine Wahl: „\(title)“ ergänzen")
        case .createNew:
            return String(localized: "Deine Wahl: neues Album")
        default:
            return nil
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button {
                if needsChoice {
                    showAdjust = true
                } else {
                    Task { await applyNow() }
                }
            } label: {
                if preparing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(primaryTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled((!recommended.isAccepted && !needsChoice) || preparing)

            HStack(spacing: Theme.Spacing.s) {
                Button("Anpassen") { showAdjust = true }.buttonStyle(SecondaryButtonStyle())
                Button("Nicht jetzt") {
                    model.setDecision(.reject, for: proposal)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if recommended.isAccepted && !recommended.isKeepExisting {
                Button("Übernehmen und später anlegen") { accept(); dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .padding(.top, Theme.Spacing.s)
    }

    private func accept() {
        if proposal.requiresUserName { model.setUserTitle(name, for: proposal) }
        model.setDecision(recommended, for: proposal)
    }

    /// Applies this one suggestion right away (preview, then the album exists in Photos).
    private func applyNow() async {
        accept()
        preparing = true
        defer { preparing = false }
        if let plan = await model.singlePlan(for: proposal) {
            directPlan = plan
            showDirect = true
        } else {
            dismiss() // nothing to change (album already complete or kept as it is)
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch recommended {
        case .keepExisting: "Album so lassen"
        case .extendExisting(let id):
            // The album the user chose, which need not be Albumist's first candidate.
            let candidate = match.flatMap { m in ([m.best].compactMap { $0 } + m.alternatives).first { $0.albumID == id } }
            if let missing = candidate.map({ proposal.assetIDs.count - $0.metrics.intersection }), missing > 0 {
                "\(missing) Fotos ergänzen"
            } else {
                "Album ergänzen"
            }
        case .createNew: "Album anlegen"
        case .undecided: proposal.requiresUserName ? "Erst einen Namen eingeben" : "Album auswählen"
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
            Section {
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
                    .foregroundStyle(.primary)
                }
                NavigationLink("Anderes Album wählen") {
                    AlbumPickerView(excluded: Set(candidates.map(\.albumID))) { id in
                        model.setDecision(.extendExisting(id), for: proposal)
                        dismiss()
                    }
                }
            } header: {
                Text("Vorhandenes Album ergänzen")
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

/// Every album Albumist may change, searchable; used when no suggested album fits.
struct AlbumPickerView: View {
    @Environment(AppModel.self) private var model
    var excluded: Set<CollectionID> = []
    var onPick: (CollectionID) -> Void
    @State private var query = ""

    private var albums: [CollectionSnapshot] {
        let all = model.inventory.albums.filter { $0.isEditableAlbum && !excluded.contains($0.id) }
        let filtered = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if albums.isEmpty {
                Text(query.isEmpty ? LocalizedStringKey("Noch keine Alben") : LocalizedStringKey("Kein Album gefunden")).foregroundStyle(.secondary)
            }
            ForEach(albums) { album in
                Button {
                    onPick(album.id)
                } label: {
                    HStack {
                        Label(album.title, systemImage: "rectangle.stack")
                        Spacer()
                        Text(album.assetIDs.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $query, prompt: Text("Album suchen"))
        .navigationTitle("Album wählen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every photo of one suggestion, oldest first. Photos that do not belong can be taken out of
/// this suggestion; they stay in the library and in other suggestions.
struct ProposalPhotosView: View {
    @Environment(AppModel.self) private var model
    var proposal: AlbumProposal
    @State private var selecting = false
    @State private var selected: Set<AssetID> = []
    @State private var confirmRemove = false
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 3)]

    var body: some View {
        let members = model.members(of: proposal)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(members, id: \.self) { id in
                    tile(id)
                }
            }
        }
        .navigationTitle(Text("\(members.count) Fotos"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selected = []
                    }
                }
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Text("\(selected.count) aus Vorschlag entfernen")
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Fotos aus diesem Vorschlag entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                let chosen = selected
                Task {
                    await model.removeFromProposal(chosen, proposal: proposal)
                    withAnimation(.snappy) {
                        selected = []
                        selecting = false
                    }
                }
            }
        } message: {
            Text("Sie kommen nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleiben sie.")
        }
    }

    private func traits(selected isSelected: Bool) -> AccessibilityTraits {
        guard selecting else { return [] }
        return isSelected ? [.isButton, .isSelected] : [.isButton]
    }

    private func tile(_ id: AssetID) -> some View {
        let isSelected = selected.contains(id)
        return AssetThumbnail(id: id, side: 120)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.25))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .opacity(selecting && !isSelected ? 0.85 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard selecting else { return }
                if isSelected { selected.remove(id) } else { selected.insert(id) }
            }
            .accessibilityAddTraits(traits(selected: isSelected))
    }
}

/// Symbol and text close together, like a status line (the list's own label style
/// puts the symbol in a wide icon column).
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
