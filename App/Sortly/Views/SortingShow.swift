import SwiftUI
import SortlyCore

/// "Fotos fliegen in Alben": while a plan runs, photos lift off a loose pile and fly in an arc
/// into their album, one album after another, while a counter runs up.
///
/// The show is paced for the eye (about four seconds in total) but never runs ahead of the
/// real work: an album only fills once its step has really finished. If the work is quicker,
/// the show finishes on its own; a tap skips it. With Reduce Motion the albums cross-fade.
struct SortingShow: View {
    struct Album: Identifiable, Equatable {
        /// Index of the album's last "add photos" step in the plan.
        let id: Int
        let title: String
        let assets: [AssetID]
    }

    let albums: [Album]
    var onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current = 0
    @State private var landed: Set<Int> = []
    @State private var counted = 0
    @State private var flights: [Flight] = []
    @State private var skipping = false
    @State private var pop = false
    @State private var landings = 0
    @State private var width: CGFloat = 360

    private let sceneHeight: CGFloat = 360
    private var pileCenter: CGPoint { CGPoint(x: width / 2, y: 78) }
    private var albumCenter: CGPoint { CGPoint(x: width / 2, y: 252) }
    private var spacing: CGFloat { min(176, width * 0.44) }
    private var totalPhotos: Int { albums.reduce(0) { $0 + $1.assets.count } }

    /// Loose photos on the pile: offset x, offset y, rotation in degrees.
    private static let scatter: [(CGFloat, CGFloat, Double)] = [
        (-54, -4, -11), (46, -12, 8), (-14, 12, -3), (60, 16, 13), (-66, 24, -16), (8, -22, 5),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            header
            ZStack {
                pile
                carousel
                ForEach(flights) { FlyingPhoto(flight: $0) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: sceneHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityHidden(true)

            Button("Überspringen") { skipping = true }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .opacity(skipping ? 0 : 1)
        }
        .padding(.top, Theme.Spacing.m)
        .contentShape(Rectangle())
        .onTapGesture { skipping = true }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: landings)
        .task { await run() }
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(counted, format: .number)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(counted)))
            Text("Fotos einsortiert")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Album \(min(current + 1, albums.count)) von \(albums.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Fotos werden einsortiert"))
        .accessibilityValue(Text("\(counted) von \(totalPhotos)"))
    }

    /// The pile thins out as photos find their albums.
    private var pile: some View {
        let photos = pilePhotos
        let remaining = 1 - Double(counted) / Double(max(1, totalPhotos))
        let visible = Int((remaining * Double(photos.count)).rounded(.up))
        return ZStack {
            ForEach(Array(photos.prefix(visible).enumerated()), id: \.element) { index, id in
                let s = Self.scatter[index % Self.scatter.count]
                PhotoChip(id: id, side: 76)
                    .rotationEffect(.degrees(s.2))
                    .offset(x: s.0, y: s.1)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .position(pileCenter)
        .animation(.smooth(duration: 0.35), value: visible)
    }

    private var carousel: some View {
        ZStack {
            ForEach(albums.indices.filter { abs($0 - current) <= 1 }, id: \.self) { index in
                let offset = CGFloat(index - current)
                AlbumStack(album: albums[index], filled: landed.contains(index))
                    .scaleEffect(index == current ? (pop ? 1.07 : 1) : 0.76)
                    .opacity(index == current ? 1 : (index < current ? 0.5 : 0.35))
                    .position(x: albumCenter.x + offset * spacing, y: albumCenter.y)
                    .transition(.opacity)
            }
        }
    }

    /// Up to six photos from the first albums, so the pile shows the user's own pictures.
    private var pilePhotos: [AssetID] {
        var result: [AssetID] = []
        var round = 0
        while result.count < 6 && round < 6 {
            for album in albums where round < album.assets.count && result.count < 6 {
                let id = album.assets[round]
                if !result.contains(id) { result.append(id) }
            }
            round += 1
        }
        return result
    }

    // MARK: Choreography

    private func run() async {
        let started = Date()
        if albums.isEmpty {
            await waitForEnd(started: started)
            onFinish()
            return
        }
        let pace: Double = reduceMotion ? 0.3 : (albums.count == 1 ? 1.1 : min(0.8, max(0.4, 4.2 / Double(albums.count))))
        // Long plans: the first albums fly in full, the rest are counted up quickly.
        let detailed = albums.count <= 10 ? albums.count : 7
        for index in albums.indices {
            if Task.isCancelled { return }
            await waitUntilDone(index, started: started)
            if model.execution.failure != nil { break }
            let quick = skipping || reduceMotion || (index >= detailed && index < albums.count - 1)
            withAnimation(quick ? .snappy(duration: 0.2) : .smooth(duration: 0.45)) { current = index }
            if quick {
                try? await Task.sleep(for: .seconds(skipping ? 0.02 : (reduceMotion ? pace : 0.09)))
            } else {
                launch(index, duration: pace * 0.8)
                try? await Task.sleep(for: .seconds(pace * 0.8))
            }
            await land(index, quietly: quick && !reduceMotion)
            if !quick { try? await Task.sleep(for: .seconds(pace * 0.25)) }
        }
        await waitForEnd(started: started)
        try? await Task.sleep(for: .seconds(skipping ? 0.05 : 0.6))
        onFinish()
    }

    private func launch(_ index: Int, duration: Double) {
        let album = albums[index]
        let count = min(album.assets.count, albums.count == 1 ? 6 : (albums.count <= 4 ? 4 : 3))
        let target = CGPoint(x: albumCenter.x, y: albumCenter.y - 30)
        var launched: [Flight] = []
        for k in 0..<count {
            let s = Self.scatter[k % Self.scatter.count]
            let from = CGPoint(x: pileCenter.x + s.0, y: pileCenter.y + s.1)
            let to = CGPoint(x: target.x + CGFloat(k % 3 - 1) * 6, y: target.y + CGFloat(k % 2) * 4)
            let side: CGFloat = k.isMultiple(of: 2) ? 1 : -1
            let control = CGPoint(x: (from.x + to.x) / 2 + side * min(120, width * 0.28), y: (from.y + to.y) / 2 - 36)
            launched.append(Flight(asset: album.assets[k], from: from, control: control, to: to,
                                   angle: s.2, delay: Double(k) * 0.07, duration: max(0.3, duration - Double(k) * 0.07)))
        }
        flights.append(contentsOf: launched)
        let ids = Set(launched.map(\.id))
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.6))
            flights.removeAll { ids.contains($0.id) }
        }
    }

    private func land(_ index: Int, quietly: Bool) async {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { _ = landed.insert(index) }
        withAnimation(.snappy(duration: quietly ? 0.15 : 0.35)) { counted += albums[index].assets.count }
        if quietly { return }
        landings += 1
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { pop = true }
        try? await Task.sleep(for: .seconds(0.12))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pop = false }
    }

    /// Never ahead of the real work: wait until the album's step has finished.
    private func waitUntilDone(_ index: Int, started: Date) async {
        while !Task.isCancelled {
            let execution = model.execution
            if execution.completedSteps > albums[index].id || execution.finished != nil || execution.failure != nil { return }
            if !execution.isRunning && Date().timeIntervalSince(started) > 3 { return }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private func waitForEnd(started: Date) async {
        while !Task.isCancelled {
            let execution = model.execution
            if execution.finished != nil || execution.failure != nil { return }
            if !execution.isRunning && Date().timeIntervalSince(started) > 3 { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    // MARK: Plan → albums

    /// The albums a plan fills, in plan order. Chunked "add photos" steps of one album are
    /// merged; the album counts as done when its last chunk is done.
    static func albums(from plan: ChangePlan, inventory: CollectionInventory) -> [Album] {
        var titles: [String: String] = [:]
        for step in plan.steps {
            if case .createAlbum(let key, let title, _) = step.operation { titles[key] = title }
        }
        var order: [AlbumRef] = []
        var lastStep: [AlbumRef: Int] = [:]
        var assets: [AlbumRef: [AssetID]] = [:]
        for (index, step) in plan.steps.enumerated() {
            guard case .addAssets(let ref, let ids) = step.operation, !ids.isEmpty else { continue }
            if lastStep[ref] == nil { order.append(ref) }
            lastStep[ref] = index
            assets[ref, default: []].append(contentsOf: ids)
        }
        return order.map { ref in
            let title: String = switch ref {
            case .planned(let key): titles[key] ?? String(localized: "Album")
            case .existing(let id): inventory[id]?.title ?? String(localized: "Album")
            }
            return Album(id: lastStep[ref] ?? 0, title: title, assets: assets[ref] ?? [])
        }
    }
}

// MARK: - Pieces

/// A photo as a small print: rounded, white edge, soft shadow.
private struct PhotoChip: View {
    var id: AssetID
    var side: CGFloat

    var body: some View {
        AssetThumbnail(id: id, side: side)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }
}

/// The target album: a small stack with its cover, title and count.
private struct AlbumStack: View {
    var album: SortingShow.Album
    var filled: Bool
    private let side: CGFloat = 124

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: side - 16, height: side - 16)
                    .offset(y: -14)
                    .opacity(0.7)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: side - 8, height: side - 8)
                    .offset(y: -7)
                cover
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if filled {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accent)
                                .padding(8)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
            }
            .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 160)
            Text("\(album.assets.count) Fotos")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var cover: some View {
        if filled, let first = album.assets.first {
            AssetThumbnail(id: first, side: side)
                .transition(.opacity)
        } else {
            ZStack {
                Theme.accent.opacity(0.12)
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.6))
            }
        }
    }
}

private struct Flight: Identifiable {
    let id = UUID()
    let asset: AssetID
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let angle: Double
    let delay: Double
    let duration: Double
}

/// One photo on its way: it lifts (grows, deeper shadow), swings along a curve and shrinks
/// into the album.
private struct FlyingPhoto: View {
    let flight: Flight
    @State private var progress: CGFloat = 0

    var body: some View {
        PhotoChip(id: flight.asset, side: 76)
            .modifier(ArcFlight(progress: progress, from: flight.from, control: flight.control,
                                to: flight.to, angle: flight.angle))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: flight.duration).delay(flight.delay)) {
                    progress = 1
                }
            }
    }
}

/// Position on a quadratic Bézier curve plus lift, turn and fade, driven by one number so
/// SwiftUI can animate it frame by frame.
private struct ArcFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let angle: Double

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = progress
        let u = 1 - t
        let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
        let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
        let lift = sin(CGFloat.pi * t)
        let fade: Double = t > 0.92 ? Double((1 - t) / 0.08) : 1
        return content
            .scaleEffect((1 + 0.16 * lift) * (1 - 0.42 * t))
            .rotationEffect(.degrees(angle * Double(u)))
            .shadow(color: .black.opacity(0.18 * Double(lift)), radius: 14 * lift, y: 10 * lift)
            .opacity(fade)
            .position(x: x, y: y)
    }
}
