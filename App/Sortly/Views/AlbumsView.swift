import SwiftUI
import SortlyCore
import SortlyEngine

/// Existing albums and folders as Photos shows them, plus merge suggestions for albums
/// that hold mostly the same photos (prompt §3).
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var mergePlan: ChangePlan?
    @State private var showMerge = false

    private var topLevel: [CollectionSnapshot] {
        model.inventory.collections.values
            .filter { $0.parentID == nil && $0.kind != .smartAlbum }
            .sorted(by: Self.order)
    }

    private var suggestions: [AlbumOverlapAnalyzer.MergeSuggestion] { model.mergeSuggestions }

    static func order(_ a: CollectionSnapshot, _ b: CollectionSnapshot) -> Bool {
        if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    var body: some View {
        List {
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.albumIDs) { suggestion in
                        Button {
                            Task {
                                mergePlan = await model.mergePlan(suggestion)
                                showMerge = mergePlan != nil
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.albumIDs.compactMap { model.inventory[$0]?.title }.formatted(.list(type: .and)))
                                    .font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text("\(suggestion.albumIDs.count) Alben mit vielen gleichen Fotos · \(suggestion.distinctAssetCount) Fotos insgesamt")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Ähnliche Alben")
                } footer: {
                    Text("Albumist ergänzt das größte Album um die fehlenden Fotos. Die anderen Alben bleiben erhalten.")
                }
            }

            let fromSortly = model.managedAlbums.compactMap { model.inventory[$0.albumID] }
            if !fromSortly.isEmpty {
                Section {
                    ForEach(fromSortly.sorted(by: Self.order)) { collection in
                        CollectionRow(collection: collection)
                    }
                } header: {
                    Text("Von Albumist angelegt oder ergänzt")
                } footer: {
                    Text("Neue Alben liegen in Fotos im Ordner „\(model.settings.rootFolderTitle)“.")
                }
            }

            Section("Deine Alben") {
                if topLevel.isEmpty {
                    Text("Noch keine Alben").foregroundStyle(.secondary)
                }
                ForEach(topLevel) { collection in
                    CollectionRow(collection: collection)
                }
            }
        }
        .navigationTitle("Alben")
        .navigationDestination(isPresented: $showMerge) {
            PlanReviewView(prebuilt: mergePlan)
        }
        .refreshable { await model.refreshDerived() }
    }
}

/// One album or folder; folders open their children.
struct CollectionRow: View {
    @Environment(AppModel.self) private var model
    var collection: CollectionSnapshot

    var body: some View {
        if collection.kind == .folder {
            NavigationLink {
                FolderView(folder: collection)
            } label: {
                label(symbol: "folder", detail: Text("\(collection.childIDs.count) Einträge"))
            }
        } else {
            NavigationLink {
                AlbumDetailView(album: collection)
            } label: {
                label(symbol: collection.kind == .restrictedAlbum ? "person.2" : "rectangle.stack",
                      detail: Text("\(collection.assetIDs.count) Fotos"))
            }
        }
    }

    private func label(symbol: String, detail: Text) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            if collection.kind == .folder {
                IconTile(systemName: symbol, tint: Theme.tint(for: .neutral))
            } else {
                AssetThumbnail(id: collection.assetIDs.min() ?? AssetID(""), side: 44)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title).font(.body)
                detail.font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct FolderView: View {
    @Environment(AppModel.self) private var model
    var folder: CollectionSnapshot

    var body: some View {
        List {
            let children = folder.childIDs.compactMap { model.inventory[$0] }.sorted(by: AlbumsView.order)
            if children.isEmpty { Text("Leerer Ordner").foregroundStyle(.secondary) }
            ForEach(children) { CollectionRow(collection: $0) }
        }
        .navigationTitle(folder.title)
    }
}

struct AlbumDetailView: View {
    var album: CollectionSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if !album.isEditableAlbum {
                    Label("Dieses Album kann Albumist nicht verändern.", systemImage: "lock")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ThumbnailGrid(ids: album.assetIDs.sorted(), columns: 4, limit: 200)
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.background)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
