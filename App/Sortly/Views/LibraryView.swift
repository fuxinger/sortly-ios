import SwiftUI
import SortlyCore
import SortlyEngine

/// Inbox (prompt §6): the library split by organization state, with ignore.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var bucket: InboxBucket = .unorganized
    @State private var selecting = false
    @State private var selection: Set<AssetID> = []

    private static let buckets: [InboxBucket] = [.unorganized, .suggestions, .uncertain, .organized, .ignored, .all]

    var body: some View {
        let members = model.bucketMembers(bucket)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(Self.buckets, id: \.self) { b in
                            Button { bucket = b; selection = [] } label: {
                                Text(b.label)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(b == bucket ? Theme.accent : Theme.card, in: Capsule())
                                    .foregroundStyle(b == bucket ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(b == bucket ? .isSelected : [])
                        }
                    }
                }
                Text("\(members.count.formatted()) Fotos und Videos")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()

                if members.isEmpty {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    selecting.toggle()
                    selection = []
                }
            }
            if selecting && !selection.isEmpty && bucket != .ignored {
                ToolbarItem(placement: .bottomBar) {
                    Button("\(selection.count) ignorieren") {
                        model.ignore(Array(selection))
                        selection = []
                        selecting = false
                    }
                }
            }
        }
        .refreshable { await model.refreshDerived() }
    }

    private func grid(_ members: [AssetFacts]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(members.prefix(3000), id: \.id) { facts in
                let id = facts.id
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
                    .onTapGesture {
                        guard selecting else { return }
                        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(facts.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Foto"))
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
