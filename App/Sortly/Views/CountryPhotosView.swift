import SwiftUI
import SortlyCore
import SortlyEngine

/// Opened from the travel atlas: every photo taken in one country, newest year first,
/// with the places photographed most and, if SORTLY has one, the album suggestion.
struct CountryPhotosView: View {
    @Environment(AppModel.self) private var model
    var code: String
    /// The year chosen in the atlas; nil = all years.
    var year: Int?
    @State private var detail: AssetFacts?
    @State private var addingToAlbum: [AssetID]?

    var body: some View {
        let country = model.countryPhotos(code, year: year)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header(country)
                if let proposal = model.countryProposal(for: country) {
                    NavigationLink {
                        ProposalDetailView(proposal: proposal)
                    } label: {
                        suggestion(proposal)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(country.years) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack(alignment: .firstTextBaseline) {
                            if let value = group.year {
                                Text(verbatim: String(value)).font(.title3.weight(.bold))
                            } else {
                                Text("Ohne Datum").font(.title3.weight(.bold))
                            }
                            Spacer()
                            Text("\(group.photos.count) Fotos").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        grid(group.photos)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .navigationTitle(AtlasStyle.countryName(code))
        .overlay {
            if country.years.isEmpty {
                ContentUnavailableView("Keine Fotos", systemImage: "photo.on.rectangle",
                                       description: Text("Für dieses Land gibt es gerade keine Fotos."))
            }
        }
        .sheet(item: $detail) { facts in
            AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {}
        }
    }

    private func header(_ country: CountryPhotos) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text(TravelAtlas.flag(code)).font(.system(size: 44)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary(country)).font(.headline)
                if !country.topPlaces.isEmpty {
                    Text(country.topPlaces.formatted(.list(type: .and)))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private func summary(_ country: CountryPhotos) -> String {
        var parts = [String(localized: "\(country.photoCount) Fotos")]
        if country.tripCount > 0 { parts.append(String(localized: "\(country.tripCount) Reisen")) }
        if year == nil, let first = country.firstVisit {
            parts.append(String(localized: "seit \(String(Calendar.current.component(.year, from: first)))"))
        }
        return parts.joined(separator: " · ")
    }

    private func suggestion(_ proposal: AlbumProposal) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(systemName: "rectangle.stack.badge.plus", tint: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Album „\(model.userTitles[proposal.id] ?? proposal.title)“ anlegen").font(.body.weight(.medium))
                Text("Vorschlag mit \(proposal.assetIDs.count) Aufnahmen").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.l)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
    }

    private func grid(_ photos: [AssetFacts]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(photos, id: \.id) { facts in
                Button {
                    detail = facts
                } label: {
                    AssetThumbnail(id: facts.id, side: 110)
                        .aspectRatio(1, contentMode: .fill)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(facts.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}
