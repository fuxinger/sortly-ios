import SwiftUI
import SortlyCore

/// "Erster Scan als Show": during the first analysis the user's own photos form a mosaic
/// that a soft light sweeps across, and every trip Albumist finds pops up as a card.
/// Only on the first run (no albums made yet); later runs keep the plain progress bar.
struct ScanShow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = 6
    private let rows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            mosaic
            found
        }
    }

    /// Photos spread over the whole library, so the mosaic shows years, not one afternoon.
    private var mosaicPhotos: [AssetID] {
        let facts = model.facts
        let count = columns * rows
        guard facts.count > count else { return facts.map(\.id) }
        return (0..<count).map { facts[$0 * (facts.count - 1) / (count - 1)].id }
    }

    private var mosaic: some View {
        let photos = mosaicPhotos
        return Group {
            if photos.count >= columns {
                TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
                    let sweep = reduceMotion ? -10 : sweepPosition(at: context.date)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.element) { index, id in
                            let column = Double(index % columns)
                            // Distance of this tile from the light band running left to right.
                            let glow = max(0, 1 - abs(column - sweep) / 1.6)
                            AssetThumbnail(id: id, side: 64)
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .compositingGroup() // fade photo and its placeholder as one
                                .opacity(0.55 + 0.45 * glow)
                                .scaleEffect(1 + 0.06 * glow)
                                .brightness(0.08 * glow)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.6), value: photos.count)
        .accessibilityHidden(true)
    }

    /// The light band: one pass across the six columns every 2.4 seconds.
    private func sweepPosition(at date: Date) -> Double {
        let period = 2.4
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return phase * Double(columns + 3) - 1.5
    }

    /// Trips found so far, newest first; each appears with a small spring.
    private var found: some View {
        let trips = model.proposals
            .filter { $0.kind == .trip }
            .sorted { ($0.dateRange?.start ?? .distantPast) > ($1.dateRange?.start ?? .distantPast) }
            .prefix(3)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !trips.isEmpty {
                Text("Schon gefunden")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            ForEach(Array(trips)) { trip in
                HStack(spacing: Theme.Spacing.m) {
                    AssetThumbnail(id: trip.coverAssetID ?? AssetID(""), side: 44)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.userTitles[trip.id] ?? trip.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(trip.assetIDs.count) Aufnahmen")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "airplane")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .transition(reduceMotion ? AnyTransition.opacity
                            : AnyTransition.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.45, dampingFraction: 0.7), value: trips.map(\.id))
    }
}
