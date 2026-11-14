import SwiftUI
import SortlyCore
import SortlyEngine

/// Natural search over the analysed library (prompt §14), e.g. "Hunde Italien 2023".
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var tokens: [SearchToken] = []
    @State private var results: [AssetID] = []
    @State private var searching = false
    @State private var detail: AssetFacts?
    @State private var addingToAlbum: [AssetID]?
    @Namespace private var zoom

    private let examples: [String] = ["Strand 2024", "Italien", "Rechnungen", "Videos", "Nicht sortiert", "Screenshots Bestellung"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Suche nach Orten, Jahren, Themen oder Text auf Screenshots.")
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: Theme.Spacing.s) {
                        ForEach(examples, id: \.self) { example in
                            Button(example) { query = example }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                } else {
                    if let rewrite = model.lastSearchRewrite, !searching {
                        Label("Verstanden als: \(rewrite)", systemImage: "apple.intelligence")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !tokens.isEmpty {
                        FlowLayout(spacing: Theme.Spacing.xs) {
                            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                                Text(verbatim: token.label)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .foregroundStyle(Theme.accent)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    if searching {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        HStack {
                            Text("\(results.count.formatted()) Treffer").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                            // The search becomes an album in Photos (through the normal preview).
                            Button("Als Album anlegen") { addingToAlbum = Array(results.prefix(2000)) }
                                .font(.footnote.weight(.semibold))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
                            ForEach(results.prefix(2000), id: \.self) { id in
                                let hit = model.factsByID[id]
                                Button {
                                    detail = hit
                                } label: {
                                    AssetThumbnail(id: id, side: 110)
                                        .aspectRatio(1, contentMode: .fill)
                                        .matchedTransitionSource(id: id, in: zoom)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(hit == nil)
                                .accessibilityLabel(Text(hit?.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
        .background(Theme.background)
        .navigationTitle("Suche")
        .sheet(item: $detail) { facts in
            AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
                .navigationTransition(.zoom(sourceID: facts.id, in: zoom))
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {}
        }
        .searchable(text: $query, prompt: SmartAssistant.isAvailable ? Text("z. B. Grillen bei Oma letzten Sommer") : Text("z. B. Hunde Italien 2023"))
        .task(id: query) {
            let text = query
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                tokens = []; results = []; return
            }
            searching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.search(text)
            guard !Task.isCancelled else { return }
            tokens = found.tokens
            results = found.results
            searching = false
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(indices: [index], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(index)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
