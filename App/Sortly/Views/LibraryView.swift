import SwiftUI
import SortlyCore
import SortlyEngine

/// Inbox (prompt §6): the library split by organization state, with ignore.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var bucket: InboxBucket = .unorganized
    @State private var selecting = false
    @State private var selection: Set<AssetID> = []
    @State private var detail: AssetFacts?
    @State private var addingToAlbum: [AssetID]?

    private static let buckets: [InboxBucket] = [.unorganized, .suggestions, .uncertain, .organized, .ignored, .all]

    var body: some View {
        let members = model.bucketMembers(bucket)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(Self.buckets, id: \.self) { b in
                            Button { bucket = b; selection = []; if b == .suggestions { selecting = false } } label: {
                                Text(b.label)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(b == bucket ? Theme.accent : Theme.card, in: Capsule())
                                    .foregroundStyle(b == bucket ? Theme.onAccent : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(b == bucket ? .isSelected : [])
                        }
                    }
                }
                if bucket == .suggestions {
                    Text("\(model.openProposals.count) Vorschläge für \(members.count.formatted()) Fotos und Videos")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("\(members.count.formatted()) Fotos und Videos")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }

                if bucket == .suggestions {
                    // Photos with a suggestion: show the suggestions themselves, ready to open.
                    proposalList
                } else if members.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle",
                                           description: Text(emptyDescription))
                } else {
                    grid(members)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .navigationTitle("Mediathek")
        .toolbar {
            if bucket != .suggestions {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "Fertig" : "Auswählen") {
                        selecting.toggle()
                        selection = []
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting && !selection.isEmpty {
                SelectionBar(count: selection.count, canIgnore: bucket != .ignored) {
                    addingToAlbum = Array(selection)
                } ignore: {
                    model.ignore(Array(selection))
                    selection = []
                    selecting = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selection.isEmpty)
        .sheet(item: $detail) { facts in
            AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {
                selection = []
                selecting = false
            }
        }
        .refreshable { await model.refreshDerived() }
    }

    @ViewBuilder
    private var proposalList: some View {
        let open = model.openProposals.sorted { ($0.assetIDs.count, $1.title) > ($1.assetIDs.count, $0.title) }
        if open.isEmpty {
            ContentUnavailableView("Keine offenen Vorschläge", systemImage: "checkmark.circle",
                                   description: Text("Alle Vorschläge sind entschieden."))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(open.enumerated()), id: \.element.id) { index, proposal in
                    NavigationLink {
                        ProposalDetailView(proposal: proposal)
                    } label: {
                        HStack {
                            ProposalRow(proposal: proposal)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < open.count - 1 { Divider().padding(.leading, 84) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func grid(_ members: [AssetFacts]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(members.prefix(3000), id: \.id) { facts in
                let id = facts.id
                // A real button: VoiceOver, Switch Control and the hit-area audit see it as one.
                Button {
                    guard selecting else { detail = facts; return }
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                } label: {
                    AssetThumbnail(id: id, side: 110)
                        .aspectRatio(1, contentMode: .fill)
                        .overlay(alignment: .bottomTrailing) {
                            if selecting {
                                Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(.white, selection.contains(id) ? Theme.accent : Color.black.opacity(0.3))
                                    .padding(6)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(facts.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
                .accessibilityAddTraits(selecting && selection.contains(id) ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private var emptyTitle: LocalizedStringKey {
        bucket == .unorganized ? "Alles sortiert" : "Keine Fotos"
    }

    private var emptyDescription: LocalizedStringKey {
        switch bucket {
        case .unorganized: "Alle Fotos liegen in deinen Hauptbereichen."
        case .ignored: "Fotos, die du ignorierst, tauchen hier auf und werden nicht mehr vorgeschlagen."
        default: "In diesem Bereich gibt es gerade nichts."
        }
    }
}

/// Actions for the selected photos, floating above the tab bar.
struct SelectionBar: View {
    var count: Int
    var canIgnore: Bool
    var addToAlbum: () -> Void
    var ignore: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: addToAlbum) {
                Label("Zu Album hinzufügen", systemImage: "rectangle.stack.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if canIgnore {
                Button(action: ignore) {
                    Label("Ignorieren", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .padding(Theme.Spacing.m)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        .overlay(alignment: .topTrailing) {
            Text(count.formatted())
                .font(.caption.weight(.bold)).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(Theme.onAccent)
                .offset(x: -14, y: -8)
                .accessibilityLabel(Text("\(count) ausgewählt"))
        }
    }
}

/// One photo, large, with what Albumist knows about it and why it is (not) sorted.
struct AssetDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var facts: AssetFacts
    var addToAlbum: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AssetThumbnail(id: facts.id, side: 420)
                        .aspectRatio(aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    if let date = facts.asset.creationDate {
                        LabeledContent("Aufgenommen", value: date.formatted(date: .long, time: .shortened))
                    }
                    if let place = placeText {
                        LabeledContent("Ort", value: place)
                    }
                    if let state = model.states[facts.id] {
                        LabeledContent("Status") { Text(model.resolver.overall(state).label) }
                    }
                }
                Section {
                    if albums.isEmpty {
                        Text("Noch in keinem Album").foregroundStyle(.secondary)
                    }
                    ForEach(albums, id: \.self) { title in
                        Label(title, systemImage: "rectangle.stack")
                    }
                } header: {
                    Text("Alben")
                }
                let suggestions = model.proposals(containing: facts.id)
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions.prefix(6)) { proposal in
                            NavigationLink {
                                ProposalDetailView(proposal: proposal)
                            } label: {
                                ProposalRow(proposal: proposal)
                            }
                        }
                    } header: {
                        Text("Vorschläge für dieses Foto")
                    } footer: {
                        Text("Tippe auf einen Vorschlag, um ihn anzusehen und zu übernehmen.")
                    }
                } else if let reason = reasonText {
                    Section("Warum nicht sortiert?") {
                        Text(reason).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        dismiss()
                        addToAlbum()
                    } label: {
                        Label("Zu Album hinzufügen", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button(role: .destructive) {
                        model.ignore([facts.id])
                        dismiss()
                    } label: {
                        Label("Ignorieren", systemImage: "eye.slash")
                    }
                } footer: {
                    Text("Ignorierte Fotos schlägt Albumist nicht mehr vor. Am Foto selbst ändert sich nichts.")
                }
            }
            .navigationTitle("Foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }

    private var aspect: CGFloat {
        let w = CGFloat(facts.asset.pixelWidth), h = CGFloat(facts.asset.pixelHeight)
        return w > 0 && h > 0 ? w / h : 1
    }

    private var placeText: String? {
        guard let place = facts.place else { return nil }
        let parts = [place.locality, place.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var albums: [String] {
        facts.albumIDs.compactMap { model.inventory[$0]?.title }.sorted()
    }

    private var reasonText: LocalizedStringKey? {
        guard let state = model.states[facts.id] else { return "Die Analyse ist für dieses Foto noch nicht fertig." }
        switch model.resolver.overall(state) {
        case .fullyOrganized: return nil
        case .ignored: return "Du hast dieses Foto ignoriert."
        case .excluded: return "Dieses Foto ist von der Analyse ausgeschlossen, zum Beispiel weil es ausgeblendet ist."
        default:
            let statuses = Set(state.areas.values)
            if statuses.contains(.proposed) || statuses.contains(.pendingConfirmation) {
                return "Es gibt schon einen Vorschlag dafür. Du findest ihn in der Übersicht."
            }
            if facts.place == nil && facts.asset.kind != .video && !facts.asset.isScreenshotLike {
                return "Das Foto hat keinen Ort und passt zu keinem Thema. Du kannst es selbst in ein Album legen."
            }
            return "Es passt zu keinem deiner eingeschalteten Bereiche. Du kannst es selbst in ein Album legen."
        }
    }
}

/// Pick an existing album or name a new one; the change then goes through the normal review.
struct AddToAlbumSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var assets: [AssetID]
    var onDone: () -> Void
    @State private var newTitle = ""
    @State private var query = ""
    @State private var plan: ChangePlan?
    @State private var showPlan = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Name des neuen Albums", text: $newTitle)
                            .submitLabel(.done)
                            .onSubmit { Task { await prepare(target: nil) } }
                        Button("Anlegen") { Task { await prepare(target: nil) } }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Neues Album")
                }
                Section {
                    if albums.isEmpty {
                        Text("Noch keine Alben").foregroundStyle(.secondary)
                    }
                    ForEach(albums) { album in
                        Button {
                            Task { await prepare(target: album.id) }
                        } label: {
                            HStack {
                                Label(album.title, systemImage: "rectangle.stack")
                                Spacer()
                                Text(album.assetIDs.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Deine Alben")
                }
            }
            .searchable(text: $query, prompt: Text("Album suchen"))
            .navigationTitle(Text("\(assets.count) Fotos hinzufügen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .navigationDestination(isPresented: $showPlan) {
                PlanReviewView(prebuilt: plan)
            }
            .onChange(of: model.execution.finished) { _, finished in
                if finished != nil { onDone() }
            }
        }
    }

    private var albums: [CollectionSnapshot] {
        let all = model.inventory.albums.filter(\.isEditableAlbum)
        let filtered = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func prepare(target: CollectionID?) async {
        let title = target == nil ? newTitle.trimmingCharacters(in: .whitespaces) : nil
        guard let built = await model.manualPlan(assets: assets, target: target, newTitle: title) else { return }
        plan = built
        showPlan = true
    }
}
